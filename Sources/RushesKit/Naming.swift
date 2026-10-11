import Foundation

/// Names for the folder of a card and for the bin in DaVinci Resolve.
public enum CardNaming {
    /// The number after the highest one in use, by the ledger and by the folders that are on the disk.
    public static func nextNumber(ledgerHighest: Int, existingFolders: [String]) -> Int {
        let onDisk = existingFolders.compactMap { PathKeys.cardNumber(in: $0) }.max() ?? 0
        return max(ledgerHighest, onDisk) + 1
    }

    public static func folderName(number: Int, name: String?) -> String {
        let clean = sanitize(name ?? "")
        return clean.isEmpty ? "SD \(number)" : "SD \(number) \(clean)"
    }

    /// What can be in a folder name on an exFAT disk, also when the folder is read on Windows or Linux.
    public static func sanitize(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters)
        let cleaned = name.components(separatedBy: forbidden).joined(separator: " ")
        return cleaned.split(separator: " ").joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    }

    /// Tokens: {datum} the day of shooting, {importdatum}, {sd} like "SD 5", {naam} what was added to the folder name, {jaar}, {maand}.
    public static func binName(template: String, day: Date?, importDate: Date, sd: String, name: String?) -> String {
        let dayText = format(day ?? importDate, "yyyy-MM-dd")
        var result = template
        let replacements: [String: String] = [
            "{datum}": dayText,
            "{importdatum}": format(importDate, "yyyy-MM-dd"),
            "{sd}": sd,
            "{naam}": sanitize(name ?? ""),
            "{jaar}": format(day ?? importDate, "yyyy"),
            "{maand}": format(day ?? importDate, "MM"),
        ]
        for (token, value) in replacements { result = result.replacingOccurrences(of: token, with: value) }
        let tidy = result.split(separator: " ").joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return tidy.isEmpty ? dayText : tidy
    }

    public static func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }
}

/// A list of the hashes of everything in a card folder, kept inside the folder. It is what lets the folder be checked
/// again a year later, on this disk or on a copy of it.
public struct Manifest: Codable, Sendable {
    public struct Entry: Codable, Sendable, Hashable {
        public var path: String
        public var size: UInt64
        public var sha256: String

        public init(path: String, size: UInt64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public var version = 1
    public var folder: String
    public var updated: Date
    public var entries: [Entry]

    public static func url(in folder: URL) -> URL {
        folder.appendingPathComponent(".rushes", isDirectory: true).appendingPathComponent("manifest.json")
    }

    public static func load(from folder: URL) -> Manifest? {
        guard let data = try? Data(contentsOf: url(in: folder)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Manifest.self, from: data)
    }

    /// Adds entries to what is there, a path that is already listed gets the new hash.
    public static func merge(_ entries: [Entry], into folder: URL) throws {
        var manifest = load(from: folder) ?? Manifest(folder: folder.lastPathComponent, updated: Date(), entries: [])
        var byPath = Dictionary(uniqueKeysWithValues: manifest.entries.map { ($0.path, $0) })
        for entry in entries { byPath[entry.path] = entry }
        manifest.entries = byPath.values.sorted { $0.path < $1.path }
        manifest.updated = Date()
        manifest.folder = folder.lastPathComponent
        let target = url(in: folder)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: target, options: .atomic)
    }
}

extension Manifest {
    /// Takes files out of the list, after they were moved to the Trash on purpose.
    public static func remove(_ paths: [String], from folder: URL) {
        guard var manifest = load(from: folder) else { return }
        let gone = Set(paths)
        manifest.entries.removeAll { gone.contains($0.path) }
        manifest.updated = Date()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(manifest).write(to: url(in: folder), options: .atomic)
    }
}

public struct IntegrityReport: Sendable {
    public var checked = 0
    public var ok = 0
    public var changed: [String] = []
    public var missing: [String] = []
    public var cancelled = false
    public var isClean: Bool { changed.isEmpty && missing.isEmpty && !cancelled }
}

public enum IntegrityChecker {
    /// Reads every file of the manifest and compares it. Blocks, so call it from a background thread.
    public static func verify(folder: URL, progress: ((Int, Int) -> Void)? = nil, isCancelled: () -> Bool = { false }) -> IntegrityReport? {
        guard let manifest = Manifest.load(from: folder) else { return nil }
        var report = IntegrityReport()
        for (index, entry) in manifest.entries.enumerated() {
            if isCancelled() { report.cancelled = true; break }
            progress?(index, manifest.entries.count)
            let url = folder.appendingPathComponent(entry.path)
            guard FileManager.default.fileExists(atPath: url.path) else { report.missing.append(entry.path); continue }
            report.checked += 1
            if let hash = try? FileCopier.hashFile(url, noCache: true), hash == entry.sha256 {
                report.ok += 1
            } else {
                report.changed.append(entry.path)
            }
        }
        progress?(manifest.entries.count, manifest.entries.count)
        return report
    }
}
