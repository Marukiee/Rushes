import AVFoundation
import CoreGraphics
import Foundation

/// What a quick look at a clip or a photo says about it. Small numbers, cheap to keep.
public struct ClipAnalysis: Codable, Sendable, Hashable {
    /// Spread of brightness over the sampled frames, the largest one. A covered lens gives a flat frame, even in log.
    public var detail: Double?
    public var meanLuma: Double?
    /// How sharp the sharpest parts of the picture are: higher is sharper. A portrait with a soft background is still sharp where
    /// the face is, so the picture is judged by its best areas and not by its average. Only meaningful next to similar photos.
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
            let thumb = Thumbnailer.imageIO(source(for: item, root: root), maxPixel: 640, always: false)
            if let thumb, let gray = Gray(thumb, width: 384, height: 256) {
                result.sharpness = gray.sharpestAreas()
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

    /// The Laplacian variance of the sharpest few areas of a grid over the picture, so a sharp subject on a soft background counts as sharp.
    func sharpestAreas(columns: Int = 6, rows: Int = 4, best: Int = 3) -> Double {
        let tileWidth = width / columns, tileHeight = height / rows
        guard tileWidth > 2, tileHeight > 2 else { return laplacianVariance() }
        var values: [Double] = []
        for row in 0 ..< rows {
            for column in 0 ..< columns {
                var sum = 0.0, sumSquares = 0.0, count = 0.0
                for y in max(1, row * tileHeight) ..< min(height - 1, (row + 1) * tileHeight) {
                    for x in max(1, column * tileWidth) ..< min(width - 1, (column + 1) * tileWidth) {
                        let center = Double(pixels[y * width + x])
                        let value = Double(pixels[(y - 1) * width + x]) + Double(pixels[(y + 1) * width + x])
                            + Double(pixels[y * width + x - 1]) + Double(pixels[y * width + x + 1]) - 4 * center
                        sum += value
                        sumSquares += value * value
                        count += 1
                    }
                }
                if count > 0 { let mean = sum / count; values.append(sumSquares / count - mean * mean) }
            }
        }
        let top = values.sorted(by: >).prefix(best)
        return top.isEmpty ? 0 : top.reduce(0, +) / Double(top.count)
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
    public var blurRatio = 0.2
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

        // Out of focus is judged against the shots around it, not against every photo of the card: a close portrait and a
        // landscape do not have the same amount of detail. Without enough shots around it there is nothing to compare with.
        for (index, photo) in photos.enumerated() where result[photo.id] == nil {
            guard let sharp = photo.analysis?.sharpness else { continue }
            let around = photos[max(0, index - 6) ... min(photos.count - 1, index + 6)]
                .filter { $0.id != photo.id }
                .compactMap { $0.analysis?.sharpness }
                .sorted()
            guard around.count >= 4 else { continue }
            let median = around[around.count / 2]
            if median > 0, sharp < median * settings.blurRatio { result[photo.id] = .blurry }
        }
        return result
    }
}
