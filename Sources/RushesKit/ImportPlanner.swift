import Foundation

public enum Verdict: String, Codable, Sendable {
    case undecided, keep, skip
}

public enum ItemStatus: String, Sendable {
    /// Never seen by this app.
    case new
    /// Every file of it was copied by an earlier import.
    case imported
    /// Left out on purpose the last time this card was in.
    case skippedBefore
}

public struct ImportPlan: Sendable {
    public var tasks: [CopyTask] = []
    public var keptItems: [MediaItem] = []
    public var skippedItems: [MediaItem] = []
    public var extraFiles = 0
    public var totalBytes: UInt64 { tasks.reduce(0) { $0 + $1.entry.size } }
    public var skippedBytes: UInt64 { skippedItems.reduce(0) { $0 + $1.totalBytes } }
    public var shotRange: ClosedRange<Date>?

    public init() {}
}

public enum ImportPlanner {
    /// Sorts items into new, already imported and left out before.
    public static func status(
        of item: MediaItem, imported: Set<String>, skipped: Set<String>
    ) -> ItemStatus {
        let prints = item.files.map { fingerprint($0) }
        if prints.allSatisfy({ imported.contains($0) }) { return .imported }
        if skipped.contains(fingerprint(item.primary)) { return .skippedBefore }
        return .new
    }

    private static func fingerprint(_ entry: FileEntry) -> String {
        "\(entry.rel.lowercased())|\(entry.size)|\(entry.modifiedSeconds)"
    }

    /// What to copy for the choices made. Items the person left out, and files copied before, stay home.
    /// The structure of the card (its extras) always comes along, so the folder on the disk looks like the card.
    public static func plan(
        scan: ScanResult,
        verdicts: [String: Verdict],
        imported: Set<String>,
        skipped: Set<String>,
        dates: [String: Date] = [:],
        undecidedMeansKeep: Bool = true,
        destinationPrefix: String = ""
    ) -> ImportPlan {
        var plan = ImportPlan()
        var earliest: Date?, latest: Date?

        func task(for entry: FileEntry) -> CopyTask {
            CopyTask(source: scan.root.appendingPathComponent(entry.rel), entry: entry, destinationRel: destinationPrefix + entry.rel)
        }

        for item in scan.items {
            let verdict = verdicts[item.id] ?? .undecided
            let leaveOut = verdict == .skip || (verdict == .undecided && !undecidedMeansKeep)
            let state = status(of: item, imported: imported, skipped: skipped)
            // Left out last time and not looked at again: it stays home, whatever the setting for items without a choice says.
            let stillLeftOut = state == .skippedBefore && verdict == .undecided
            if leaveOut || stillLeftOut {
                if state != .imported { plan.skippedItems.append(item) }
                continue
            }
            if state == .imported { continue }
            // A left out item that was marked keep this time is copied like any other.
            plan.keptItems.append(item)
            for file in item.files where !imported.contains(fingerprint(file)) { plan.tasks.append(task(for: file)) }
            let date = dates[item.id] ?? item.primary.created ?? item.primary.modified
            earliest = min(earliest ?? date, date)
            latest = max(latest ?? date, date)
        }
        for extra in scan.extras where !imported.contains(fingerprint(extra)) {
            plan.tasks.append(task(for: extra))
            plan.extraFiles += 1
        }
        if let earliest, let latest { plan.shotRange = earliest ... latest }
        return plan
    }
}
