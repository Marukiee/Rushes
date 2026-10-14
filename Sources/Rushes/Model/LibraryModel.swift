import Foundation
import RushesKit

/// The folders of the disk and what DaVinci Resolve does with the clips in them.
@MainActor
@Observable
final class LibraryModel {
    struct Folder: Identifiable {
        let url: URL
        var name: String
        var number: Int?
        var review: ReviewModel
        var itemCount = 0
        var totalBytes: UInt64 = 0
        var usedBytes: UInt64 = 0
        var reclaimableBytes: UInt64 = 0
        var reclaimableCount = 0
        var possibleCount = 0
        var hasManifest = false
        var loadedAt = Date()

        var id: String { url.path }
    }

    private(set) var folders: [Folder] = []
    private(set) var isLoading = false
    private(set) var loadedCount = 0
    var selectedID: String? {
        didSet { if oldValue != nil, oldValue != selectedID { userChose = true } }
    }
    private var userChose = false

    private var ledger: Ledger?
    private var loadTask: Task<Void, Never>?

    func attach(ledger: Ledger) { self.ledger = ledger }

    var selected: Folder? { folders.first { $0.id == selectedID } }

    var totalBytes: UInt64 { folders.reduce(0) { $0 + $1.totalBytes } }
    var reclaimableBytes: UInt64 { folders.reduce(0) { $0 + $1.reclaimableBytes } }
    var reclaimableCount: Int { folders.reduce(0) { $0 + $1.reclaimableCount } }
    var usedBytes: UInt64 { folders.reduce(0) { $0 + $1.usedBytes } }

    // MARK: Loading

    /// Finds the card folders on the disk and reads them one after the other, so the disk is never read in many places at once.
    func reload(destination: URL?, subfolder: String, extras: [String], index: ResolveIndex) {
        loadTask?.cancel()
        var roots: [URL] = []
        if let destination {
            let base = subfolder.isEmpty ? destination : destination.appendingPathComponent(subfolder, isDirectory: true)
            let children = (try? FileManager.default.contentsOfDirectory(
                at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            )) ?? []
            roots += children.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .filter { PathKeys.cardNumber(in: $0.lastPathComponent) != nil }
                .sorted { ($0.lastPathComponent).localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        }
        roots += extras.map { URL(fileURLWithPath: $0, isDirectory: true) }.filter { FileManager.default.fileExists(atPath: $0.path) }

        isLoading = true
        loadedCount = 0
        let previous = Dictionary(uniqueKeysWithValues: folders.map { ($0.id, $0) })
        folders = folders.filter { folder in roots.contains { $0.path == folder.id } }
        loadTask = Task { [weak self] in
            for root in roots {
                if Task.isCancelled { break }
                let scan = await Task.detached(priority: .utility) { FolderScanner.scan(root: root) }.value
                if Task.isCancelled { break }
                guard let self else { return }
                // The index of the moment, not the one from when the loading began: the projects may have been read since.
                self.add(scan: scan, previous: previous[root.path], index: AppModel.shared.resolve.index)
                self.loadedCount += 1
            }
            self?.isLoading = false
            if let self { self.applyUsage(index: AppModel.shared.resolve.index) }
            self?.chooseStartingFolder()
            self?.findDuplicates()
        }
    }

    private func add(scan: ScanResult, previous: Folder?, index: ResolveIndex) {
        let name = scan.root.lastPathComponent
        let review = previous?.review ?? ReviewModel(mode: .library, root: scan.root, title: name, items: scan.items)
        review.replaceItems(scan.items)
        review.subtitle = scan.root.deletingLastPathComponent().lastPathComponent
        configure(review, root: scan.root, name: name)
        var folder = Folder(
            url: scan.root, name: name, number: PathKeys.cardNumber(in: name), review: review,
            hasManifest: Manifest.load(from: scan.root) != nil
        )
        applyUsage(to: &folder, index: index)
        if let at = folders.firstIndex(where: { $0.id == folder.id }) { folders[at] = folder } else { folders.append(folder) }
        folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        if selectedID == nil { selectedID = folders.first?.id }
        review.startEnriching()
    }

    /// The folder that has the most to give back, or else the newest one, so the page opens on something worth looking at.
    private func chooseStartingFolder() {
        guard !userChose else { return }
        if let best = folders.max(by: { $0.reclaimableBytes < $1.reclaimableBytes }), best.reclaimableBytes > 0 {
            selectedID = best.id
        } else if let newest = folders.last(where: { $0.itemCount > 0 }) {
            selectedID = newest.id
        }
    }

    private func configure(_ review: ReviewModel, root: URL, name: String) {
        let key: (MediaItem) -> String = { item in Self.choiceKey(folder: name, rel: item.primary.rel) }
        let choices = ledger?.allChoices() ?? [:]
        // What was chosen while the card was in carries over to its folder: a keep protects, a leave out is offered to clean up.
        let cardChoices = ledger?.cardChoices() ?? [:]
        let fingerprints = ledger?.cardFingerprintsByDestination() ?? [:]
        var cardKeys: [String: String] = [:]
        var leftOut = Set<String>()
        for item in review.allItems {
            let fingerprint = fingerprints[root.appendingPathComponent(item.primary.rel).path]
            if let fingerprint { cardKeys[item.id] = fingerprint }
            let own = choices[key(item)]
            let card = fingerprint.flatMap { cardChoices[$0] }
            if own?.verdict == "keep" || (own == nil && card?.verdict == "keep") {
                review.verdicts[item.id] = .keep
            } else if card?.verdict == "skip" {
                leftOut.insert(item.id)
            }
            let stars = (own?.rating ?? 0) > 0 ? (own?.rating ?? 0) : (card?.rating ?? 0)
            if stars > 0 { review.ratings[item.id] = stars }
        }
        review.leftOutOnCard = leftOut
        review.persistChoice = { [weak self, weak review] item, verdict, rating in
            guard let self else { return }
            self.ledger?.setChoice(key: key(item), verdict: verdict == .keep ? "keep" : nil, rating: rating)
            // The memory of the card follows, so the two never disagree when the card comes back.
            guard let fingerprint = cardKeys[item.id], let entry = Self.entry(fingerprint: fingerprint) else { return }
            if verdict == .keep { review?.leftOutOnCard.remove(item.id) }
            let stillLeftOut = review?.leftOutOnCard.contains(item.id) == true
            self.ledger?.setCardChoice(entry, verdict: verdict == .keep ? "keep" : (stillLeftOut ? "skip" : nil), rating: rating)
        }
        review.trashHandler = { [weak self] items in self?.trash(items, in: root) ?? [] }
        review.restoreHandler = { [weak self] done in self?.restore(done, in: root) }
        review.refresh()
    }

    /// A fingerprint back into the file it stands for, enough for the ledger to find its choice.
    private static func entry(fingerprint: String) -> FileEntry? {
        let parts = fingerprint.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count >= 3, let size = UInt64(parts[parts.count - 2]), let seconds = Double(parts[parts.count - 1]) else { return nil }
        let rel = parts.dropLast(2).joined(separator: "|")
        return FileEntry(rel: rel, size: size, modified: Date(timeIntervalSince1970: seconds), created: nil)
    }

    static func choiceKey(folder: String, rel: String) -> String {
        if let number = PathKeys.cardNumber(in: folder) { return "sd\(number)|\(rel.lowercased())" }
        return "folder|\(folder.lowercased())|\(rel.lowercased())"
    }

    // MARK: Usage

    func applyUsage(index: ResolveIndex) {
        for at in folders.indices { applyUsage(to: &folders[at], index: index) }
    }

    private func applyUsage(to folder: inout Folder, index: ResolveIndex) {
        let review = folder.review
        let photosCount = Prefs.bool(PrefKey.photosInSavings)
        var usage: [String: ResolveIndex.Usage] = [:]
        var total: UInt64 = 0, used: UInt64 = 0, reclaim: UInt64 = 0, reclaimCount = 0, possible = 0
        let hasIndex = index.scannedAt > .distantPast
        for item in review.allItems {
            total += item.totalBytes
            guard hasIndex else { continue }
            let result = index.usage(ofPath: review.url(of: item).path)
            usage[item.id] = result
            switch result.status {
            case .used, .poolOnly: used += item.totalBytes
            case .possible: possible += 1
            case .unused:
                if review.verdicts[item.id] != .keep, item.kind == .video || photosCount {
                    reclaim += item.totalBytes
                    reclaimCount += 1
                }
            }
        }
        review.usage = usage
        review.refresh()
        folder.itemCount = review.allItems.count
        folder.totalBytes = total
        folder.usedBytes = used
        folder.reclaimableBytes = reclaim
        folder.reclaimableCount = reclaimCount
        folder.possibleCount = possible
    }

    func recount(index: ResolveIndex) { applyUsage(index: index) }

    private func findDuplicates() {
        guard let ledger else { return }
        let hashes = ledger.hashesByDestination()
        for folder in folders {
            var byHash: [String: String] = [:]
            for item in folder.review.allItems {
                if let hash = hashes[folder.review.url(of: item).path] { byHash[item.id] = hash }
            }
            folder.review.detectDuplicates(using: byHash)
        }
    }

    // MARK: Trash

    private func trash(_ items: [MediaItem], in root: URL) -> [(item: MediaItem, moved: [TrashService.Moved])] {
        var done: [(MediaItem, [TrashService.Moved])] = []
        for item in items {
            let urls = item.files.map { root.appendingPathComponent($0.rel) }
            let result = TrashService.trash(urls)
            if result.failed.isEmpty { done.append((item, result.moved)) } else {
                TrashService.restore(result.moved)
            }
        }
        Manifest.remove(items.filter { item in done.contains { $0.0.id == item.id } }.flatMap { $0.files.map(\.rel) }, from: root)
        refreshStats()
        return done.map { (item: $0.0, moved: $0.1) }
    }

    private func restore(_ done: [(item: MediaItem, moved: [TrashService.Moved])], in root: URL) {
        for entry in done { TrashService.restore(entry.moved) }
        refreshStats()
    }

    /// After files came or went, so the totals follow.
    func refreshStats() {
        let index = AppModel.shared.resolve.index
        Task { @MainActor in
            for at in folders.indices {
                let review = folders[at].review
                // Totals only from what is still there.
                folders[at].itemCount = review.allItems.count
                folders[at].totalBytes = review.allItems.reduce(0) { $0 + $1.totalBytes }
            }
            applyUsage(index: index)
        }
    }

    func folder(named name: String) -> Folder? { folders.first { $0.name == name } }
}
