import CryptoKit
import Foundation

/// What Rushes has already read from the disk, kept between runs: the files of each folder, and what each file turned out to be
/// (length, camera, format). A file is known by its path, size and time, so one that did not change is never read again.
public final class LibraryCache: @unchecked Sendable {
    public static let shared = LibraryCache()

    private let lock = NSLock()
    private let directory: URL
    private var metadata: [String: MediaMetadata] = [:]
    private var analyses: [String: ClipAnalysis] = [:]
    private var dirty = false

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nl.markmaaktmedia.Rushes", isDirectory: true).appendingPathComponent("library", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: base.appendingPathComponent("metadata.json")),
           let stored = try? JSONDecoder().decode([String: MediaMetadata].self, from: data) {
            metadata = stored
        }
        if let data = try? Data(contentsOf: base.appendingPathComponent("analysis.json")),
           let stored = try? JSONDecoder().decode([String: ClipAnalysis].self, from: data) {
            analyses = stored
        }
    }

    static func key(_ entry: FileEntry, root: URL) -> String {
        "\(root.path)|\(entry.rel)|\(entry.size)|\(Int(entry.modified.timeIntervalSince1970))"
    }

    // MARK: What a file is

    public func metadata(for item: MediaItem, root: URL) -> MediaMetadata? {
        lock.lock()
        defer { lock.unlock() }
        return metadata[Self.key(item.primary, root: root)]
    }

    public func store(_ value: MediaMetadata, for item: MediaItem, root: URL) {
        lock.lock()
        metadata[Self.key(item.primary, root: root)] = value
        dirty = true
        lock.unlock()
    }

    /// What the look at a clip or photo found, for the suggestions.
    public func analysis(for item: MediaItem, root: URL) -> ClipAnalysis? {
        lock.lock()
        defer { lock.unlock() }
        return analyses[Self.key(item.primary, root: root)]
    }

    public func store(_ value: ClipAnalysis, for item: MediaItem, root: URL) {
        lock.lock()
        analyses[Self.key(item.primary, root: root)] = value
        dirty = true
        lock.unlock()
    }

    /// Writes what was learned. Cheap when nothing is new.
    public func save() {
        lock.lock()
        guard dirty else { lock.unlock(); return }
        let snapshot = metadata, looked = analyses
        dirty = false
        lock.unlock()
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: directory.appendingPathComponent("metadata.json"), options: .atomic)
        }
        if let data = try? JSONEncoder().encode(looked) {
            try? data.write(to: directory.appendingPathComponent("analysis.json"), options: .atomic)
        }
    }

    // MARK: The files of a folder

    private func scanURL(for root: URL) -> URL {
        let name = SHA256.hash(data: Data(root.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("scan-\(name).json")
    }

    public func scan(for root: URL) -> ScanResult? {
        guard let data = try? Data(contentsOf: scanURL(for: root)) else { return nil }
        return try? JSONDecoder().decode(ScanResult.self, from: data)
    }

    public func storeScan(_ scan: ScanResult) {
        if let data = try? JSONEncoder().encode(scan) { try? data.write(to: scanURL(for: scan.root), options: .atomic) }
    }

    public func clear() {
        lock.lock()
        metadata = [:]
        analyses = [:]
        dirty = false
        lock.unlock()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// The same files, by path, size and time: a folder whose scan says this has not changed.
    public static func sameFiles(_ a: [MediaItem], _ b: [MediaItem]) -> Bool {
        guard a.count == b.count else { return false }
        func keys(_ items: [MediaItem]) -> Set<String> {
            Set(items.flatMap { item in ([item.primary] + item.companions.map(\.entry)).map { "\($0.rel)|\($0.size)|\(Int($0.modified.timeIntervalSince1970))" } })
        }
        return keys(a) == keys(b)
    }
}
