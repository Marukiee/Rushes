import Foundation
import RushesKit

/// A card that is in the Mac: what is on it, what is new, and the choices made while looking through it.
@MainActor
@Observable
final class CardSession: Identifiable {
    enum Phase: Equatable {
        case scanning
        case ready
        case failed(String)
    }

    /// Where the card is in its dealings with the person.
    enum Stage: Equatable {
        /// Just put in, nothing decided.
        case waiting
        /// The person looked at the card and no import has started.
        case reviewing
        case importing
        case imported
        /// Closed away by the person. Comes back by itself only when the card is put in again.
        case dismissed
    }

    let volume: VolumeInfo
    var phase: Phase = .scanning
    var stage: Stage = .waiting
    var scan: ScanResult?
    var review: ReviewModel?
    var record: Ledger.CardRecord?

    var newItems = 0
    var newBytes: UInt64 = 0
    var knownItems = 0
    var skippedBefore = 0
    var scannedFiles = 0
    var startedAt = Date()

    var id: String { volume.id }
    var name: String { volume.name }

    init(volume: VolumeInfo) {
        self.volume = volume
    }

    var hasNothingNew: Bool { phase == .ready && newItems == 0 }

    func updateCounts() {
        guard let review else { return }
        let fresh = review.allItems.filter { review.status(of: $0) == .new }
        newItems = fresh.count
        newBytes = fresh.reduce(0) { $0 + $1.totalBytes }
        knownItems = review.allItems.filter { review.status(of: $0) == .imported }.count
        skippedBefore = review.allItems.filter { review.status(of: $0) == .skippedBefore }.count
    }
}

/// A flag that a copy running on another thread can poll.
final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func set() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

/// One import while it runs and after it has finished.
@MainActor
@Observable
final class ImportJob: Identifiable {
    enum Phase: Equatable {
        case preparing
        case copying
        case finishing
        case done
        case failed(String)
        case cancelled
    }

    struct ResolveOutcome: Equatable {
        var message: String
        var failed: Bool
    }

    let id = UUID()
    let cardName: String
    let cardUUID: String
    let startedAt = Date()
    var phase: Phase = .preparing
    var progress: CopyProgress?
    var folderName: String
    var folder: URL
    var backupFolder: URL?
    var plan: ImportPlan
    var report: CopyReport?
    var recordID: Int64 = 0
    var duration: TimeInterval = 0
    var needsName = false
    var ejected = false
    var resolve: ResolveOutcome?
    var integrityNote: String?
    var request = ImportRequest()
    let cancelFlag = CancelFlag()

    init(cardName: String, cardUUID: String, folderName: String, folder: URL, plan: ImportPlan) {
        self.cardName = cardName
        self.cardUUID = cardUUID
        self.folderName = folderName
        self.folder = folder
        self.plan = plan
    }

    var isRunning: Bool {
        switch phase {
        case .preparing, .copying, .finishing: true
        default: false
        }
    }

    var failedFiles: [FailedFile] { report?.failed ?? [] }
    var copiedCount: Int { report?.copied.count ?? 0 }
    var copiedBytes: UInt64 { report?.bytes ?? 0 }

    func cancel() { cancelFlag.set() }
}
