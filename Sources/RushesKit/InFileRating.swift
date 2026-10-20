import Foundation

/// The star rating inside a photo, where a Sony camera keeps it and where the camera and Sony's Creators' App read it back.
///
/// A Sony camera writes the rating in the XMP packet inside the file (`<xmp:Rating>5</xmp:Rating>`, tag 0x02BC in an ARW, an
/// APP1 segment in a JPEG). That packet ends in padding meant for exactly this: a rating is changed in place, or added by
/// taking room from the padding, so the file keeps its size to the byte. The EXIF Rating tag (0x4746) is set as well when a
/// file has one. Nothing else in the file moves, and a file without either is left alone.
public enum InFileRating {
    /// A part of the file that holds a rating or can take one.
    public struct Place: Equatable, Sendable {
        public enum Kind: Sendable { case xmp, exif }
        public let kind: Kind
        public let offset: Int
        public let length: Int
        public let littleEndian: Bool
    }

    public static func places(in data: Data) -> [Place] {
        let bytes = [UInt8](data.prefix(16 << 20))
        guard bytes.count > 12 else { return [] }
        if bytes[0] == 0xFF, bytes[1] == 0xD8 { return jpegPlaces(bytes) }
        if (bytes[0] == 0x49 && bytes[1] == 0x49) || (bytes[0] == 0x4D && bytes[1] == 0x4D) { return tiffPlaces(bytes, base: 0) }
        return []
    }

    /// The rating the file carries, or nil when it has none (or 0, which means none).
    public static func read(_ url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return nil }
        let bytes = [UInt8](data.prefix(16 << 20))
        var best: Int?
        for place in places(in: data) {
            if let value = rating(in: place, bytes: bytes), value > 0 { best = max(best ?? 0, value) }
        }
        return best
    }

    /// Whether the file has a place where a rating fits.
    public static func canHold(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else { return false }
        let bytes = [UInt8](data.prefix(16 << 20))
        return places(in: data).contains { place in place.kind == .exif || updatedPacket(place, bytes: bytes, stars: 5) != nil }
    }

    /// Sets the rating. False when the file has no room for it, and then nothing is changed.
    @discardableResult
    public static func write(_ stars: Int, to url: URL) throws -> Bool {
        let data = try Data(contentsOf: url, options: .alwaysMapped)
        let bytes = [UInt8](data.prefix(16 << 20))
        var changes: [(offset: Int, bytes: [UInt8])] = []
        for place in places(in: data) {
            switch place.kind {
            case .xmp:
                if let packet = updatedPacket(place, bytes: bytes, stars: stars) { changes.append((place.offset, packet)) }
            case .exif:
                let value = UInt16(max(0, stars))
                changes.append((place.offset, place.littleEndian ? [UInt8(value & 0xFF), UInt8(value >> 8)] : [UInt8(value >> 8), UInt8(value & 0xFF)]))
            }
        }
        guard !changes.isEmpty else { return false }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let handle = try FileHandle(forUpdating: url)
        for change in changes {
            try handle.seek(toOffset: UInt64(change.offset))
            try handle.write(contentsOf: Data(change.bytes))
        }
        try handle.synchronize()
        try handle.close()
        // The same time as before, so the file is still the file Rushes and the camera know.
        if let modified = attributes[.modificationDate] as? Date {
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        }
        return true
    }

    // MARK: The XMP packet

    static func rating(in place: Place, bytes: [UInt8]) -> Int? {
        guard place.offset + place.length <= bytes.count else { return nil }
        switch place.kind {
        case .exif:
            let a = Int(bytes[place.offset]), b = Int(bytes[place.offset + 1])
            return place.littleEndian ? a | b << 8 : a << 8 | b
        case .xmp:
            let text = String(decoding: bytes[place.offset ..< place.offset + place.length], as: UTF8.self)
            return CardMarker.value(of: "xmp:Rating", in: text).flatMap { Int($0) }
        }
    }

    /// The packet with the new rating, exactly as long as it was. Nil when it does not fit.
    static func updatedPacket(_ place: Place, bytes: [UInt8], stars: Int) -> [UInt8]? {
        guard place.kind == .xmp, place.offset + place.length <= bytes.count else { return nil }
        let packet = Array(bytes[place.offset ..< place.offset + place.length])
        let text = String(decoding: packet, as: UTF8.self)
        guard text.utf8.count == packet.count else { return nil }   // not plain UTF-8: leave it
        var updated: String
        if CardMarker.value(of: "xmp:Rating", in: text) != nil {
            updated = CardMarker.setting("xmp:Rating", to: "\(stars)", in: text)
        } else {
            // A description of its own, the way the camera writes one, placed first inside the RDF.
            guard let rdf = text.range(of: "<rdf:RDF"), let close = text[rdf.upperBound...].firstIndex(of: ">") else { return nil }
            let insert = "\n <rdf:Description rdf:about=''\n  xmlns:xmp='http://ns.adobe.com/xap/1.0/'>\n  <xmp:Rating>\(stars)</xmp:Rating>\n </rdf:Description>"
            updated = text
            updated.insert(contentsOf: insert, at: text.index(after: close))
        }
        return fitted(updated, length: packet.count)
    }

    /// Gives back what was added by taking it from the padding before the packet's end, or adds padding for what was taken.
    static func fitted(_ text: String, length: Int) -> [UInt8]? {
        var bytes = Array(text.utf8)
        let difference = bytes.count - length
        if difference == 0 { return bytes }
        guard let end = text.range(of: "<?xpacket end")?.lowerBound else { return nil }
        let endOffset = text.utf8.distance(from: text.startIndex, to: end)
        if difference > 0 {
            // Remove that many spaces from the padding, which is spaces and line breaks just before the end.
            var removed = 0, i = endOffset - 1
            while removed < difference, i >= 0, bytes[i] == 0x20 || bytes[i] == 0x0A {
                if bytes[i] == 0x20 { bytes.remove(at: i); removed += 1 }
                i -= 1
            }
            guard removed == difference else { return nil }
        } else {
            bytes.insert(contentsOf: [UInt8](repeating: 0x20, count: -difference), at: endOffset)
        }
        return bytes.count == length ? bytes : nil
    }

    // MARK: Finding the places

    private static func jpegPlaces(_ bytes: [UInt8]) -> [Place] {
        var found: [Place] = []
        var p = 2
        let xmpHeader = Array("http://ns.adobe.com/xap/1.0/\0".utf8)
        while p + 4 <= bytes.count, bytes[p] == 0xFF {
            let marker = bytes[p + 1]
            if marker == 0xDA || marker == 0xD9 { break }   // the picture itself starts, no more metadata
            let length = Int(bytes[p + 2]) << 8 | Int(bytes[p + 3])
            let start = p + 4, end = min(bytes.count, p + 2 + length)
            if marker == 0xE1, end > start + 6 {
                if Array(bytes[start ..< start + 6]) == Array("Exif\0\0".utf8) {
                    found += tiffPlaces(bytes, base: start + 6)
                } else if end > start + xmpHeader.count, Array(bytes[start ..< start + xmpHeader.count]) == xmpHeader {
                    found.append(Place(kind: .xmp, offset: start + xmpHeader.count, length: end - start - xmpHeader.count, littleEndian: true))
                }
            }
            guard length >= 2 else { break }
            p += 2 + length
        }
        return found
    }

    private static func tiffPlaces(_ bytes: [UInt8], base: Int) -> [Place] {
        guard base + 8 <= bytes.count else { return [] }
        let little = bytes[base] == 0x49
        let ifd0 = base + Int(u32(bytes, base + 4, little))
        guard ifd0 + 2 <= bytes.count else { return [] }
        let count = Int(u16(bytes, ifd0, little))
        guard count < 1000, ifd0 + 2 + count * 12 <= bytes.count else { return [] }
        var found: [Place] = []
        for index in 0 ..< count {
            let p = ifd0 + 2 + index * 12
            let tag = u16(bytes, p, little), type = u16(bytes, p + 2, little), length = Int(u32(bytes, p + 4, little))
            if tag == 0x4746, type == 3, length == 1 {
                found.append(Place(kind: .exif, offset: p + 8, length: 2, littleEndian: little))
            } else if tag == 0x02BC, length > 4 {
                let start = base + Int(u32(bytes, p + 8, little))
                if start + length <= bytes.count { found.append(Place(kind: .xmp, offset: start, length: length, littleEndian: little)) }
            }
        }
        return found
    }

    private static func u16(_ b: [UInt8], _ p: Int, _ little: Bool) -> UInt16 {
        guard p + 2 <= b.count else { return 0 }
        return little ? UInt16(b[p]) | UInt16(b[p + 1]) << 8 : UInt16(b[p]) << 8 | UInt16(b[p + 1])
    }

    private static func u32(_ b: [UInt8], _ p: Int, _ little: Bool) -> UInt32 {
        guard p + 4 <= b.count else { return 0 }
        let v = (0 ..< 4).map { UInt32(b[p + $0]) }
        return little ? v[0] | v[1] << 8 | v[2] << 16 | v[3] << 24 : v[0] << 24 | v[1] << 16 | v[2] << 8 | v[3]
    }
}
