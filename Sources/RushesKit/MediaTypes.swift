import Foundation

public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case video, photo, audio
}

/// What a file is, going by its extension. Cameras agree on very little, so this stays a list of
/// the formats that actually turn up on cards, and everything else is treated as card structure.
public enum MediaTypes {
    public static let video: Set<String> = [
        "mp4", "mov", "mxf", "mts", "m2ts", "avi", "mkv", "m4v", "mpg", "mpeg", "braw", "r3d", "ari", "crm", "webm", "insv", "360",
    ]
    public static let photo: Set<String> = [
        "arw", "sr2", "srf", "jpg", "jpeg", "hif", "heic", "heif", "cr2", "cr3", "crw", "nef", "nrw", "dng", "raf", "orf", "rw2",
        "pef", "srw", "x3f", "gpr", "png", "tif", "tiff",
    ]
    public static let audio: Set<String> = ["wav", "mp3", "m4a", "aac", "aif", "aiff", "flac", "bwf"]
    /// Raw stills: when a raw and a JPEG share a name they are one picture, and the raw is the main file.
    public static let raw: Set<String> = [
        "arw", "sr2", "srf", "cr2", "cr3", "crw", "nef", "nrw", "dng", "raf", "orf", "rw2", "pef", "srw", "x3f", "gpr",
    ]
    /// Small files a camera writes next to a clip as a preview or a proxy. They are never an item of their own.
    public static let previewExtensions: Set<String> = ["lrv", "lrf", "thm"]
    /// Folders that hold previews of the clips elsewhere on the card.
    public static let previewFolders: Set<String> = ["sub", "thmbnl", "proxy", "proxies"]

    public static func kind(forExtension ext: String) -> MediaKind? {
        let ext = ext.lowercased()
        if video.contains(ext) { return .video }
        if photo.contains(ext) { return .photo }
        if audio.contains(ext) { return .audio }
        return nil
    }

    /// Names the system and the card's filesystem leave behind. None of it belongs on the disk.
    public static func isJunk(_ name: String) -> Bool {
        if name.hasPrefix("._") || name == ".DS_Store" { return true }
        switch name {
        case ".Spotlight-V100", ".fseventsd", ".Trashes", ".TemporaryItems", "System Volume Information",
             "$RECYCLE.BIN", ".DocumentRevisions-V100", ".VolumeIcon.icns", "Thumbs.db", ".rushes":
            return true
        default:
            return name.hasSuffix(".rushes-part")
        }
    }
}

/// One file as found on a card or a disk.
public struct FileEntry: Hashable, Sendable, Codable {
    public let rel: String
    public let size: UInt64
    public let modified: Date
    public let created: Date?

    public init(rel: String, size: UInt64, modified: Date, created: Date?) {
        self.rel = rel
        self.size = size
        self.modified = modified
        self.created = created
    }

    public var name: String { (rel as NSString).lastPathComponent }
    public var ext: String { (rel as NSString).pathExtension.lowercased() }
    public var stem: String { ((rel as NSString).lastPathComponent as NSString).deletingPathExtension }
    public var directory: String { (rel as NSString).deletingLastPathComponent }

    /// Whole seconds, because the cards use FAT-style clocks that round differently from the disk they are copied to.
    public var modifiedSeconds: Int64 { Int64(modified.timeIntervalSince1970.rounded(.down)) }

    /// What the ledger uses to recognise a file it has already handled.
    public var fingerprint: String { "\(rel.lowercased())|\(size)|\(modifiedSeconds)" }
}

/// A clip or a picture together with the small files that belong to it.
public struct MediaItem: Identifiable, Hashable, Sendable, Codable {
    public enum CompanionRole: String, Sendable, Codable { case sidecar, proxy, thumbnail, pair, other }

    public struct Companion: Hashable, Sendable, Codable {
        public let entry: FileEntry
        public let role: CompanionRole
    }

    public let primary: FileEntry
    public let kind: MediaKind
    public var companions: [Companion]

    public var id: String { primary.rel }

    public init(primary: FileEntry, kind: MediaKind, companions: [Companion] = []) {
        self.primary = primary
        self.kind = kind
        self.companions = companions
    }

    public var totalBytes: UInt64 { primary.size + companions.reduce(0) { $0 + $1.entry.size } }
    public var name: String { primary.name }
    public var files: [FileEntry] { [primary] + companions.map(\.entry) }

    public func companion(_ role: CompanionRole) -> FileEntry? { companions.first { $0.role == role }?.entry }
}
