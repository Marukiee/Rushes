import AppKit
import Foundation

public struct VolumeInfo: Hashable, Sendable, Identifiable {
    public let url: URL
    public let name: String
    public let uuid: String
    public let capacity: UInt64
    public let available: UInt64
    public let isRemovable: Bool
    public let isEjectable: Bool
    public let isInternal: Bool
    public let isReadOnly: Bool
    public let format: String

    public init(url: URL, name: String, uuid: String, capacity: UInt64, available: UInt64, isRemovable: Bool,
                isEjectable: Bool, isInternal: Bool, isReadOnly: Bool, format: String) {
        self.url = url
        self.name = name
        self.uuid = uuid
        self.capacity = capacity
        self.available = available
        self.isRemovable = isRemovable
        self.isEjectable = isEjectable
        self.isInternal = isInternal
        self.isReadOnly = isReadOnly
        self.format = format
    }

    public var id: String { uuid.isEmpty ? url.path : uuid }
    public var used: UInt64 { capacity > available ? capacity - available : 0 }

    /// Looks like the card of a camera: a known camera folder at the top, on something that can be taken out.
    public var looksLikeCard: Bool {
        guard !isInternal else { return false }
        return Self.cameraMarkers.contains { FileManager.default.fileExists(atPath: url.appendingPathComponent($0).path) }
    }

    static let cameraMarkers = [
        "DCIM", "PRIVATE/M4ROOT", "PRIVATE/AVCHD", "AVF_INFO", "BPAV", "CONTENTS/CLIPS", "XDROOT", "MP_ROOT", "CLIPS001", "PRIVATE/XDROOT",
    ]
}

public enum Volumes {
    static let keys: [URLResourceKey] = [
        .volumeNameKey, .volumeUUIDStringKey, .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey,
        .volumeAvailableCapacityKey, .volumeIsRemovableKey, .volumeIsEjectableKey, .volumeIsInternalKey,
        .volumeIsReadOnlyKey, .volumeLocalizedFormatDescriptionKey, .volumeIsLocalKey,
    ]

    public static func mounted() -> [VolumeInfo] {
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap(info(for:))
    }

    public static func info(for url: URL) -> VolumeInfo? {
        guard let values = try? url.resourceValues(forKeys: Set(keys)), values.volumeIsLocal ?? true else { return nil }
        let path = url.standardizedFileURL.path
        // The system volume and its helpers are never a card or a destination.
        if path == "/" || path.hasPrefix("/System") || path.hasPrefix("/private") { return nil }
        return VolumeInfo(
            url: url.standardizedFileURL,
            name: values.volumeName ?? url.lastPathComponent,
            uuid: values.volumeUUIDString ?? "",
            capacity: UInt64(max(0, values.volumeTotalCapacity ?? 0)),
            available: UInt64(max(0, values.volumeAvailableCapacityForImportantUsage ?? Int64(values.volumeAvailableCapacity ?? 0))),
            isRemovable: values.volumeIsRemovable ?? false,
            isEjectable: values.volumeIsEjectable ?? false,
            isInternal: values.volumeIsInternal ?? false,
            isReadOnly: values.volumeIsReadOnly ?? false,
            format: values.volumeLocalizedFormatDescription ?? ""
        )
    }

    /// A volume that is plausible as the disk to copy to: writable, not the card itself, with room to speak of.
    public static func isUsableDestination(_ volume: VolumeInfo) -> Bool {
        !volume.isReadOnly && !volume.looksLikeCard && volume.capacity > 8 * 1024 * 1024 * 1024
    }
}
