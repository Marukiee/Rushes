import Foundation
import ImageIO

/// What can be put on the files of a card instead of copying them.
public enum CardMark: String, Sendable, CaseIterable {
    /// Five stars, the rating every photo app and Lightroom can filter on.
    case stars
    /// A green label, which Lightroom, Bridge and Capture One show as a colour.
    case flag
}

/// Writes a rating or a label next to a file on the card, in an XMP sidecar (`DSC0001.xmp` next to `DSC0001.ARW`). The original
/// file is never changed: its name, size and time are what Rushes knows it by, and a raw file is not something to write into.
public enum CardMarker {
    public static let label = "Green"

    public struct Existing: Sendable, Equatable {
        public var rating: Int?
        public var label: String?
    }

    public static func sidecarURL(for item: MediaItem, root: URL) -> URL {
        root.appendingPathComponent(item.primary.rel).deletingPathExtension().appendingPathExtension("xmp")
    }

    /// The rating and label a file already has: in its sidecar, or for a photo inside the file, where a camera puts the stars
    /// given on the camera itself.
    public static func existing(_ item: MediaItem, root: URL) -> Existing {
        var found = Existing()
        if let text = try? String(contentsOf: sidecarURL(for: item, root: root), encoding: .utf8) {
            found.rating = value(of: "xmp:Rating", in: text).flatMap { Int($0) }
            found.label = value(of: "xmp:Label", in: text)
        }
        if found.rating == nil, item.kind == .photo {
            let urls = [item.primary.rel] + item.companions.filter { $0.role == .pair }.map(\.entry.rel)
            for rel in urls {
                guard let source = CGImageSourceCreateWithURL(root.appendingPathComponent(rel) as CFURL, nil),
                      let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) else { continue }
                if let rating = CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String?,
                   let stars = Int(rating) {
                    found.rating = stars
                    break
                }
            }
        }
        // Zero stars is how some apps write "no rating", and a rejected photo is -1. Neither is a rating to keep.
        if let rating = found.rating, rating <= 0 { found.rating = nil }
        return found
    }

    /// Puts the mark on an item. Returns false when it already had it.
    @discardableResult
    public static func write(_ mark: CardMark, to item: MediaItem, root: URL) throws -> Bool {
        let url = sidecarURL(for: item, root: root)
        let key = mark == .stars ? "xmp:Rating" : "xmp:Label"
        let wanted = mark == .stars ? "5" : label
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? emptyPacket
        if value(of: key, in: text) == wanted { return false }
        text = setting(key, to: wanted, in: text)
        try Data(text.utf8).write(to: url, options: .atomic)
        return true
    }

    // MARK: XMP text

    static let emptyPacket = """
    <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
    <x:xmpmeta xmlns:x="adobe:ns:meta/" x:xmptk="Rushes">
     <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
      <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/"/>
     </rdf:RDF>
    </x:xmpmeta>
    <?xpacket end="w"?>

    """

    /// A property as an attribute (`xmp:Rating="5"`) or as an element (`<xmp:Rating>5</xmp:Rating>`), both of which XMP allows.
    static func value(of key: String, in text: String) -> String? {
        let name = NSRegularExpression.escapedPattern(for: key)
        for pattern in ["\(name)\\s*=\\s*\"([^\"]*)\"", "<\(name)>([^<]*)</\(name)>"] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
               let range = Range(match.range(at: 1), in: text) {
                return String(text[range]).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }

    static func setting(_ key: String, to value: String, in text: String) -> String {
        let name = NSRegularExpression.escapedPattern(for: key)
        for (pattern, template) in [
            ("\(name)\\s*=\\s*\"[^\"]*\"", "\(key)=\"\(value)\""),
            ("<\(name)>[^<]*</\(name)>", "<\(key)>\(value)</\(key)>"),
        ] {
            if let regex = try? NSRegularExpression(pattern: pattern),
               regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil {
                return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
            }
        }
        // Not there yet: an attribute on the first description, with the namespace when that description does not have it.
        guard let start = text.range(of: "<rdf:Description") else { return text }
        var addition = " \(key)=\"\(value)\""
        let tagEnd = text[start.upperBound...].firstIndex(of: ">") ?? text.endIndex
        if !text[start.lowerBound ..< tagEnd].contains("xmlns:xmp=") { addition = " xmlns:xmp=\"http://ns.adobe.com/xap/1.0/\"" + addition }
        var result = text
        result.insert(contentsOf: addition, at: start.upperBound)
        return result
    }
}
