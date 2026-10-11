import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

public final class CGImageBox {
    public let image: CGImage
    public init(_ image: CGImage) { self.image = image }
}

/// Pictures of clips and photos, from the cheapest source available: the thumbnail the camera wrote,
/// the small proxy, the preview inside a raw file, and only then the clip itself.
public actor Thumbnailer {
    public static let shared = Thumbnailer()

    private let memory = NSCache<NSString, CGImageBox>()
    private let directory: URL

    public init(directory: URL? = nil) {
        let base = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nl.markmaaktmedia.Rushes", isDirectory: true).appendingPathComponent("thumbs", isDirectory: true)
        self.directory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        memory.countLimit = 600
    }

    public func image(for item: MediaItem, root: URL, maxPixel: Int, at fraction: Double = 0.12) async -> CGImage? {
        let key = cacheKey(item: item, root: root, maxPixel: maxPixel, fraction: fraction)
        if let hit = memory.object(forKey: key as NSString) { return hit.image }
        let file = directory.appendingPathComponent(key + ".jpg")
        if let cached = Self.decode(file, maxPixel: maxPixel) {
            memory.setObject(CGImageBox(cached), forKey: key as NSString)
            return cached
        }
        guard let made = await render(item: item, root: root, maxPixel: maxPixel, fraction: fraction) else { return nil }
        Self.write(made, to: file)
        memory.setObject(CGImageBox(made), forKey: key as NSString)
        return made
    }

    /// Frames spread over a clip, for moving over a thumbnail to look through it.
    public func strip(for item: MediaItem, root: URL, count: Int, maxPixel: Int) async -> [CGImage] {
        guard item.kind == .video else {
            if let single = await image(for: item, root: root, maxPixel: maxPixel) { return [single] }
            return []
        }
        let key = cacheKey(item: item, root: root, maxPixel: maxPixel, fraction: -Double(count))
        if let hit = memory.object(forKey: key as NSString) { return [hit.image] }
        let source = playbackSource(of: item, root: root)
        let asset = AVURLAsset(url: source)
        guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else { return [] }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let times = (0 ..< count).map { CMTime(seconds: duration.seconds * (Double($0) + 0.5) / Double(count), preferredTimescale: 600) }
        var frames: [Int: CGImage] = [:]
        for await result in generator.images(for: times) {
            if case let .success(requestedTime, image, _) = result,
               let index = times.firstIndex(where: { CMTimeCompare($0, requestedTime) == 0 }) {
                frames[index] = image
            }
        }
        return frames.sorted { $0.key < $1.key }.map(\.value)
    }

    /// True when the file that plays is the camera's proxy, which needs no LUT.
    public func isProxyPlayback(of item: MediaItem, root: URL) -> Bool {
        playbackSource(of: item, root: root) != root.appendingPathComponent(item.primary.rel)
    }

    public func playbackSource(of item: MediaItem, root: URL) -> URL {
        if let proxy = item.companion(.proxy), MediaTypes.kind(forExtension: proxy.ext) == .video {
            return root.appendingPathComponent(proxy.rel)
        }
        return root.appendingPathComponent(item.primary.rel)
    }

    // MARK: Rendering

    private func render(item: MediaItem, root: URL, maxPixel: Int, fraction: Double) async -> CGImage? {
        switch item.kind {
        case .photo:
            if let pair = item.companions.first(where: { $0.role == .pair }), !MediaTypes.raw.contains(pair.entry.ext),
               let image = Self.imageIO(root.appendingPathComponent(pair.entry.rel), maxPixel: maxPixel, always: false) {
                return image
            }
            return Self.imageIO(root.appendingPathComponent(item.primary.rel), maxPixel: maxPixel, always: false)
                ?? Self.imageIO(root.appendingPathComponent(item.primary.rel), maxPixel: maxPixel, always: true)
        case .video:
            // A proxy already has the look of the camera in it, where the camera's own thumbnail of a log clip is flat grey.
            // So the proxy comes first, and that thumbnail only when there is nothing else cheap to look at.
            if item.companion(.proxy) == nil, maxPixel <= 360, let thumb = item.companion(.thumbnail),
               let image = Self.imageIO(root.appendingPathComponent(thumb.rel), maxPixel: maxPixel, always: false) {
                return image
            }
            return await frame(of: playbackSource(of: item, root: root), maxPixel: maxPixel, fraction: fraction)
        case .audio:
            return nil
        }
    }

    public func frame(of url: URL, maxPixel: Int, fraction: Double) async -> CGImage? {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        generator.requestedTimeToleranceBefore = .positiveInfinity
        generator.requestedTimeToleranceAfter = .positiveInfinity
        let duration = (try? await asset.load(.duration))?.seconds ?? 0
        let time = CMTime(seconds: duration.isFinite && duration > 0 ? duration * fraction : 0, preferredTimescale: 600)
        return try? await generator.image(at: time).image
    }

    static func imageIO(_ url: URL, maxPixel: Int, always: Bool) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: always,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    // MARK: Disk cache

    private func cacheKey(item: MediaItem, root: URL, maxPixel: Int, fraction: Double) -> String {
        let text = "\(root.path)|\(item.primary.fingerprint)|\(maxPixel)|\(fraction)"
        return SHA256.hash(data: Data(text.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    private static func decode(_ url: URL, maxPixel: Int) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return imageIO(url, maxPixel: maxPixel * 2, always: false)
    }

    private static func write(_ image: CGImage, to url: URL) {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        CGImageDestinationFinalize(destination)
    }

    public func clearCache() {
        memory.removeAllObjects()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func cacheSize() -> UInt64 {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        return files.reduce(0) { $0 + UInt64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }
}
