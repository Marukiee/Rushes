import CoreImage
import Foundation

/// A 3D LUT as Core Image wants it: float RGBA, red running fastest, then green, then blue. That
/// is also how a `.cube` file is laid out, so reading one is a straight copy.
public struct CubeLUT: Sendable {
    public let size: Int
    public let data: Data
    public let title: String

    public enum ParseError: Error { case notThreeDimensional, malformed }

    public static func parse(_ url: URL) throws -> CubeLUT {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }

    public static func parse(_ text: String) throws -> CubeLUT {
        var size = 0
        var title = ""
        var domainMin: [Float] = [0, 0, 0], domainMax: [Float] = [1, 1, 1]
        var values: [Float] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                if title.isEmpty { title = String(line.dropFirst()).trimmingCharacters(in: .whitespaces) }
                continue
            }
            if line.hasPrefix("TITLE") { title = line.dropFirst(5).trimmingCharacters(in: CharacterSet(charactersIn: " \"")); continue }
            if line.hasPrefix("LUT_1D_SIZE") { throw ParseError.notThreeDimensional }
            if line.hasPrefix("LUT_3D_SIZE") { size = Int(line.split(separator: " ").last ?? "") ?? 0; continue }
            if line.hasPrefix("DOMAIN_MIN") { domainMin = floats(line); continue }
            if line.hasPrefix("DOMAIN_MAX") { domainMax = floats(line); continue }
            if let first = line.first, first.isLetter { continue }
            let numbers = floats(line)
            guard numbers.count == 3 else { throw ParseError.malformed }
            values.append(contentsOf: numbers)
        }
        guard size >= 2, values.count == size * size * size * 3 else { throw ParseError.malformed }
        var rgba = [Float](); rgba.reserveCapacity(size * size * size * 4)
        for index in stride(from: 0, to: values.count, by: 3) {
            for channel in 0 ..< 3 {
                let span = domainMax[channel] - domainMin[channel]
                rgba.append(span == 0 ? values[index + channel] : (values[index + channel] - domainMin[channel]) / span)
            }
            rgba.append(1)
        }
        return CubeLUT(size: size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, title: title)
    }

    private static func floats(_ line: String) -> [Float] {
        line.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Float($0) }
    }

    /// A stand in for the camera's own LUT: S-Log3 with S-Gamut3.Cine to a normal looking picture.
    /// Good enough to judge a shot by, not a grade.
    public static func sLog3Preview(size: Int = 33) -> CubeLUT {
        var rgba = [Float](); rgba.reserveCapacity(size * size * size * 4)
        func decode(_ x: Double) -> Double {
            let code = x * 1023
            if x >= 171.2102946929 / 1023 { return pow(10, (code - 420) / 261.5) * 0.19 - 0.01 }
            return (code - 95) * 0.01125 / (171.2102946929 - 95)
        }
        func encode(_ linear: Double) -> Float {
            // A soft shoulder, then the sRGB curve.
            let white = 6.0
            let mapped = max(0, linear) * (1 + max(0, linear) / (white * white)) / (1 + max(0, linear))
            let value = mapped <= 0.0031308 ? 12.92 * mapped : 1.055 * pow(mapped, 1 / 2.4) - 0.055
            return Float(min(1, max(0, value)))
        }
        for blue in 0 ..< size {
            for green in 0 ..< size {
                for red in 0 ..< size {
                    let r = decode(Double(red) / Double(size - 1))
                    let g = decode(Double(green) / Double(size - 1))
                    let b = decode(Double(blue) / Double(size - 1))
                    // S-Gamut3.Cine to Rec.709 primaries.
                    let outR = 1.6269474099 * r - 0.5401385880 * g - 0.0868088219 * b
                    let outG = -0.1785155272 * r + 1.4179409274 * g - 0.2394254004 * b
                    let outB = -0.0444361150 * r - 0.1959199662 * g + 1.2403560812 * b
                    rgba.append(encode(outR)); rgba.append(encode(outG)); rgba.append(encode(outB)); rgba.append(1)
                }
            }
        }
        return CubeLUT(size: size, data: rgba.withUnsafeBufferPointer { Data(buffer: $0) }, title: "S-Log3 preview")
    }

    public func filter() -> CIFilter? {
        // The video is tagged Rec.709 even when it holds log, so the lookup runs on those code values as they are.
        guard let space = CGColorSpace(name: CGColorSpace.itur_709),
              let filter = CIFilter(name: "CIColorCubeWithColorSpace") else { return nil }
        filter.setValue(size, forKey: "inputCubeDimension")
        filter.setValue(data, forKey: "inputCubeData")
        filter.setValue(space, forKey: "inputColorSpace")
        return filter
    }
}
