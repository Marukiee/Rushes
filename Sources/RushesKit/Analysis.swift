import AVFoundation
import CoreGraphics
import Foundation

/// What a quick look at a clip or a photo says about it. Small numbers, cheap to keep.
public struct ClipAnalysis: Codable, Sendable, Hashable {
    /// Spread of brightness over the sampled frames, the largest one. A covered lens gives a flat frame, even in log.
    public var detail: Double?
    public var meanLuma: Double?
    /// Variance of the Laplacian of a small version: higher is sharper. Only meaningful next to other photos.
    public var sharpness: Double?
    /// 64 bit difference hash, for finding near copies in a burst.
    public var hash: UInt64?

    public init() {}
}

public enum ClipAnalyzer {
    public static func analyze(_ item: MediaItem, root: URL) async -> ClipAnalysis {
        var result = ClipAnalysis()
        switch item.kind {
        case .photo:
            let thumb = Thumbnailer.imageIO(source(for: item, root: root), maxPixel: 320, always: false)
            if let thumb, let gray = Gray(thumb, width: 256, height: 170) {
                result.sharpness = gray.laplacianVariance()
                result.meanLuma = gray.mean()
                result.detail = gray.standardDeviation()
                result.hash = Gray(thumb, width: 9, height: 8)?.differenceHash()
            }
        case .video:
            let url = await Thumbnailer.shared.playbackSource(of: item, root: root)
            var spread = 0.0, means: [Double] = []
            var firstHash: UInt64?
            for fraction in [0.1, 0.5, 0.9] {
                guard let frame = await Thumbnailer.shared.frame(of: url, maxPixel: 192, fraction: fraction),
                      let gray = Gray(frame, width: 96, height: 54) else { continue }
                spread = max(spread, gray.standardDeviation())
                means.append(gray.mean())
                if firstHash == nil { firstHash = Gray(frame, width: 9, height: 8)?.differenceHash() }
            }
            if !means.isEmpty {
                result.detail = spread
                result.meanLuma = means.reduce(0, +) / Double(means.count)
                result.hash = firstHash
            }
        case .audio:
            break
        }
        return result
    }

    private static func source(for item: MediaItem, root: URL) -> URL {
        if let pair = item.companions.first(where: { $0.role == .pair }), !MediaTypes.raw.contains(pair.entry.ext) {
            return root.appendingPathComponent(pair.entry.rel)
        }
        return root.appendingPathComponent(item.primary.rel)
    }
}

/// An 8 bit grey picture with the few measurements the suggestions need.
struct Gray {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    init?(_ image: CGImage, width: Int, height: Int) {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    func mean() -> Double {
        guard !pixels.isEmpty else { return 0 }
        return pixels.reduce(0.0) { $0 + Double($1) } / Double(pixels.count) / 255
    }

    func standardDeviation() -> Double {
        guard !pixels.isEmpty else { return 0 }
        let mean = self.mean() * 255
        let variance = pixels.reduce(0.0) { $0 + pow(Double($1) - mean, 2) } / Double(pixels.count)
        return sqrt(variance) / 255
    }

    func laplacianVariance() -> Double {
        guard width > 2, height > 2 else { return 0 }
        var sum = 0.0, sumSquares = 0.0, count = 0.0
        for y in 1 ..< height - 1 {
            for x in 1 ..< width - 1 {
                let center = Double(pixels[y * width + x])
                let value = Double(pixels[(y - 1) * width + x]) + Double(pixels[(y + 1) * width + x])
                    + Double(pixels[y * width + x - 1]) + Double(pixels[y * width + x + 1]) - 4 * center
                sum += value
                sumSquares += value * value
                count += 1
            }
        }
        let mean = sum / count
        return sumSquares / count - mean * mean
    }

    /// Compares each pixel with its right neighbour on a 9 by 8 grid.
    func differenceHash() -> UInt64? {
        guard width == 9, height == 8 else { return nil }
        var hash: UInt64 = 0
        for y in 0 ..< 8 {
            for x in 0 ..< 8 where pixels[y * 9 + x] > pixels[y * 9 + x + 1] {
                hash |= 1 << UInt64(y * 8 + x)
            }
        }
        return hash
    }
}

public struct SuggestionSettings: Codable, Sendable, Equatable {
    public var enabled = true
    public var shortClipSeconds = 1.0
    public var flatDetail = 0.02
    public var blurRatio = 0.35
    public var burstSeconds = 3.0
    public var burstDistance = 10

    public init() {}
}

public enum Suggestion: Sendable, Hashable {
    case flatFrame
    case tooShort
    case blurry
    case nearDuplicate(of: String)
}

/// Decides which items look like candidates to leave out. It only ever suggests; the person decides.
public enum SuggestionEngine {
    public struct Input: Sendable {
        public let id: String
        public let kind: MediaKind
        public let date: Date
        public let duration: Double?
        public let analysis: ClipAnalysis?

        public init(id: String, kind: MediaKind, date: Date, duration: Double?, analysis: ClipAnalysis?) {
            self.id = id
            self.kind = kind
            self.date = date
            self.duration = duration
            self.analysis = analysis
        }
    }

    public static func evaluate(_ inputs: [Input], settings: SuggestionSettings) -> [String: Suggestion] {
        guard settings.enabled else { return [:] }
        var result: [String: Suggestion] = [:]

        for input in inputs where input.kind == .video {
            if let duration = input.duration, duration < settings.shortClipSeconds {
                result[input.id] = .tooShort
            } else if let detail = input.analysis?.detail, detail < settings.flatDetail {
                result[input.id] = .flatFrame
            }
        }

        let photos = inputs.filter { $0.kind == .photo }.sorted { $0.date < $1.date }
        let sharpValues = photos.compactMap { $0.analysis?.sharpness }.sorted()
        let median = sharpValues.isEmpty ? 0 : sharpValues[sharpValues.count / 2]

        // A burst: shots seconds apart that look almost the same. The sharpest one stays unsuggested.
        var group: [Input] = []
        func flush() {
            guard group.count > 1 else { group = []; return }
            let best = group.max { ($0.analysis?.sharpness ?? 0) < ($1.analysis?.sharpness ?? 0) }!
            for other in group where other.id != best.id { result[other.id] = .nearDuplicate(of: best.id) }
            group = []
        }
        for photo in photos {
            if let last = group.last, photo.date.timeIntervalSince(last.date) <= settings.burstSeconds,
               let a = last.analysis?.hash, let b = photo.analysis?.hash,
               (a ^ b).nonzeroBitCount <= settings.burstDistance {
                group.append(photo)
            } else {
                flush()
                group = [photo]
            }
        }
        flush()

        if median > 0 {
            for photo in photos where result[photo.id] == nil {
                if let sharp = photo.analysis?.sharpness, sharp < median * settings.blurRatio { result[photo.id] = .blurry }
            }
        }
        return result
    }
}
