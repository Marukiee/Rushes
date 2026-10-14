import AppKit
import Foundation
import RushesKit

enum ReviewKindFilter: String, CaseIterable, Identifiable {
    case all, video, photo
    var id: String { rawValue }
}

enum ReviewStateFilter: String, CaseIterable, Identifiable {
    case all, undecided, keep, skip, suggested
    // Card only.
    case notOnDisk, onDisk
    // Library only.
    case unused, used, protected, duplicates, leftOut
    var id: String { rawValue }
}

/// Which star ratings to show: all, the ones without stars, or from some number of stars up.
enum ReviewRatingFilter: Hashable {
    case any, unrated
    case atLeast(Int)
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
        var ratings: [String: Int] = [:]
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
    /// Card: what was on the disk, or left out, when the card came in. It stays out of the way unless asked for. What is copied
    /// while the card is in stays in view, so the choices made for it can still be seen and changed.
    var knownAtStart: Set<String> = []
    /// Library: what DaVinci Resolve says about each item.
    var usage: [String: ResolveIndex.Usage] = [:]
    var duplicates: Set<String> = []
    /// Library: what was left out while the card was in, and was copied anyway. The disk only needs what was kept.
    var leftOutOnCard: Set<String> = []
    /// A reset of many choices at once waits for a yes.
    var pendingReset: ResetRequest?

    struct ResetRequest: Identifiable {
        let id = UUID()
        let title: String
        let items: [MediaItem]
    }

    var kindFilter: ReviewKindFilter = .all
    var stateFilter: ReviewStateFilter = .all
    var ratingFilter: ReviewRatingFilter = .any
    var showKnown = false
    /// Set by the grid, so the up and down keys move by a row.
    var gridColumns = 3

    var selection: Set<String> = []
    var focusID: String?
    /// False until the person picks something, so the one in view follows the order as it settles (dates are read after the
    /// first look at the list) instead of staying on whatever happened to come first.
    private var userChose = false
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

    /// On a card, what was already handled before it came in is not up for a choice unless the person asks to see it.
    func isActionable(_ item: MediaItem) -> Bool {
        mode == .library || showKnown || !knownAtStart.contains(item.id)
    }

    /// Card: every file of it is on the disk already.
    func isOnDisk(_ item: MediaItem) -> Bool { mode == .card && status(of: item) == .imported }

    /// What a copy would take now: what is chosen (or everything) of the right kind that is not on the disk yet.
    func toCopy(kinds: CopyKinds, undecidedMeansKeep: Bool, everything: Bool = false, only: Set<String>? = nil) -> (count: Int, bytes: UInt64) {
        var count = 0
        var bytes: UInt64 = 0
        for item in allItems where isActionable(item) && kinds.includes(item.kind) && status(of: item) != .imported {
            if let only, !only.contains(item.id) { continue }
            let verdict = verdict(of: item)
            if !everything {
                if verdict == .skip { continue }
                if verdict == .undecided, !undecidedMeansKeep || status(of: item) == .skippedBefore { continue }
            }
            count += 1
            bytes += item.totalBytes
        }
        return (count, bytes)
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
            let stars = ratings[item.id] ?? 0
            switch ratingFilter {
            case .any: break
            case .unrated: if stars > 0 { return false }
            case let .atLeast(minimum): if stars < minimum { return false }
            }
            switch stateFilter {
            case .all: return true
            case .undecided: return verdict(of: item) == .undecided
            case .keep: return verdict(of: item) == .keep
            case .skip: return verdict(of: item) == .skip
            case .suggested: return suggestions[item.id] != nil
            case .notOnDisk: return status(of: item) != .imported
            case .onDisk: return status(of: item) == .imported
            case .leftOut: return leftOutOnCard.contains(item.id)
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
        if let first = visible.first, (!userChose && focusID != first.id) || focusID == nil {
            // A filter that takes away the clip in view lands on the first of what is left, so the picture is never empty.
            selection = [first.id]
            focusID = first.id
        }
    }

    func focus(_ id: String?, extend: Bool = false, toggle: Bool = false) {
        userChose = true
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

    /// What a choice applies to: the selection, or else the one in view.
    var targets: [MediaItem] {
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
        change(affected, to: verdict, text: Self.text(for: verdict, count: affected.count))
        if advance, Prefs.bool(PrefKey.advanceAfterVerdict), affected.count == 1 {
            // After the item that was just judged, whether or not it is still in the filtered list.
            if let previousFocus, let old = allItems.firstIndex(where: { $0.id == previousFocus }) {
                let following = allItems[(old + 1)...].first { visible.contains($0) }
                if let following { focus(following.id) } else if wasLast, let last = visible.last { focus(last.id) }
            }
        }
    }

    /// Every change of a choice goes through here, so it is remembered, can be undone and shows at once.
    private func change(_ items: [MediaItem], to verdict: Verdict, resetStars: Bool = false, text: String) {
        guard !items.isEmpty else { return }
        var before: [String: Verdict] = [:]
        var stars: [String: Int] = [:]
        for item in items {
            before[item.id] = self.verdict(of: item)
            stars[item.id] = ratings[item.id] ?? 0
            if verdict == .undecided { verdicts.removeValue(forKey: item.id) } else { verdicts[item.id] = verdict }
            if resetStars { ratings[item.id] = nil }
            persistChoice?(item, verdict == .undecided ? nil : verdict, ratings[item.id] ?? 0)
        }
        markSkipped?(items, verdict == .skip)
        undoStack.append(UndoStep(verdicts: before, ratings: resetStars ? stars : [:], text: text))
        trimUndo()
        refresh()
    }

    /// Back to the start for the ones in hand: no choice and no stars.
    func reset() {
        let affected = targets
        change(affected, to: .undecided, resetStars: true, text: String(localized: "Reset \(affected.count)"))
        message = String(localized: "Reset \(affected.count)")
    }

    func reset(_ items: [MediaItem]) {
        change(items, to: .undecided, resetStars: true, text: String(localized: "Reset \(items.count)"))
        message = String(localized: "Reset \(items.count)")
    }

    // MARK: Days

    /// Everything of one day that is up for a choice, whatever the filter shows.
    func items(ofDay day: Date) -> [MediaItem] {
        let calendar = Calendar.current
        return allItems.filter { isActionable($0) && calendar.isDate(date(of: $0), inSameDayAs: day) }
    }

    func selectDay(_ section: ReviewSection) {
        userChose = true
        selection = Set(section.items.map(\.id))
        if let focusID, selection.contains(focusID) { return }
        focusID = section.items.first?.id
    }

    func setDay(_ section: ReviewSection, to verdict: Verdict) {
        change(section.items, to: verdict, text: Self.text(for: verdict, count: section.items.count))
    }

    private static func text(for verdict: Verdict, count: Int) -> String {
        switch verdict {
        case .keep: String(localized: "Kept \(count)")
        case .skip: String(localized: "Left out \(count)")
        case .undecided: String(localized: "Cleared \(count)")
        }
    }

    func rate(_ stars: Int) {
        let affected = targets
        var before: [String: Int] = [:]
        for item in affected { before[item.id] = ratings[item.id] ?? 0 }
        if !affected.isEmpty {
            undoStack.append(UndoStep(ratings: before, text: String(localized: "Stars for \(affected.count)")))
            trimUndo()
        }
        for item in affected {
            ratings[item.id] = stars == 0 ? nil : stars
            persistChoice?(item, verdicts[item.id], stars)
        }
    }

    func applySuggestions() {
        let chosen = visible.filter { suggestions[$0.id] != nil && verdict(of: $0) == .undecided }
        change(chosen, to: .skip, text: String(localized: "Left out \(chosen.count) suggested"))
    }

    func keepAllUndecided() {
        let chosen = visible.filter { verdict(of: $0) == .undecided }
        change(chosen, to: .keep, text: String(localized: "Kept \(chosen.count)"))
    }

    func clearAll() {
        let chosen = allItems.filter { isActionable($0) && verdicts[$0.id] != nil }
        change(chosen, to: .undecided, text: String(localized: "Cleared all"))
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
            }
            for (id, stars) in step.ratings { ratings[id] = stars == 0 ? nil : stars }
            for id in Set(step.verdicts.keys).union(step.ratings.keys) {
                if let item = item(id) { persistChoice?(item, verdicts[id], ratings[id] ?? 0) }
            }
            let reverted = step.verdicts.keys.compactMap { item($0) }
            markSkipped?(reverted.filter { verdict(of: $0) != .skip }, false)
            markSkipped?(reverted.filter { verdict(of: $0) == .skip }, true)
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

    /// The look to play an original log clip with in a thumbnail, once the notes of the camera are known. Nil for a clip with a proxy.
    func look(for item: MediaItem) -> CubeLUT? {
        guard item.kind == .video, item.companion(.proxy) == nil, let meta = metadata[item.id] else { return nil }
        return Look.lut(for: meta, root: root, mode: Prefs.lutMode.look)
    }

    /// The camera's own LUT when the clip names one and it is on the card or disk, found below the root.
    func lutURL(for item: MediaItem) -> URL? {
        guard let name = metadata[item.id]?.lutFile else { return nil }
        let fm = FileManager.default
        let direct = root.appendingPathComponent("PRIVATE/M4ROOT/GENERAL/LUT").appendingPathComponent(name)
        if fm.fileExists(atPath: direct.path) { return direct }
        return nil
    }
}
