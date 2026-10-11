import AppKit
import Foundation
import RushesKit

/// What the app knows about DaVinci Resolve: which clips the projects use (read from the project files, so Resolve
/// does not have to be open) and whether Resolve can be talked to (for bins, imports and relinking).
@MainActor
@Observable
final class ResolveModel {
    enum BridgeState: Equatable {
        case unknown
        case notInstalled
        case notRunning
        case checking
        case ready(version: String, project: String?)
        case unavailable(String)
    }

    private(set) var index: ResolveIndex = .empty
    private(set) var isScanning = false
    private(set) var scanProgress: Double = 0
    private(set) var generation = 0
    var bridge: BridgeState = .unknown
    var lastScanError: String?

    private var timer: Timer?
    private var knownStamp = ""
    private let cacheURL: URL

    init(directory: URL) {
        cacheURL = directory.appendingPathComponent("resolve-index.json")
        loadCache()
    }

    var hasIndex: Bool { index.scannedAt > .distantPast }
    var projects: [ResolveIndex.ProjectInfo] { index.projects }

    var roots: [URL] {
        ResolveDatabase.defaultRoots + Prefs.resolveRoots.map { URL(fileURLWithPath: $0) }
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let cached = try? decoder.decode(ResolveIndex.self, from: data) {
            index = cached
            generation += 1
        }
    }

    private func saveCache() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(index) { try? data.write(to: cacheURL, options: .atomic) }
    }

    /// Reads all projects again. The files are copied first, so Resolve is never held up.
    func scan() async {
        guard Prefs.bool(PrefKey.resolveEnabled), !isScanning else { return }
        isScanning = true
        scanProgress = 0
        lastScanError = nil
        let roots = roots
        let mappings = Prefs.resolveMappings
        let stamp = Self.stamp(of: ResolveDatabase.findProjects(roots: roots))
        let built = await Task.detached(priority: .utility) {
            ResolveIndex.build(roots: roots, mappings: mappings) { done, total in
                Task { @MainActor in
                    if total > 0 { AppModel.shared.resolve.scanProgress = Double(done) / Double(total) }
                }
            }
        }.value
        index = built
        knownStamp = stamp
        isScanning = false
        generation += 1
        if built.projects.isEmpty {
            lastScanError = String(localized: "No DaVinci Resolve projects were found in the local database.")
        } else if built.projects.contains(where: \.failed) {
            lastScanError = String(localized: "Some projects could not be read.")
        }
        saveCache()
    }

    nonisolated private static func stamp(of projects: [ResolveProjectFile]) -> String {
        projects.map { "\($0.dbPath)@\(Int($0.modified.timeIntervalSince1970))" }.joined(separator: "|")
    }

    /// Looks at the project files now and then; a saved project in Resolve is picked up within a minute.
    func startWatching() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 45, repeats: true) { _ in
            Task { @MainActor in AppModel.shared.resolve.checkForChanges() }
        }
    }

    func checkForChanges() {
        guard Prefs.bool(PrefKey.resolveEnabled), Prefs.bool(PrefKey.resolveAutoScan), !isScanning else { return }
        let roots = roots
        let known = knownStamp
        Task {
            let current = await Task.detached { Self.stamp(of: ResolveDatabase.findProjects(roots: roots)) }.value
            if current != known { await scan() }
        }
    }

    // MARK: Talking to Resolve

    var bridgeClient: ResolveBridge { ResolveBridge(pythonPath: Prefs.string(PrefKey.pythonPath)) }

    func refreshBridge() async {
        guard Prefs.bool(PrefKey.resolveEnabled) else { bridge = .unknown; return }
        guard ResolveBridge.isResolveInstalled else { bridge = .notInstalled; return }
        guard ResolveBridge.isResolveRunning else { bridge = .notRunning; return }
        bridge = .checking
        do {
            let status = try await bridgeClient.status()
            bridge = .ready(version: status.version, project: status.project)
        } catch {
            bridge = .unavailable(error.localizedDescription)
        }
    }

    func openResolve() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ResolveBridge.resolveBundleID) else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
