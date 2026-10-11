import Foundation

public struct ScanResult: Sendable {
    public var root: URL
    public var items: [MediaItem]
    /// Everything that is not a clip or a picture: the folder structure of the card, its index files, the LUTs.
    public var extras: [FileEntry]

    public init(root: URL, items: [MediaItem], extras: [FileEntry]) {
        self.root = root
        self.items = items
        self.extras = extras
    }

    public var totalBytes: UInt64 { items.reduce(0) { $0 + $1.totalBytes } + extras.reduce(0) { $0 + $1.size } }
}

/// Reads a card or a folder and works out which files belong together.
public enum FolderScanner {
    public static func scan(root: URL, isCancelled: () -> Bool = { false }) -> ScanResult {
        let entries = enumerate(root: root, isCancelled: isCancelled)
        let (items, extras) = group(entries)
        return ScanResult(root: root, items: items, extras: extras)
    }

    public static func enumerate(root: URL, isCancelled: () -> Bool = { false }) -> [FileEntry] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants]
        ) else { return [] }
        let prefix = root.standardizedFileURL.path.hasSuffix("/") ? root.standardizedFileURL.path : root.standardizedFileURL.path + "/"
        var entries: [FileEntry] = []
        for case let url as URL in walker {
            if isCancelled() { break }
            let name = url.lastPathComponent
            if MediaTypes.isJunk(name) {
                walker.skipDescendants()
                continue
            }
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let path = url.standardizedFileURL.path
            guard path.hasPrefix(prefix) else { continue }
            entries.append(FileEntry(
                rel: String(path.dropFirst(prefix.count)),
                size: UInt64(max(0, values.fileSize ?? 0)),
                modified: values.contentModificationDate ?? Date(timeIntervalSince1970: 0),
                created: values.creationDate
            ))
        }
        return entries
    }

    /// Pure, so it can be tested with made up lists: groups files into items and leaves the rest as extras.
    public static func group(_ entries: [FileEntry]) -> (items: [MediaItem], extras: [FileEntry]) {
        var byDirAndStem: [String: [FileEntry]] = [:]
        var byFamily: [String: [FileEntry]] = [:]
        for entry in entries {
            byDirAndStem[dirStemKey(entry), default: []].append(entry)
            if let family = family(ofStem: entry.stem) { byFamily[family, default: []].append(entry) }
        }

        var used = Set<String>()
        var items: [MediaItem] = []

        // A still that has a twin (raw and JPEG) is one picture. Only the main file starts an item.
        let primaries = entries.filter { entry in
            guard MediaTypes.kind(forExtension: entry.ext) != nil, !isPreview(entry) else { return false }
            return isMainFile(entry, among: byDirAndStem[dirStemKey(entry)] ?? [])
        }

        for primary in primaries.sorted(by: { ($0.modified, $0.rel) < ($1.modified, $1.rel) }) {
            guard let kind = MediaTypes.kind(forExtension: primary.ext) else { continue }
            var companions: [MediaItem.Companion] = []
            var seen = Set<String>([primary.rel])

            func add(_ entry: FileEntry, _ role: MediaItem.CompanionRole) {
                guard seen.insert(entry.rel).inserted, !used.contains(entry.rel) else { return }
                companions.append(.init(entry: entry, role: role))
            }

            for twin in byDirAndStem[dirStemKey(primary)] ?? [] where twin.rel != primary.rel {
                if MediaTypes.kind(forExtension: twin.ext) == .photo, kind == .photo {
                    add(twin, .pair)
                } else if MediaTypes.kind(forExtension: twin.ext) != nil, !isPreview(twin) {
                    // Another clip with the same name in the same folder is its own item.
                    continue
                } else {
                    add(twin, role(of: twin))
                }
            }
            if let family = family(ofStem: primary.stem), isFamilyPrimary(primary.stem) {
                for member in byFamily[family] ?? [] where member.rel != primary.rel && !isFamilyPrimary(member.stem) {
                    add(member, role(of: member))
                }
            }
            if let twinFamily = goProFamily(ofStem: primary.stem) {
                for member in entries where member.rel != primary.rel && goProFamily(ofStem: member.stem) == twinFamily
                    && (isPreview(member) || member.ext == "thm") {
                    add(member, role(of: member))
                }
            }
            used.formUnion(seen)
            items.append(MediaItem(primary: primary, kind: kind, companions: companions))
        }

        let extras = entries.filter { !used.contains($0.rel) }.sorted { $0.rel < $1.rel }
        return (items, extras)
    }

    // MARK: Helpers

    private static func dirStemKey(_ entry: FileEntry) -> String {
        entry.directory.lowercased() + "/" + entry.stem.lowercased()
    }

    /// True for the small copies a camera makes of a clip: the folder or the extension gives them away.
    static func isPreview(_ entry: FileEntry) -> Bool {
        if MediaTypes.previewExtensions.contains(entry.ext) { return true }
        let parts = entry.directory.lowercased().split(separator: "/").map(String.init)
        return parts.contains { MediaTypes.previewFolders.contains($0) }
    }

    private static func isMainFile(_ entry: FileEntry, among twins: [FileEntry]) -> Bool {
        guard MediaTypes.kind(forExtension: entry.ext) == .photo else { return true }
        let photos = twins.filter { MediaTypes.kind(forExtension: $0.ext) == .photo && !isPreview($0) }
        guard photos.count > 1 else { return true }
        if let raw = photos.filter({ MediaTypes.raw.contains($0.ext) }).min(by: { $0.rel < $1.rel }) { return raw.rel == entry.rel }
        return photos.max(by: { ($0.size, $1.rel) < ($1.size, $0.rel) })?.rel == entry.rel
    }

    private static func role(of entry: FileEntry) -> MediaItem.CompanionRole {
        let parts = entry.directory.lowercased().split(separator: "/").map(String.init)
        if parts.contains("thmbnl") || entry.ext == "thm" { return .thumbnail }
        if parts.contains("sub") || parts.contains("proxy") || parts.contains("proxies") || entry.ext == "lrv" || entry.ext == "lrf" { return .proxy }
        if entry.ext == "xml" || entry.ext == "srt" || entry.ext == "xmp" || entry.ext == "ale" || entry.ext == "bim" { return .sidecar }
        return .other
    }

    /// Sony names a clip C0001 and everything around it C0001M01.XML, C0001S03.MP4, C0001T01.JPG.
    /// The shared part is the family. Only the clip itself has a stem that is exactly the family.
    private static func family(ofStem stem: String) -> String? {
        let upper = Array(stem.uppercased())
        guard upper.count == 5 || upper.count == 8,
              upper[0].isLetter, upper[1...4].allSatisfy(\.isNumber) else { return nil }
        if upper.count == 8 {
            guard upper[5].isLetter, upper[6...7].allSatisfy(\.isNumber) else { return nil }
        }
        return String(upper[0 ... 4])
    }

    private static func isFamilyPrimary(_ stem: String) -> Bool { stem.count == 5 }

    /// GoPro: GX010001 is the clip, GL010001.LRV its low resolution copy, GX010001.THM its thumbnail.
    private static func goProFamily(ofStem stem: String) -> String? {
        let upper = Array(stem.uppercased())
        guard upper.count == 8, upper[0] == "G", "XLHS".contains(upper[1]), upper[2...7].allSatisfy(\.isNumber) else { return nil }
        return String(upper[2...7])
    }
}
