import AVFoundation
import Foundation
import ImageIO

public struct MediaMetadata: Codable, Sendable, Hashable {
    public var captureDate: Date?
    public var duration: Double?
    public var width: Int?
    public var height: Int?
    public var fps: Double?
    public var codec: String?
    public var camera: String?
    public var lens: String?
    public var iso: Int?
    public var shutter: String?
    public var aperture: Double?
    public var focalLength: Double?
    /// "s-log3-cine" and the like, from the camera's own notes next to the clip.
    public var gamma: String?
    public var lutFile: String?
    public var hasGPS = false

    public init() {}

    public var isLog: Bool { (gamma ?? "").lowercased().contains("log") }

    public var resolution: String? {
        guard let width, let height else { return nil }
        return "\(width) x \(height)"
    }

    public var frameRateText: String? {
        guard let fps else { return nil }
        return fps.rounded() == fps ? "\(Int(fps)) fps" : String(format: "%.2f fps", fps)
    }
}

/// The notes Sony cameras write in an XML file next to every clip (`C0001M01.XML`): when it was
/// shot, with what, in which gamma, and which LUT belongs with it.
public enum SonyClipXML {
    public static func parse(_ data: Data) -> MediaMetadata {
        let reader = Reader()
        let parser = XMLParser(data: data)
        parser.delegate = reader
        parser.parse()
        return reader.metadata
    }

    private final class Reader: NSObject, XMLParserDelegate {
        var metadata = MediaMetadata()
        private var frames: Double?
        private var formatFps: Double?

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes attributeDict: [String: String] = [:]) {
            switch name {
            case "CreationDate":
                if let value = attributeDict["value"] { metadata.captureDate = Self.date(value) }
            case "Duration":
                frames = attributeDict["value"].flatMap(Double.init)
            case "VideoFrame":
                metadata.codec = attributeDict["videoCodec"].map(Self.codecName)
                formatFps = attributeDict["formatFps"].flatMap { Double($0.filter { $0.isNumber || $0 == "." }) }
                metadata.fps = formatFps
            case "VideoLayout":
                metadata.width = attributeDict["pixel"].flatMap(Int.init)
                metadata.height = attributeDict["numOfVerticalLine"].flatMap(Int.init)
            case "Device":
                metadata.camera = attributeDict["modelName"]
            case "Lens":
                metadata.lens = attributeDict["modelName"]
            case "Item":
                if attributeDict["name"] == "CaptureGammaEquation" { metadata.gamma = attributeDict["value"] }
            case "RelatedTo":
                if attributeDict["rel"] == "LUT" { metadata.lutFile = attributeDict["file"] }
            default: break
            }
        }

        func parserDidEndDocument(_ parser: XMLParser) {
            if let frames, let rate = formatFps, rate > 0 { metadata.duration = frames / rate }
        }

        static func date(_ text: String) -> Date? {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: text)
        }

        /// "AVC140_3840_2160_H422P@L51" becomes "AVC 4:2:2 intra".
        static func codecName(_ raw: String) -> String {
            let upper = raw.uppercased()
            let family = upper.hasPrefix("HEVC") ? "HEVC" : (upper.hasPrefix("AVC") ? "AVC" : (upper.components(separatedBy: "_").first ?? raw))
            if upper.contains("H422") { return "\(family) 4:2:2" }
            if upper.contains("H420") || upper.contains("HP") { return "\(family) 4:2:0" }
            return family
        }
    }
}

public enum MediaProbe {
    /// Everything that can be learned about an item without playing it. Cheap enough to run for a whole card.
    public static func probe(_ item: MediaItem, root: URL) async -> MediaMetadata {
        var metadata = MediaMetadata()
        if let sidecar = item.companion(.sidecar), sidecar.ext == "xml",
           let data = try? Data(contentsOf: root.appendingPathComponent(sidecar.rel)) {
            metadata = SonyClipXML.parse(data)
        }
        let url = root.appendingPathComponent(item.primary.rel)
        switch item.kind {
        case .photo:
            mergeImage(url, into: &metadata)
        case .video:
            await mergeVideo(url, into: &metadata)
        case .audio:
            if let asset = Optional(AVURLAsset(url: url)), let duration = try? await asset.load(.duration) {
                metadata.duration = duration.seconds
            }
        }
        if metadata.captureDate == nil { metadata.captureDate = item.primary.created ?? item.primary.modified }
        return metadata
    }

    static func mergeImage(_ url: URL, into metadata: inout MediaMetadata) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return }
        metadata.width = properties[kCGImagePropertyPixelWidth] as? Int
        metadata.height = properties[kCGImagePropertyPixelHeight] as? Int
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        metadata.camera = tiff[kCGImagePropertyTIFFModel] as? String
        metadata.lens = exif[kCGImagePropertyExifLensModel] as? String
        metadata.iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first
        metadata.aperture = exif[kCGImagePropertyExifFNumber] as? Double
        metadata.focalLength = exif[kCGImagePropertyExifFocalLength] as? Double
        if let exposure = exif[kCGImagePropertyExifExposureTime] as? Double, exposure > 0 {
            metadata.shutter = exposure >= 1 ? String(format: "%.1f s", exposure) : "1/\(Int((1 / exposure).rounded())) s"
        }
        metadata.hasGPS = properties[kCGImagePropertyGPSDictionary] != nil
        if let text = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            if let offset = exif["OffsetTimeOriginal" as CFString] as? String, let zone = TimeZone(iso8601Offset: offset) {
                formatter.timeZone = zone
            }
            metadata.captureDate = formatter.date(from: text)
        }
    }

    static func mergeVideo(_ url: URL, into metadata: inout MediaMetadata) async {
        // The sidecar already says it all for a Sony clip, and reading it is much cheaper than opening the video.
        if metadata.duration != nil, metadata.width != nil, metadata.codec != nil { return }
        let asset = AVURLAsset(url: url)
        if metadata.duration == nil, let duration = try? await asset.load(.duration), duration.isNumeric {
            metadata.duration = duration.seconds
        }
        if let track = try? await asset.loadTracks(withMediaType: .video).first {
            if let size = try? await track.load(.naturalSize), metadata.width == nil {
                metadata.width = Int(size.width)
                metadata.height = Int(size.height)
            }
            if metadata.fps == nil, let rate = try? await track.load(.nominalFrameRate), rate > 0 { metadata.fps = Double(rate) }
            if metadata.codec == nil, let descriptions = try? await track.load(.formatDescriptions), let first = descriptions.first {
                metadata.codec = fourCC(CMFormatDescriptionGetMediaSubType(first))
            }
        }
        if metadata.captureDate == nil, let date = try? await asset.load(.creationDate), let value = try? await date.load(.dateValue) {
            metadata.captureDate = value
        }
    }

    static func fourCC(_ code: FourCharCode) -> String {
        let bytes = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF), UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        let text = String(decoding: bytes, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        switch text {
        case "avc1": return "AVC"
        case "hvc1", "hev1": return "HEVC"
        case "apcn", "apch", "apcs", "apco", "ap4h": return "ProRes"
        default: return text
        }
    }
}

extension TimeZone {
    init?(iso8601Offset text: String) {
        let sign = text.hasPrefix("-") ? -1 : 1
        let digits = text.filter { $0.isNumber }
        guard digits.count >= 4, let hours = Int(digits.prefix(2)), let minutes = Int(digits.dropFirst(2).prefix(2)) else { return nil }
        self.init(secondsFromGMT: sign * (hours * 3600 + minutes * 60))
    }
}
