import AppKit
import Foundation
import RushesKit

enum ReviewKindFilter: String, CaseIterable, Identifiable {
    case all, video, photo
    var id: String { rawValue }
}

enum ReviewStateFilter: String, CaseIterable, Identifiable {
    case all, undecided, keep, skip, suggested
    // Library only.
    case unused, used, protected, duplicates
    var id: String { rawValue }
}

struct ReviewSection: Identifiable {
    let id: String
    let day: Date
    var items: [MediaItem]
}

/// Everything about one pass over a set of clips and photos: the card that has just been put in, or a folder on the disk.
///
/// On a card, "skip" means "do not copy this". In the library it means "move this to the Trash" and "keep" means "protect
/// this from every suggestion". The view is the same in both; the two differ only in what the verdict does.
@MainActor
@Observable
final class ReviewModel {
    enum Mode { case card, library }

    struct UndoStep {
        var verdicts: [String: Verdict] = [:]
        var trashed: [(item: MediaItem, moved: [TrashService.Moved])] = []
        var text: String
    }

    let mode: Mode
    let root: URL
    var title: String
    var subtitle = ""

    private(set) var allItems: [MediaItem]
    var verdicts: [String: Verdict] = [:]
    var ratings: [String: Int] = [:]
    private(set) var metadata: [String: MediaMetadata] = [:]
    private(set) var analysis: [String: ClipAnalysis] = [:]
    private(set) var suggestions: [String: Suggestion] = [:]
    /// Card: what the ledger says about each item.
    var statuses: [String: ItemStatus] = [:]
    /// Library: what DaVinci Resolve says about each item.
    var usage: [String: ResolveIndex.Usage] = [:]
    var duplicates: Set<String> = []

    var kindFilter: ReviewKindFilter = .all
    var stateFilter: ReviewStateFilter = .all
    var showKnown = false
    /// Set by the grid, so the up and down keys move by a row.
    var gridColumns = 3

    var selection: Set<String> = []
    var focusID: String?
    private(set) var visible: [MediaItem] = []
    private(set) var sections: [ReviewSection] = []
    private(set) var undoStack: [UndoStep] = []
    var message: String?
    private(set) var enriching = false
    private(set) var enrichDone = 0

    /// Library: how to move files to the Trash. Set by the owner.
    var trashHandler: (([MediaItem]) -> [(item: MediaItem, moved: [TrashService.Moved])])?
    var restoreHandler: (([(item: MediaItem, moved: [TrashService.Moved])]) -> Void)?
    var persistChoice: ((MediaItem, Verdict?, Int) -> Void)?
    var markSkipped: (([MediaItem], Bool) -> Void)?

    private var enrichTask: Task<Void, Never>?
    private let probeLimit = 4

    init(mode: Mode, root: URL, title: String, items: [MediaItem]) {
        self.mode = mode
        self.root = root
        self.title = title
        allItems = items
        refresh()
    }

    // MARK: Reading

    func date(of item: MediaItem) -> Date {
        metadata[item.id]?.captureDate ?? item.primary.created ?? item.primary.modified
    }

    func item(_ id: String?) -> MediaItem? {
        guard let id else { return nil }
        return allItems.first { $0.id == id }
    }

    var focusItem: MediaItem? { item(focusID) }

    func verdict(of item: MediaItem) -> Verdict { verdicts[item.id] ?? .undecided }

    func status(of item: MediaItem) -> ItemStatus { statuses[item.id] ?? .new }

    func counts() -> (keep: Int, skip: Int, undecided: Int, suggested: Int) {
        var keep = 0, skip = 0, undecided = 0, suggested = 0
        for item in allItems where isActionable(item) {
            switch verdict(of: item) {
            case .keep: keep += 1
            case .skip: skip += 1
            case .undecided: undecided += 1
            }
            if suggestions[item.id] != nil, verdict(of: item) == .undecided { suggested += 1 }
        }
        return (keep, skip, undecided, suggested)
    }

    func bytes(for verdict: Verdict) -> UInt64 {
        allItems.filter { isActionable($0) && self.verdict(of: $0) == verdict }.reduce(0) { $0 + $1.totalBytes }
    }

    /// On a card, items already copied are not up for a choice unless the person asks to see them.
    func isActionable(_ item: MediaItem) -> Bool {
        mode == .library || showKnown || status(of: item) == .new
    }

    var actionableCount: Int { allItems.filter(isActionable).count }

    // MARK: Filtering

    func refresh() {
        let filtered = allItems.filter { item in
            guard isActionable(item) else { return false }
            switch kindFilter {
            case .all: break
            case .video: if item.kind != .video { return false }
            case .photo: if item.kind != .photo { return false }
            }
            switch stateFilter {
            case .all: return true
            case .undecided: return verdict(of: item) == .undecided
            case .keep: return verdict(of: item) == .keep
            case .skip: return verdict(of: item) == .skip
            case .suggested: return suggestions[item.id] != nil
            case .unused: return usage[item.id]?.status == .unused && verdict(of: item) != .keep
            case .used: return usage[item.id].map { $0.status == .used || $0.status == .poolOnly } ?? false
            case .protected: return verdict(of: item) == .keep
            case .duplicates: return duplicates.contains(item.id)
            }
        }
        visible = filtered.sorted { (date(of: $0), $0.id) < (date(of: $1), $1.id) }

        let calendar = Calendar.current
        var grouped: [Date: [MediaItem]] = [:]
        for item in visible { grouped[calendar.startOfDay(for: date(of: item)), default: []].append(item) }
        sections = grouped.keys.sorted().map { day in
            ReviewSection(id: String(day.timeIntervalSince1970), day: day, items: grouped[day] ?? [])
        }
        selection = selection.filter { id in visible.contains { $0.id == id } }
        if let focusID, !visible.contains(where: { $0.id == focusID }) { self.focusID = nil }
        if focusID == nil, let first = visible.first { focus(first.id) }
    }

    func focus(_ id: String?, extend: Bool = false, toggle: Bool = false) {
        guard let id else { focusID = nil; selection = []; return }
        if extend, let anchor = focusID, let a = visible.firstIndex(where: { $0.id == anchor }),
           let b = visible.firstIndex(where: { $0.id == id }) {
            selection = Set(visible[min(a, b) ... max(a, b)].map(\.id))
            focusID = id
        } else if toggle {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            focusID = id
        } else {
            selection = [id]
            focusID = id
        }
    }

    func move(_ step: Int, extend: Bool = false) {
        guard !visible.isEmpty else { return }
        let index = visible.firstIndex { $0.id == focusID } ?? (step > 0 ? -1 : visible.count)
        let target = min(visible.count - 1, max(0, index + step))
        focus(visible[target].id, extend: extend)
    }

    /// The clips that follow the one in view, for a look ahead.
    func upcoming(_ count: Int) -> [MediaItem] {
        guard let index = visible.firstIndex(where: { $0.id == focusID }) else { return Array(visible.prefix(count)) }
        return Array(visible.dropFirst(index + 1).prefix(count))
    }

    var focusPosition: Int? { visible.firstIndex(where: { $0.id == focusID }).map { $0 + 1 } }

    func moveToNextUndecided() {
        guard let index = visible.firstIndex(where: { $0.id == focusID }) else { return }
        let rest = visible[(index + 1)...] + visible[..<index]
        if let next = rest.first(where: { verdict(of: $0) == .undecided }) { focus(next.id) }
    }

    // MARK: Verdicts

    private var targets: [MediaItem] {
        let ids = selection.isEmpty ? (focusID.map { [$0] } ?? []) : Array(selection)
        let wanted = Set(ids)
        return visible.filter { wanted.contains($0.id) }
    }

    func set(_ verdict: Verdict, advance: Bool = true) {
        let affected = targets
        guard !affected.isEmpty else { return }
        let previousFocus = focusID
        let wasLast = affected.contains { $0.id == visible.last?.id }

        if mode == .library, verdict == .skip {
            trash(affected)
            return
        }
        var before: [String: Verdict] = [:]
        for item in affected {
            before[item.id] = self.verdict(of: item)
            if verdict == .undecided { verdicts.removeValue(forKey: item.id) } else { verdicts[item.id] = verdict }
            persistChoice?(item, verdict == .undecided ? nil : verdict, ratings[item.id] ?? 0)
        }
        markSkipped?(affected, verdict == .skip)
        undoStack.append(UndoStep(verdicts: before, text: Self.text(for: verdict, count: affected.count)))
        trimUndo()
        refresh()
        if advance, Prefs.bool(PrefKey.advanceAfterVerdict), affected.count == 1 {
            // After the item that was just judged, whether or not it is still in the filtered list.
            if let previousFocus, let old = allItems.firstIndex(where: { $0.id == previousFocus }) {
                let following = allItems[(old + 1)...].first { visible.contains($0) }
                if let following { focus(following.id) } else if wasLast, let last = visible.last { focus(last.id) }
            }
        }
    }

    private static func text(for verdict: Verdict, count: Int) -> String {
        switch verdict {
        case .keep: String(localized: "Kept \(count)")
        case .skip: String(localized: "Left out \(count)")
        case .undecided: String(localized: "Cleared \(count)")
        }
    }

    func rate(_ stars: Int) {
        for item in targets {
            ratings[item.id] = stars == 0 ? nil : stars
            persistChoice?(item, verdicts[item.id], stars)
        }
    }

    func applySuggestions() {
        let chosen = visible.filter { suggestions[$0.id] != nil && verdict(of: $0) == .undecided }
        guard !chosen.isEmpty else { return }
        var before: [String: Verdict] = [:]
        for item in chosen {
            before[item.id] = .undecided
            verdicts[item.id] = .skip
        }
        markSkipped?(chosen, true)
        undoStack.append(UndoStep(verdicts: before, text: String(localized: "Left out \(chosen.count) suggested")))
        refresh()
    }

    func keepAllUndecided() {
        let chosen = visible.filter { verdict(of: $0) == .undecided }
        var before: [String: Verdict] = [:]
        for item in chosen {
            before[item.id] = .undecided
            verdicts[item.id] = .keep
        }
        undoStack.append(UndoStep(verdicts: before, text: String(localized: "Kept \(chosen.count)")))
        refresh()
    }

    func clearAll() {
        guard !verdicts.isEmpty else { return }
        undoStack.append(UndoStep(verdicts: verdicts, text: String(localized: "Cleared all")))
        let skipped = allItems.filter { verdicts[$0.id] == .skip }
        markSkipped?(skipped, false)
        verdicts = [:]
        refresh()
    }

    private func trimUndo() {
        if undoStack.count > 200 { undoStack.removeFirst(undoStack.count - 200) }
    }

    // MARK: Library: moving to the Trash

    /// Moves these to the Trash, for a clean up of many at once.
    func trashItems(_ items: [MediaItem]) { trash(items) }

    private func trash(_ items: [MediaItem]) {
        guard let trashHandler else { return }
        let focusIndex = visible.firstIndex { $0.id == focusID }
        let done = trashHandler(items)
        guard !done.isEmpty else {
            message = String(localized: "Could not move to the Trash")
            return
        }
        let gone = Set(done.map(\.item.id))
        allItems.removeAll { gone.contains($0.id) }
        undoStack.append(UndoStep(trashed: done, text: String(localized: "Moved \(done.count) to the Trash")))
        message = String(localized: "Moved \(done.count) to the Trash")
        refresh()
        // The next one opens by itself, which is the point of the whole page.
        if let focusIndex, !visible.isEmpty { focus(visible[min(focusIndex, visible.count - 1)].id) }
    }

    func undo() {
        guard let step = undoStack.popLast() else { return }
        if !step.trashed.isEmpty {
            restoreHandler?(step.trashed)
            allItems.append(contentsOf: step.trashed.map(\.item))
            message = String(localized: "Put back \(step.trashed.count)")
        } else {
            for (id, verdict) in step.verdicts {
                if verdict == .undecided { verdicts.removeValue(forKey: id) } else { verdicts[id] = verdict }
                if let item = item(id) { persistChoice?(item, verdict == .undecided ? nil : verdict, ratings[id] ?? 0) }
            }
            let reverted = step.verdicts.keys.compactMap { item($0) }
            markSkipped?(reverted.filter { verdict(of: $0) != .skip }, false)
            message = String(localized: "Undone: \(step.text)")
        }
        refresh()
    }

    var canUndo: Bool { !undoStack.isEmpty }

    /// Items that came back from outside, or went away because the disk changed.
    func replaceItems(_ items: [MediaItem]) {
        allItems = items
        refresh()
    }

    // MARK: Enrichment

    /// Reads dates, durations and cameras, then looks at the clips to suggest what can go. Runs in the background.
    func startEnriching() {
        enrichTask?.cancel()
        enriching = true
        enrichDone = 0
        let items = allItems
        let root = root
        // Suggestions are for a card that is about to be copied. A folder on the disk only needs dates and durations.
        var settings = Prefs.suggestions
        if mode == .library { settings.enabled = false }
        enrichTask = Task { [weak self] in
            var pending = items.makeIterator()
            await withTaskGroup(of: (String, MediaMetadata, ClipAnalysis?).self) { group in
                func next() -> MediaItem? { pending.next() }
                for _ in 0 ..< (self?.probeLimit ?? 4) {
                    guard let item = next() else { break }
                    group.addTask { await Self.work(item, root: root, analyse: settings.enabled) }
                }
                while let (id, meta, analysis) = await group.next() {
                    if Task.isCancelled { break }
                    await MainActor.run {
                        guard let self else { return }
                        self.metadata[id] = meta
                        if let analysis { self.analysis[id] = analysis }
                        self.enrichDone += 1
                        if self.enrichDone % 25 == 0 { self.recomputeSuggestions(settings) }
                    }
                    if let item = next() {
                        group.addTask { await Self.work(item, root: root, analyse: settings.enabled) }
                    }
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.recomputeSuggestions(settings)
                self.enriching = false
                self.refresh()
            }
        }
    }

    func stopEnriching() {
        enrichTask?.cancel()
        enriching = false
    }

    private static func work(_ item: MediaItem, root: URL, analyse: Bool) async -> (String, MediaMetadata, ClipAnalysis?) {
        let meta = await MediaProbe.probe(item, root: root)
        guard analyse, item.kind != .audio else { return (item.id, meta, nil) }
        return (item.id, meta, await ClipAnalyzer.analyze(item, root: root))
    }

    private func recomputeSuggestions(_ settings: SuggestionSettings) {
        guard mode == .card else { return }
        let inputs = allItems.map { item in
            SuggestionEngine.Input(id: item.id, kind: item.kind, date: date(of: item), duration: metadata[item.id]?.duration, analysis: analysis[item.id])
        }
        suggestions = SuggestionEngine.evaluate(inputs, settings: settings)
        // The date of an item is better known now, so the order and the days may have changed.
        refresh()
    }

    func detectDuplicates(using hashes: [String: String]) {
        var seen: [String: [String]] = [:]
        for (id, hash) in hashes { seen[hash, default: []].append(id) }
        duplicates = Set(seen.values.filter { $0.count > 1 }.flatMap { $0 })
    }

    // MARK: Paths

    func url(of item: MediaItem) -> URL { root.appendingPathComponent(item.primary.rel) }

    /// The camera's own LUT when the clip names one and it is on the card or disk, found below the root.
    func lutURL(for item: MediaItem) -> URL? {
        guard let name = metadata[item.id]?.lutFile else { return nil }
        let fm = FileManager.default
        let direct = root.appendingPathComponent("PRIVATE/M4ROOT/GENERAL/LUT").appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        return nil
    }
}
