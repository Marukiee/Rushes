import AVFoundation
import CoreImage
import Foundation

/// Whether a log clip is shown with a look on it, and which.
public enum LookMode: String, Sendable {
    case off, auto, builtIn
}

/// The look that makes a log clip watchable: the LUT the camera names, or a standard S-Log3 one. A proxy has the look in it
/// already, so this is only for the original.
public enum Look {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var parsed: [String: CubeLUT] = [:]
    nonisolated(unsafe) private static var standard: CubeLUT?
    private static let context = CIContext()

    public static func standardSLog3() -> CubeLUT {
        lock.lock()
        defer { lock.unlock() }
        if let standard { return standard }
        let made = CubeLUT.sLog3Preview()
        standard = made
        return made
    }

    /// The LUT file of the camera, when the clip names one and it is on the card or the disk.
    public static func cameraLUT(named name: String, root: URL) -> CubeLUT? {
        let url = root.appendingPathComponent("PRIVATE/M4ROOT/GENERAL/LUT").appendingPathComponent(name)
        lock.lock()
        defer { lock.unlock() }
        if let hit = parsed[url.path] { return hit }
        guard FileManager.default.fileExists(atPath: url.path), let lut = try? CubeLUT.parse(url) else { return nil }
        parsed[url.path] = lut
        return lut
    }

    /// The LUT to show a clip with, or nil for a clip that is not log or a mode that shows it as shot.
    public static func lut(for metadata: MediaMetadata, root: URL, mode: LookMode) -> CubeLUT? {
        guard metadata.isLog else { return nil }
        switch mode {
        case .off: return nil
        case .builtIn: return standardSLog3()
        case .auto:
            if let name = metadata.lutFile, let camera = cameraLUT(named: name, root: root) { return camera }
            return standardSLog3()
        }
    }

    /// The look for an item from the notes the camera wrote next to it, without playing it.
    public static func lut(for item: MediaItem, root: URL, mode: LookMode) -> CubeLUT? {
        guard mode != .off, item.kind == .video, item.companion(.proxy) == nil,
              let sidecar = item.companion(.sidecar), sidecar.ext == "xml",
              let data = try? Data(contentsOf: root.appendingPathComponent(sidecar.rel)) else { return nil }
        return lut(for: SonyClipXML.parse(data), root: root, mode: mode)
    }

    /// A picture with the look on it.
    public static func applying(_ lut: CubeLUT, to image: CGImage) -> CGImage? {
        guard let filter = lut.filter() else { return nil }
        filter.setValue(CIImage(cgImage: image), forKey: kCIInputImageKey)
        guard let output = filter.outputImage, let space = CGColorSpace(name: CGColorSpace.itur_709) else { return nil }
        return context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: space)
    }

    /// A video composition that puts the look on every frame as it plays.
    public static func composition(for asset: AVAsset, lut: CubeLUT) async throws -> AVVideoComposition {
        guard let filter = lut.filter() else { throw CocoaError(.featureUnsupported) }
        let guardrail = NSLock()
        return try await AVVideoComposition.videoComposition(with: asset) { request in
            guardrail.lock()
            defer { guardrail.unlock() }
            filter.setValue(request.sourceImage.clampedToExtent(), forKey: kCIInputImageKey)
            let output = filter.outputImage?.cropped(to: request.sourceImage.extent) ?? request.sourceImage
            request.finish(with: output, context: nil)
        }
    }
}
