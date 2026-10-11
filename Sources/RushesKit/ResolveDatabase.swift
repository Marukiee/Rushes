import Foundation

/// One project of DaVinci Resolve's local disk database.
public struct ResolveProjectFile: Hashable, Sendable {
    public let name: String
    /// Project folders it sits in, outermost first. Empty for a project in the top level.
    public let folders: [String]
    public let dbPath: String
    public let modified: Date

    public var displayName: String { (folders + [name]).joined(separator: " / ") }
}

/// What one project says about files on disk.
public struct ResolveProjectReading: Sendable {
    /// A clip on a timeline: the timeline it is on (nil inside a compound clip) and the path Resolve stored.
    public var timelineUses: [(timeline: String?, path: String)] = []
    /// The paths of everything in the media pool, used or not.
    public var poolPaths: [String] = []
}

/// Reads the project files of DaVinci Resolve without opening Resolve.
///
/// A disk database project is a SQLite file. The paths of clips on a timeline are in plain text
/// (`Sm2TiItem.MediaFilePath`). The paths of everything in the media pool are in a small
/// protobuf message in `BtVideoInfo.Clip` and `BtAudioInfo.Clip`: field 1 is the folder, field 2 the
/// file name. The file is copied first, so Resolve keeps working undisturbed and a half written
/// file can be retried.
public enum ResolveDatabase {
    public static var defaultRoots: [URL] {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Blackmagic Design/DaVinci Resolve/Resolve Project Library/Resolve Projects/Users")
        let users = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
        return users.map { $0.appendingPathComponent("Projects", isDirectory: true) }
    }

    public static func findProjects(roots: [URL]) -> [ResolveProjectFile] {
        var found: [ResolveProjectFile] = []
        for root in roots {
            let rootPath = root.standardizedFileURL.path
            guard let walker = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            ) else { continue }
            for case let url as URL in walker where url.lastPathComponent == "Project.db" {
                let folder = url.deletingLastPathComponent().standardizedFileURL
                var parts = folder.path.dropFirst(rootPath.count).split(separator: "/").map(String.init)
                guard let name = parts.popLast() else { continue }
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                found.append(ResolveProjectFile(name: name, folders: parts, dbPath: url.path, modified: modified))
            }
        }
        return found.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    public static func read(_ project: ResolveProjectFile) throws -> ResolveProjectReading {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("rushes-resolve-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let copy = scratch.appendingPathComponent("Project.db")
        try FileManager.default.copyItem(atPath: project.dbPath, toPath: copy.path)
        // A journal next to the file means Resolve was in the middle of a write; keeping it lets SQLite roll back to a sound state.
        for suffix in ["-journal", "-wal", "-shm"] where FileManager.default.fileExists(atPath: project.dbPath + suffix) {
            try? FileManager.default.copyItem(atPath: project.dbPath + suffix, toPath: copy.path + suffix)
        }
        return try read(databaseAt: copy.path)
    }

    public static func read(databaseAt path: String) throws -> ResolveProjectReading {
        let db = try SQLiteDB(path: path, readOnly: true)
        var reading = ResolveProjectReading()

        let timelineQuery = """
        SELECT t.Name, i.MediaFilePath
        FROM Sm2TiItem i
        JOIN Sm2TiTrack k ON i.Sm2TiTrack_id = k.Sm2TiTrack_id
        LEFT JOIN Sm2SequenceContainer c ON k.Sm2SequenceContainer_id = c.Sm2SequenceContainer_id
        LEFT JOIN Sm2Timeline t ON t.Sequence = c.Sm2Sequence_id
        WHERE i.MediaFilePath IS NOT NULL AND i.MediaFilePath != ''
        """
        do {
            try db.query(timelineQuery) { row in
                guard let path = row[1].text, !path.isEmpty else { return }
                reading.timelineUses.append((timeline: row[0].text, path: path))
            }
        } catch {
            // A project from a version with another layout still has its media pool.
        }

        for table in ["BtVideoInfo", "BtAudioInfo"] {
            _ = try? db.query("SELECT Clip FROM \(table) WHERE Clip IS NOT NULL") { row in
                if let blob = row[0].blob, let path = parseClipBlob(blob) { reading.poolPaths.append(path) }
            }
        }
        return reading
    }

    /// Pulls the folder and file name out of a `Clip` blob. The blob has a small header and a zstd frame around a protobuf
    /// message; for a message this short the frame holds it as is, so it is read in place.
    public static func parseClipBlob(_ blob: Data) -> String? {
        let bytes = [UInt8](blob)
        let count = bytes.count
        var index = 0
        while index < count - 3 {
            defer { index += 1 }
            guard bytes[index] == 0x0A, let (length, next) = varint(bytes, index + 1), length > 1, next + length <= count,
                  bytes[next] == 0x2F, isText(bytes[next ..< next + length]) else { continue }
            let folder = String(decoding: bytes[next ..< next + length], as: UTF8.self)
            let after = next + length
            if after < count, bytes[after] == 0x12, let (nameLength, nameStart) = varint(bytes, after + 1),
               nameLength > 0, nameStart + nameLength <= count, isText(bytes[nameStart ..< nameStart + nameLength]) {
                let name = String(decoding: bytes[nameStart ..< nameStart + nameLength], as: UTF8.self)
                return folder.hasSuffix("/") ? folder + name : folder + "/" + name
            }
            return nil
        }
        return nil
    }

    private static func varint(_ bytes: [UInt8], _ start: Int) -> (Int, Int)? {
        var result = 0, shift = 0, index = start
        while index < bytes.count, shift < 28 {
            let byte = bytes[index]
            index += 1
            result |= Int(byte & 0x7F) << shift
            if byte & 0x80 == 0 { return (result, index) }
            shift += 7
        }
        return nil
    }

    private static func isText(_ slice: ArraySlice<UInt8>) -> Bool {
        slice.allSatisfy { $0 >= 0x20 && $0 != 0x7F }
    }
}

// MARK: Index

/// What the scan of all projects found, ready to be asked "is this file used anywhere?".
public final class ResolveIndex: Codable, @unchecked Sendable {
    public struct Reference: Codable, Hashable, Sendable {
        public enum Source: String, Codable, Sendable { case timeline, pool }
        public var project: String
        public var timeline: String?
        public var source: Source
        public var card: String?
        public var volume: String?
        public var name: String
        public var count: Int

        public init(project: String, timeline: String?, source: Source, card: String?, volume: String?, name: String, count: Int) {
            self.project = project
            self.timeline = timeline
            self.source = source
            self.card = card
            self.volume = volume
            self.name = name
            self.count = count
        }
    }

    public struct ProjectInfo: Codable, Hashable, Sendable, Identifiable {
        public var name: String
        public var modified: Date
        public var timelineClips: Int
        public var poolClips: Int
        public var failed: Bool
        public var id: String { name }

        public init(name: String, modified: Date, timelineClips: Int, poolClips: Int, failed: Bool) {
            self.name = name
            self.modified = modified
            self.timelineClips = timelineClips
            self.poolClips = poolClips
            self.failed = failed
        }
    }

    public let references: [Reference]
    public let projects: [ProjectInfo]
    public let scannedAt: Date

    private var byCard: [String: [Int]] = [:]
    private var byVolume: [String: [Int]] = [:]
    private var byName: [String: [Int]] = [:]

    enum CodingKeys: String, CodingKey { case references, projects, scannedAt }

    public init(references: [Reference], projects: [ProjectInfo], scannedAt: Date = Date()) {
        self.references = references
        self.projects = projects
        self.scannedAt = scannedAt
        buildLookup()
    }

    public required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        references = try container.decode([Reference].self, forKey: .references)
        projects = try container.decode([ProjectInfo].self, forKey: .projects)
        scannedAt = try container.decode(Date.self, forKey: .scannedAt)
        buildLookup()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(references, forKey: .references)
        try container.encode(projects, forKey: .projects)
        try container.encode(scannedAt, forKey: .scannedAt)
    }

    private func buildLookup() {
        for (index, reference) in references.enumerated() {
            if let card = reference.card { byCard[card, default: []].append(index) }
            if let volume = reference.volume { byVolume[volume, default: []].append(index) }
            byName[reference.name, default: []].append(index)
        }
    }

    public static let empty = ResolveIndex(references: [], projects: [], scannedAt: .distantPast)

    /// Reads every project below the given roots. `mappings` rewrites old prefixes first (`/run/media/Mark` to `/Volumes`).
    public static func build(
        roots: [URL],
        mappings: [(from: String, to: String)] = [],
        progress: ((Int, Int) -> Void)? = nil
    ) -> ResolveIndex {
        let projects = ResolveDatabase.findProjects(roots: roots)
        var references: [Reference] = []
        var infos: [ProjectInfo] = []

        for (offset, project) in projects.enumerated() {
            progress?(offset, projects.count)
            do {
                let reading = try ResolveDatabase.read(project)
                var counts: [String: Int] = [:]
                for use in reading.timelineUses {
                    let path = remap(use.path, mappings)
                    let keys = PathKeys.make(path: path)
                    let key = "\(use.timeline ?? "")\u{1}\(keys.card ?? "")\u{1}\(keys.volumeRelative ?? "")\u{1}\(keys.name)"
                    counts[key, default: 0] += 1
                }
                for (key, count) in counts {
                    let parts = key.components(separatedBy: "\u{1}")
                    references.append(Reference(
                        project: project.displayName, timeline: parts[0].isEmpty ? nil : parts[0], source: .timeline,
                        card: parts[1].isEmpty ? nil : parts[1], volume: parts[2].isEmpty ? nil : parts[2], name: parts[3], count: count
                    ))
                }
                var pool = Set<String>()
                for path in reading.poolPaths {
                    let keys = PathKeys.make(path: remap(path, mappings))
                    let key = "\(keys.card ?? "")\u{1}\(keys.volumeRelative ?? "")\u{1}\(keys.name)"
                    guard pool.insert(key).inserted else { continue }
                    references.append(Reference(
                        project: project.displayName, timeline: nil, source: .pool,
                        card: keys.card, volume: keys.volumeRelative, name: keys.name, count: 1
                    ))
                }
                infos.append(ProjectInfo(
                    name: project.displayName, modified: project.modified,
                    timelineClips: reading.timelineUses.count, poolClips: reading.poolPaths.count, failed: false
                ))
            } catch {
                infos.append(ProjectInfo(name: project.displayName, modified: project.modified, timelineClips: 0, poolClips: 0, failed: true))
            }
        }
        progress?(projects.count, projects.count)
        return ResolveIndex(references: references, projects: infos)
    }

    static func remap(_ path: String, _ mappings: [(from: String, to: String)]) -> String {
        for mapping in mappings where path.hasPrefix(mapping.from) {
            return mapping.to + path.dropFirst(mapping.from.count)
        }
        return path
    }

    // MARK: Lookup

    public struct ProjectUse: Hashable, Sendable, Identifiable {
        public var project: String
        public var timelines: [String]
        public var clipCount: Int
        public var inPool: Bool
        public var id: String { project }

        public init(project: String, timelines: [String], clipCount: Int, inPool: Bool) {
            self.project = project
            self.timelines = timelines
            self.clipCount = clipCount
            self.inPool = inPool
        }
    }

    public enum Status: String, Sendable { case used, poolOnly, possible, unused }

    public struct Usage: Sendable {
        public var status: Status
        public var projects: [ProjectUse]

        public init(status: Status, projects: [ProjectUse]) {
            self.status = status
            self.projects = projects
        }

        public static let unused = Usage(status: .unused, projects: [])
    }

    public func usage(ofPath path: String) -> Usage {
        let keys = PathKeys.make(path: path)
        var indices = Set<Int>()
        if let card = keys.card, let hits = byCard[card] { indices.formUnion(hits) }
        if let volume = keys.volumeRelative, let hits = byVolume[volume] { indices.formUnion(hits) }

        if indices.isEmpty {
            // Same name somewhere, but no path agrees: not proof, so it only warns.
            guard let hits = byName[keys.name], !hits.isEmpty else { return .unused }
            let names = Set(hits.map { references[$0].project }).sorted()
            return Usage(status: .possible, projects: names.map { ProjectUse(project: $0, timelines: [], clipCount: 0, inPool: false) })
        }

        var perProject: [String: (timelines: Set<String>, count: Int, pool: Bool)] = [:]
        for index in indices {
            let reference = references[index]
            var entry = perProject[reference.project] ?? ([], 0, false)
            switch reference.source {
            case .timeline:
                entry.timelines.insert(reference.timeline ?? "Compound clip")
                entry.count += reference.count
            case .pool:
                entry.pool = true
            }
            perProject[reference.project] = entry
        }
        let uses = perProject.map { ProjectUse(project: $0.key, timelines: $0.value.timelines.sorted(), clipCount: $0.value.count, inPool: $0.value.pool) }
            .sorted { $0.project.localizedStandardCompare($1.project) == .orderedAscending }
        let onTimeline = uses.contains { $0.clipCount > 0 }
        return Usage(status: onTimeline ? .used : .poolOnly, projects: uses)
    }
}
