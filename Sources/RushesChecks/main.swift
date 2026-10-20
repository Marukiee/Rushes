import CoreImage
import Foundation
import ImageIO
import RushesKit
import UniformTypeIdentifiers

func import_ci() {
    let args = CommandLine.arguments
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        defer { semaphore.signal() }
        guard let frame = await Thumbnailer.shared.frame(of: URL(fileURLWithPath: args[2]), maxPixel: 960, fraction: 0.3) else { print("no frame"); return }
        let lut = args[3] == "builtin" ? CubeLUT.sLog3Preview() : try! CubeLUT.parse(URL(fileURLWithPath: args[3]))
        let filter = lut.filter()!
        filter.setValue(CIImage(cgImage: frame), forKey: kCIInputImageKey)
        let context = CIContext()
        let output = filter.outputImage!
        let image = context.createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))!
        let both = CGImage.sideBySide(frame, image)
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: args[4]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, both, nil)
        CGImageDestinationFinalize(destination)
        print("wrote \(args[4])")
    }
    semaphore.wait()
    exit(0)
}

extension CGImage {
    static func sideBySide(_ a: CGImage, _ b: CGImage) -> CGImage {
        let context = CGContext(data: nil, width: a.width + b.width, height: max(a.height, b.height), bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(a, in: CGRect(x: 0, y: 0, width: a.width, height: a.height))
        context.draw(b, in: CGRect(x: a.width, y: 0, width: b.width, height: b.height))
        return context.makeImage()!
    }
}

// Swift Testing and XCTest both need a full Xcode. These checks run with the command line tools alone:
// swift run RushesChecks
// swift run RushesChecks usage <folder>: how the projects of DaVinci Resolve on this Mac use the files of a folder.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "usage" {
    let index = ResolveIndex.build(roots: ResolveDatabase.defaultRoots, mappings: [("/run/media/Mark", "/Volumes")])
    for project in index.projects { print("project \(project.name): \(project.timelineClips) on timelines, \(project.poolClips) in the pool\(project.failed ? " (unreadable)" : "")") }
    let root = URL(fileURLWithPath: CommandLine.arguments[2])
    let scan = FolderScanner.scan(root: root)
    var counts: [String: (Int, UInt64)] = [:]
    for item in scan.items {
        let usage = index.usage(ofPath: root.appendingPathComponent(item.primary.rel).path)
        let old = counts[usage.status.rawValue] ?? (0, 0)
        counts[usage.status.rawValue] = (old.0 + 1, old.1 + item.totalBytes)
    }
    print("\(scan.items.count) items, \(scan.extras.count) extra files")
    for (status, value) in counts.sorted(by: { $0.key < $1.key }) {
        print("  \(status): \(value.0) items, \(ByteCountFormatter.string(fromByteCount: Int64(value.1), countStyle: .file))")
    }
    exit(0)
}

// swift run RushesChecks rating <photo> [stars]: where the photo keeps a star rating, what it says, and with stars sets it.
if CommandLine.arguments.count > 2, CommandLine.arguments[1] == "rating" {
    let url = URL(fileURLWithPath: CommandLine.arguments[2])
    let data = try! Data(contentsOf: url, options: .alwaysMapped)
    let places = InFileRating.places(in: data)
    print("\(url.lastPathComponent): \(data.count) bytes, \(places.count) places, rating \(InFileRating.read(url).map(String.init) ?? "none"), room for one: \(InFileRating.canHold(url))")
    for place in places { print("  \(place.kind) at \(place.offset), \(place.length) bytes") }
    if CommandLine.arguments.count > 3, let stars = Int(CommandLine.arguments[3]) {
        print("  write \(stars): \((try? InFileRating.write(stars, to: url)) ?? false), now \(InFileRating.read(url).map(String.init) ?? "none")")
    }
    if let source = CGImageSourceCreateWithURL(url as CFURL, nil), let metadata = CGImageSourceCopyMetadataAtIndex(source, 0, nil) {
        print("  ImageIO xmp:Rating = \(CGImageMetadataCopyStringValueWithPath(metadata, nil, "xmp:Rating" as CFString) as String? ?? "none")")
    }
    exit(0)
}

// swift run RushesChecks lut <clip> <cube file or "builtin"> <out.png>: one frame of a clip through a LUT.
if CommandLine.arguments.count > 4, CommandLine.arguments[1] == "lut" {
    import_ci()
}

nonisolated(unsafe) var failures: [String] = []
nonisolated(unsafe) var currentName = ""

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "", line: Int = #line) {
    if !((try? condition()) ?? false) { failures.append("\(currentName) (Checks.swift:\(line)) \(message)") }
}

let tests: [(String, () throws -> Void)] = [
    ("PathKeyTests.cardNumbers", PathKeyTests.cardNumbers),
    ("PathKeyTests.linuxAndMacPathsMeetInTheMiddle", PathKeyTests.linuxAndMacPathsMeetInTheMiddle),
    ("PathKeyTests.volumeRelativePaths", PathKeyTests.volumeRelativePaths),
    ("ScannerTests.sonyClipGetsItsCompanions", ScannerTests.sonyClipGetsItsCompanions),
    ("ScannerTests.rawAndJpegAreOnePicture", ScannerTests.rawAndJpegAreOnePicture),
    ("ScannerTests.goProAndDjiSidecars", ScannerTests.goProAndDjiSidecars),
    ("PlannerTests.plansOnlyWhatIsWanted", PlannerTests.plansOnlyWhatIsWanted),
    ("PlannerTests.onlyWhatWasChosen", PlannerTests.onlyWhatWasChosen),
    ("PlannerTests.secondDayAfterTheFirst", PlannerTests.secondDayAfterTheFirst),
    ("PlannerTests.videosOrPhotosAndOneDay", PlannerTests.videosOrPhotosAndOneDay),
    ("PlannerTests.reformattedCardIsNotMistakenForOld", PlannerTests.reformattedCardIsNotMistakenForOld),
    ("CopierTests.copiesAndVerifiesWithBackup", CopierTests.copiesAndVerifiesWithBackup),
    ("CopierTests.cancelStopsAndLeavesNoPartFile", CopierTests.cancelStopsAndLeavesNoPartFile),
    ("ResolveTests.parsesTheClipBlob", ResolveTests.parsesTheClipBlob),
    ("ResolveTests.indexLookupSurvivesMovedDisksAndRenamedFolders", ResolveTests.indexLookupSurvivesMovedDisksAndRenamedFolders),
    ("ResolveTests.roundTripsThroughJSON", ResolveTests.roundTripsThroughJSON),
    ("ResolveTests.readsTheRealProjects", ResolveTests.readsTheRealProjects),
    ("LedgerTests.remembersFilesCardsAndSkips", LedgerTests.remembersFilesCardsAndSkips),
    ("MiscTests.theSlotOfAMacIsStillACard", MiscTests.theSlotOfAMacIsStillACard),
    ("MiscTests.marksGoInASidecarAndNeverIntoTheFile", MiscTests.marksGoInASidecarAndNeverIntoTheFile),
    ("MiscTests.starsGoIntoThePhotoLikeTheCameraDoes", MiscTests.starsGoIntoThePhotoLikeTheCameraDoes),
    ("MiscTests.whatWasReadIsKept", MiscTests.whatWasReadIsKept),
    ("MiscTests.cardNames", MiscTests.cardNames),
    ("MiscTests.binNames", MiscTests.binNames),
    ("MiscTests.cubeLUT", MiscTests.cubeLUT),
    ("MiscTests.sonyXML", MiscTests.sonyXML),
    ("MiscTests.suggestions", MiscTests.suggestions),
]

var passed = 0
for (name, body) in tests {
    currentName = name
    let before = failures.count
    do { try body() } catch { failures.append("\(name) threw \(error)") }
    if failures.count == before { passed += 1; print("ok      \(name)") } else { print("FAILED  \(name)") }
}
print("\n\(passed) of \(tests.count) passed")
for failure in failures { print("  - \(failure)") }
exit(failures.isEmpty ? 0 : 1)
