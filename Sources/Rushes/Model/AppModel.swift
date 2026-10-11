import AppKit
import Foundation
import RushesKit

enum AppPage: Hashable {
    case overview, review, library, history, resolve
}

/// What can be chosen in the sidebar. The folders of the library are rows of their own under it.
enum SidebarItem: Hashable {
    case overview, card, library, folder(String), history, resolve
}

/// Opens the window of the app from anywhere. SwiftUI only hands out `openWindow` to a view, so a view parks it here.
@MainActor
final class WindowOpener {
    static let shared = WindowOpener()
    var open: (() -> Void)?

    func openMain() {
        NSApp.activate()
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) {
            window.makeKeyAndOrderFront(nil)
            if window.isMiniaturized { window.deminiaturize(nil) }
        } else {
            open?()
        }
        NSApp.activate()
    }

    var mainWindowIsFront: Bool {
        guard NSApp.isActive, let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true }) else { return false }
        return window.isVisible && window.isKeyWindow && !window.isMiniaturized
    }
}

/// The app: which card is in, where the disk is, what is being copied, and the pages that show it.
@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let dataDirectory: URL
    let ledger: Ledger
    let library = LibraryModel()
    let resolve: ResolveModel

    private(set) var volumes: [VolumeInfo] = []
    private(set) var sessions: [CardSession] = []
    private(set) var destination: VolumeInfo?
    private(set) var backup: VolumeInfo?
    var job: ImportJob?
    private(set) var history: [Ledger.ImportRecord] = []
    var page: AppPage = .overview
    var reviewSessionID: String?
    var toast: String?
    var alert: AppAlert?
    /// Set after a folder was renamed: clips in Resolve may still point at the old name.
    var pendingRelink: RelinkRequest?
    var integrity: IntegrityState?

    var sidebarSelection: SidebarItem {
        get {
            switch page {
            case .overview: .overview
            case .review: .card
            case .library: library.selected.map { .folder($0.id) } ?? .library
            case .history: .history
            case .resolve: .resolve
            }
        }
        set {
            switch newValue {
            case .overview: page = .overview
            case .card: page = .review
            case .library: page = .library
            case let .folder(id):
                library.selectedID = id
                page = .library
            case .history: page = .history
            case .resolve: page = .resolve
            }
        }
    }

    private let watcher = VolumeWatcher()
    private let sleepBlocker = SleepBlocker()
    private var activity: NSObjectProtocol?
    private var toastTask: Task<Void, Never>?
    private var started = false
    private var announced = Set<String>()
    private var lastDestinationID: String?

    struct RelinkRequest: Identifiable {
        let id = UUID()
        let from: String
        let to: String
    }

    struct IntegrityState: Identifiable {
        let id = UUID()
        var folder: String
        var done: Int
        var total: Int
        var report: IntegrityReport?
        var missingManifest = false
    }

    struct AppAlert: Identifiable {
        let id = UUID()
        var title: String
        var message: String
    }

    init() {
        Prefs.register()
        dataDirectory = AppIdentity.dataDirectory()
        try? FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        do {
            ledger = try Ledger(path: dataDirectory.appendingPathComponent("ledger.sqlite").path)
        } catch {
            // A damaged ledger must not stop the app: start a new one next to it and keep the old file for a look.
            let broken = dataDirectory.appendingPathComponent("ledger.sqlite")
            try? FileManager.default.moveItem(at: broken, to: dataDirectory.appendingPathComponent("ledger-damaged-\(Int(Date().timeIntervalSince1970)).sqlite"))
            // swiftlint:disable:next force_try
            ledger = try! Ledger(path: broken.path)
        }
        resolve = ResolveModel(directory: dataDirectory)
        library.attach(ledger: ledger)
    }

    // MARK: Start

    func start() {
        guard !started else { return }
        started = true
        ledger.markInterrupted()
        history = ledger.imports()
        Notifier.shared.onAction = { [weak self] action, info in self?.handleNotification(action: action, info: info) }
        Notifier.shared.setUp()
        watcher.onChange = { [weak self] in self?.refreshVolumes() }
        watcher.start()
        refreshVolumes()
        resolve.startWatching()
        if Prefs.bool(PrefKey.resolveEnabled), Prefs.bool(PrefKey.resolveAutoScan) {
            Task { await resolve.scan(); library.recount(index: resolve.index) }
        }
        Task { await resolve.refreshBridge() }
    }

    // MARK: Volumes

    private func mountedVolumes() -> [VolumeInfo] {
        var found = Volumes.mounted()
        // Development: a folder can stand in for a card and another for the disk.
        let environment = ProcessInfo.processInfo.environment
        if let path = environment["RUSHES_DEBUG_CARD"], !path.isEmpty {
            found.append(Self.fake(path: path, name: "NO NAME", uuid: "debug-card", capacity: 128 << 30, removable: true))
        }
        if let path = environment["RUSHES_DEBUG_DEST"], !path.isEmpty {
            found.append(Self.fake(path: path, name: "Debug SSD", uuid: "debug-dest", capacity: 4_000 << 30, removable: false))
        }
        return found
    }

    private static func fake(path: String, name: String, uuid: String, capacity: UInt64, removable: Bool) -> VolumeInfo {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let free = DiskSpace.available(at: url) ?? 0
        return VolumeInfo(url: url, name: name, uuid: uuid, capacity: capacity, available: free, isRemovable: removable,
                          isEjectable: removable, isInternal: false, isReadOnly: false, format: "exFAT")
    }

    func refreshVolumes() {
        let current = mountedVolumes()
        volumes = current
        let oldDestination = lastDestinationID
        destination = chooseDestination(from: current)
        backup = chooseBackup(from: current)
        lastDestinationID = destination?.id

        let cards = current.filter { $0.looksLikeCard && $0.id != destination?.id && $0.id != backup?.id }
        for session in sessions where !cards.contains(where: { $0.id == session.id }) && session.stage != .importing {
            sessions.removeAll { $0.id == session.id }
            announced.remove(session.id)
            if reviewSessionID == session.id { reviewSessionID = nil }
        }
        for card in cards where !sessions.contains(where: { $0.id == card.id }) {
            let session = CardSession(volume: card)
            sessions.append(session)
            scan(session)
        }
        if destination?.id != oldDestination {
            reloadLibrary()
            for session in sessions where session.phase == .ready && session.stage == .waiting { cardReady(session) }
        }
        syncPrompt()
    }

    private func chooseDestination(from volumes: [VolumeInfo]) -> VolumeInfo? {
        // Development: the folder that stands in for the disk wins.
        if let fake = volumes.first(where: { $0.uuid == "debug-dest" }) { return fake }
        let uuid = Prefs.string(PrefKey.destinationUUID)
        if !uuid.isEmpty { return volumes.first { $0.uuid == uuid } }
        // First run: if exactly one disk could be the place to put things, it is that one.
        let candidates = volumes.filter { Volumes.isUsableDestination($0) && !$0.isInternal }
        guard candidates.count == 1, let only = candidates.first else { return nil }
        Prefs.defaults.set(only.uuid, forKey: PrefKey.destinationUUID)
        Prefs.defaults.set(only.name, forKey: PrefKey.destinationName)
        return only
    }

    private func chooseBackup(from volumes: [VolumeInfo]) -> VolumeInfo? {
        guard Prefs.bool(PrefKey.backupEnabled) else { return nil }
        let uuid = Prefs.string(PrefKey.backupUUID)
        return uuid.isEmpty ? nil : volumes.first { $0.uuid == uuid && $0.id != destination?.id }
    }

    /// For the pickers in the settings: disks that could be a destination.
    var destinationCandidates: [VolumeInfo] { volumes.filter { Volumes.isUsableDestination($0) } }

    func chooseDestination(_ volume: VolumeInfo) {
        Prefs.defaults.set(volume.uuid, forKey: PrefKey.destinationUUID)
        Prefs.defaults.set(volume.name, forKey: PrefKey.destinationName)
        refreshVolumes()
    }

    // MARK: Cards

    private func scan(_ session: CardSession) {
        let root = session.volume.url
        let ledger = ledger
        Task {
            // Cards need a moment after they appear before every folder can be read.
            try? await Task.sleep(for: .milliseconds(500))
            let (scan, known) = await Task.detached(priority: .userInitiated) {
                (FolderScanner.scan(root: root), ledger.knownFingerprints())
            }.value
            guard sessions.contains(where: { $0.id == session.id }) else { return }
            let review = ReviewModel(mode: .card, root: root, title: session.volume.name, items: scan.items)
            for item in scan.items { review.statuses[item.id] = ImportPlanner.status(of: item, imported: known.imported, skipped: known.skipped) }
            review.subtitle = Self.sizeText(session.volume.used)
            review.markSkipped = { [weak self] items, skip in self?.rememberSkipped(items, skip: skip, session: session) }
            review.refresh()
            session.scan = scan
            session.review = review
            session.record = ledger.card(uuid: session.volume.uuid)
            session.updateCounts()
            session.phase = .ready
            cardReady(session)
            syncPrompt()
        }
    }

    private func rememberSkipped(_ items: [MediaItem], skip: Bool, session: CardSession) {
        let entries = items.map(\.primary)
        if skip { ledger.markSkipped(entries, cardUUID: session.volume.uuid) } else { ledger.unmarkSkipped(entries) }
    }

    /// The card has been read and the disk is, or is not, there. Decides what the person is shown.
    private func cardReady(_ session: CardSession) {
        guard session.phase == .ready, session.stage == .waiting else { return }
        if session.hasNothingNew {
            if announced.insert(session.id).inserted {
                showToast(String(localized: "\(session.name): nothing new, everything is already on your disk"))
            }
            return
        }
        guard destination != nil else { return }
        guard announced.insert(session.id).inserted else { return }
        Notifier.shared.cardRecognised(name: session.name, summary: Self.recognitionSummary(session, destination: destination), uuid: session.id)
        switch Prefs.cardBehavior {
        case .review:
            openReview(session)
        case .copyAll:
            startImport(session, everything: true)
        case .ask:
            break
        }
    }

    static func recognitionSummary(_ session: CardSession, destination: VolumeInfo?) -> String {
        let amount = "\(session.newItems) " + String(localized: "new") + " (\(sizeText(session.newBytes)))"
        guard let destination else { return amount }
        return amount + ", " + String(localized: "\(sizeText(destination.available)) free on \(destination.name)")
    }

    func openReview(_ session: CardSession) {
        session.stage = .reviewing
        reviewSessionID = session.id
        page = .review
        session.review?.startEnriching()
        if Prefs.bool(PrefKey.openWindowOnCard) { WindowOpener.shared.openMain() }
        syncPrompt()
    }

    func dismiss(_ session: CardSession) {
        session.stage = .dismissed
        syncPrompt()
    }

    /// Back to the start for a card that was put away, for the person who changed their mind.
    func reconsider(_ session: CardSession) {
        session.stage = .waiting
        announced.remove(session.id)
        cardReady(session)
        syncPrompt()
    }

    func eject(_ session: CardSession) {
        let url = session.volume.url
        guard session.volume.uuid != "debug-card" else { sessions.removeAll { $0.id == session.id }; syncPrompt(); return }
        do {
            try NSWorkspace.shared.unmountAndEjectDevice(at: url)
            showToast(String(localized: "\(session.name) is safe to remove"))
            sessions.removeAll { $0.id == session.id }
        } catch {
            alert = AppAlert(title: String(localized: "The card could not be ejected"), message: error.localizedDescription)
        }
        syncPrompt()
    }

    var currentReviewSession: CardSession? {
        sessions.first { $0.id == reviewSessionID } ?? sessions.first { $0.phase == .ready && $0.stage != .imported }
    }

    // MARK: Library

    func reloadLibrary() {
        library.reload(
            destination: destination?.url, subfolder: Prefs.string(PrefKey.destinationSubfolder),
            extras: Prefs.extraFolders, index: resolve.index
        )
    }

    func refreshHistory() { history = ledger.imports() }

    // MARK: Notifications

    private func handleNotification(action: String, info: [String: String]) {
        switch action {
        case "review":
            if let id = info["card"], let session = sessions.first(where: { $0.id == id }) { openReview(session) }
        case "copyAll":
            if let id = info["card"], let session = sessions.first(where: { $0.id == id }) { startImport(session, everything: true) }
        case "reveal":
            if let folder = info["folder"] { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) }
        case "eject":
            if let id = info["card"], let session = sessions.first(where: { $0.id == id }) { eject(session) }
        default:
            if let id = info["card"], let session = sessions.first(where: { $0.id == id }), session.stage == .waiting {
                openReview(session)
            } else {
                WindowOpener.shared.openMain()
            }
        }
    }

    // MARK: Small things

    func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task {
            try? await Task.sleep(for: .seconds(3.5))
            if !Task.isCancelled { toast = nil }
        }
    }

    func syncPrompt() {
        CardPromptController.shared.sync(model: self)
    }

    static func sizeText(_ bytes: UInt64) -> String { Format.bytes(bytes) }

    // MARK: Power

    func beginWork(reason: String) {
        sleepBlocker.start(reason: reason)
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .idleSystemSleepDisabled], reason: reason)
    }

    func endWork() {
        sleepBlocker.stop()
        if let activity { ProcessInfo.processInfo.endActivity(activity) }
        activity = nil
    }
}

/// Tells the model when a disk comes or goes.
@MainActor
final class VolumeWatcher {
    var onChange: (() -> Void)?
    private var tokens: [NSObjectProtocol] = []
    private var debounce: Task<Void, Never>?

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification, NSWorkspace.didRenameVolumeNotification] {
            tokens.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.changed() }
            })
        }
        // Also by the clock: a card that is put in while the app starts, or a notification that went missing.
        Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.onChange?() }
        }
    }

    private func changed() {
        debounce?.cancel()
        debounce = Task {
            try? await Task.sleep(for: .milliseconds(700))
            if !Task.isCancelled { onChange?() }
        }
    }
}
