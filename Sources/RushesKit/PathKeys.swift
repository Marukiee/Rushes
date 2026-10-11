import Foundation

/// Turns a file path into keys that stay the same when the disk is mounted somewhere else, or the
/// folder is renamed after the card number.
///
/// DaVinci Resolve remembers the path a clip had when it was imported. Those paths come from
/// another system (`/run/media/Mark/4TB SSD/...` on Linux), from before a folder was renamed, or
/// from a folder that has moved up one level. Matching on the whole path would call all of them
/// unused. The key that survives all of that is the card number plus the path inside the card.
public struct PathKeys: Hashable, Sendable {
    /// `sd4|private/m4root/clip/c2631.mp4`: independent of the disk and of what follows the number.
    public var card: String?
    /// The path from the disk onwards: `projecten/film/beelden/a.mov`.
    public var volumeRelative: String?
    /// File name only. A weak match, shown as "possibly used" and never as a certainty.
    public var name: String

    public static func make(path: String, extraVolumeNames: [String] = []) -> PathKeys {
        let normalised = path.precomposedStringWithCanonicalMapping.replacingOccurrences(of: "\\", with: "/")
        let parts = normalised.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let name = (parts.last ?? normalised).lowercased()

        var card: String?
        for (index, part) in parts.enumerated().dropLast() {
            if let number = cardNumber(in: part) {
                let rest = parts[(index + 1)...].joined(separator: "/").lowercased()
                card = "sd\(number)|\(rest)"
                break
            }
        }

        var volumeRelative: String?
        if let start = volumeStart(parts: parts), start < parts.count - 1 {
            volumeRelative = parts[start...].joined(separator: "/").lowercased()
        }
        return PathKeys(card: card, volumeRelative: volumeRelative, name: name)
    }

    /// "SD 4", "SD4", "sd 4 Zomervakantie" give 4. "SD kaarten" and "SDHC" give nothing.
    public static func cardNumber(in component: String) -> Int? {
        let lower = component.lowercased()
        guard lower.hasPrefix("sd") else { return nil }
        var rest = lower.dropFirst(2)
        while rest.first == " " || rest.first == "_" || rest.first == "-" { rest = rest.dropFirst() }
        let digits = rest.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 4 else { return nil }
        let after = rest.dropFirst(digits.count)
        guard after.isEmpty || !(after.first?.isNumber ?? false) else { return nil }
        return Int(digits)
    }

    /// The index of the first component after the name of the disk, for the places a disk can be mounted.
    static func volumeStart(parts: [String]) -> Int? {
        guard parts.count >= 3 else { return nil }
        switch parts[0] {
        case "Volumes": return 2
        case "run" where parts.count > 4 && parts[1] == "media": return 4
        case "media" where parts.count > 3: return 3
        case "mnt": return 2
        default: return nil
        }
    }
}
