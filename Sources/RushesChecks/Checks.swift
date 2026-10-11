import Foundation
import RushesKit

private func entry(_ rel: String, size: UInt64 = 100, seconds: TimeInterval = 1_000_000) -> FileEntry {
    FileEntry(rel: rel, size: size, modified: Date(timeIntervalSince1970: seconds), created: nil)
}

enum PathKeyTests {
    static func cardNumbers() {
        expect(PathKeys.cardNumber(in: "SD 4") == 4)
        expect(PathKeys.cardNumber(in: "sd4") == 4)
        expect(PathKeys.cardNumber(in: "SD 3 Zomervakantie Zweden") == 3)
        expect(PathKeys.cardNumber(in: "SD kaarten") == nil)
        expect(PathKeys.cardNumber(in: "SDHC") == nil)
        expect(PathKeys.cardNumber(in: "Backups") == nil)
    }

    static func linuxAndMacPathsMeetInTheMiddle() {
        let linux = PathKeys.make(path: "/run/media/Mark/4TB SSD/SD kaarten/SD 3 Zomervakantie Zweden Marokko Spanje/PRIVATE/M4ROOT/CLIP/C2405.MP4")
        let mac = PathKeys.make(path: "/Volumes/4TB SSD/SD 3/PRIVATE/M4ROOT/CLIP/C2405.MP4")
        expect(linux.card == "sd3|private/m4root/clip/c2405.mp4")
        expect(linux.card == mac.card)
        expect(linux.name == "c2405.mp4")
    }

    static func volumeRelativePaths() {
        expect(PathKeys.make(path: "/Volumes/4TB SSD/Film/VFX/a.mov").volumeRelative == "film/vfx/a.mov")
        expect(PathKeys.make(path: "/run/media/Mark/4TB SSD/Film/VFX/a.mov").volumeRelative == "film/vfx/a.mov")
        expect(PathKeys.make(path: "/Users/mark/Movies/a.mp4").volumeRelative == nil)
    }
}

enum ScannerTests {
    static func sonyClipGetsItsCompanions() {
        let files = [
            entry("PRIVATE/M4ROOT/CLIP/C2631.MP4", size: 900),
            entry("PRIVATE/M4ROOT/CLIP/C2631M01.XML", size: 2),
            entry("PRIVATE/M4ROOT/SUB/C2631S03.MP4", size: 50),
            entry("PRIVATE/M4ROOT/THMBNL/C2631T01.JPG", size: 5),
            entry("PRIVATE/M4ROOT/CLIP/C2632.MP4", size: 800),
            entry("PRIVATE/M4ROOT/MEDIAPRO.XML", size: 1),
            entry("AVF_INFO/AVIN0001.BNP", size: 1),
        ]
        let (items, extras) = FolderScanner.group(files)
        expect(items.count == 2)
        let first = items.first { $0.name == "C2631.MP4" }
        expect(first?.companions.count == 3)
        expect(first?.companion(.proxy)?.rel.hasSuffix("C2631S03.MP4") == true)
        expect(first?.companion(.thumbnail) != nil)
        expect(first?.companion(.sidecar)?.ext == "xml")
        expect(Set(extras.map(\.rel)) == ["PRIVATE/M4ROOT/MEDIAPRO.XML", "AVF_INFO/AVIN0001.BNP"])
    }

    static func rawAndJpegAreOnePicture() {
        let files = [entry("DCIM/100MSDCF/DSC03034.ARW", size: 30), entry("DCIM/100MSDCF/DSC03034.JPG", size: 8), entry("DCIM/100MSDCF/DSC03035.JPG", size: 8)]
        let (items, extras) = FolderScanner.group(files)
        expect(items.count == 2)
        expect(extras.isEmpty)
        let pair = items.first { $0.name == "DSC03034.ARW" }
        expect(pair?.companion(.pair)?.ext == "jpg")
    }

    static func goProAndDjiSidecars() {
        let files = [entry("DCIM/100GOPRO/GX010123.MP4"), entry("DCIM/100GOPRO/GL010123.LRV"), entry("DCIM/100GOPRO/GX010123.THM"),
                     entry("DCIM/100MEDIA/DJI_0001.MP4"), entry("DCIM/100MEDIA/DJI_0001.SRT"), entry("DCIM/100MEDIA/DJI_0001.LRF")]
        let (items, extras) = FolderScanner.group(files)
        expect(items.count == 2)
        expect(extras.isEmpty)
        expect(items.first { $0.name == "GX010123.MP4" }?.companions.count == 2)
        expect(items.first { $0.name == "DJI_0001.MP4" }?.companions.count == 2)
    }
}

enum PlannerTests {
    static func plansOnlyWhatIsWanted() {
        let files = [entry("DCIM/A0001.MP4", size: 10), entry("DCIM/A0002.MP4", size: 20), entry("DCIM/A0003.MP4", size: 30), entry("INDEX.BIN", size: 1)]
        let (items, extras) = FolderScanner.group(files)
        let scan = ScanResult(root: URL(fileURLWithPath: "/card"), items: items, extras: extras)
        let imported: Set<String> = ["dcim/a0001.mp4|10|1000000"]
        let plan = ImportPlanner.plan(scan: scan, verdicts: ["DCIM/A0002.MP4": .skip], imported: imported, skipped: [])
        expect(plan.keptItems.map(\.name) == ["A0003.MP4"])
        expect(plan.skippedItems.map(\.name) == ["A0002.MP4"])
        expect(plan.tasks.map(\.entry.rel).sorted() == ["DCIM/A0003.MP4", "INDEX.BIN"])
        expect(plan.totalBytes == 31)
    }

    static func reformattedCardIsNotMistakenForOld() {
        let old = entry("DCIM/A0001.MP4", size: 10, seconds: 1_000_000)
        let fresh = entry("DCIM/A0001.MP4", size: 10, seconds: 2_000_000)
        let (items, extras) = FolderScanner.group([fresh])
        let scan = ScanResult(root: URL(fileURLWithPath: "/card"), items: items, extras: extras)
        let plan = ImportPlanner.plan(scan: scan, verdicts: [:], imported: [old.fingerprint], skipped: [])
        expect(plan.keptItems.count == 1)
    }
}

enum CopierTests {
    static func copiesAndVerifiesWithBackup() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("rushes-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        let card = base.appendingPathComponent("card"), dest = base.appendingPathComponent("dest"), backup = base.appendingPathComponent("backup")
        try fm.createDirectory(at: card.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        var data = Data(count: 20_000_000)
        for index in stride(from: 0, to: data.count, by: 4096) { data[index] = UInt8(index % 251) }
        try data.write(to: card.appendingPathComponent("DCIM/clip.mp4"))
        try Data("hello".utf8).write(to: card.appendingPathComponent("DCIM/note.xml"))

        let entries = FolderScanner.enumerate(root: card)
        expect(entries.count == 2)
        let tasks = entries.map { CopyTask(source: card.appendingPathComponent($0.rel), entry: $0, destinationRel: "SD 1/" + $0.rel) }
        let report = FileCopier(tasks: tasks, destination: dest, backup: backup).run()
        expect(report.failed.isEmpty)
        expect(report.copied.count == 2)
        expect(report.verified)
        expect(try Data(contentsOf: dest.appendingPathComponent("SD 1/DCIM/clip.mp4")) == data)
        expect(try Data(contentsOf: backup.appendingPathComponent("SD 1/DCIM/note.xml")) == Data("hello".utf8))
        let hash = try FileCopier.hashFile(card.appendingPathComponent("DCIM/clip.mp4"))
        expect(report.copied.first { $0.task.entry.name == "clip.mp4" }?.hash == hash)
        // No half files are left behind.
        expect(!FolderScanner.enumerate(root: dest).contains { $0.rel.hasSuffix(".rushes-part") })
    }

    static func cancelStopsAndLeavesNoPartFile() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("rushes-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: base) }
        try fm.createDirectory(at: base.appendingPathComponent("card"), withIntermediateDirectories: true)
        try Data(count: 5_000_000).write(to: base.appendingPathComponent("card/a.mp4"))
        let entries = FolderScanner.enumerate(root: base.appendingPathComponent("card"))
        let tasks = entries.map { CopyTask(source: base.appendingPathComponent("card").appendingPathComponent($0.rel), entry: $0, destinationRel: $0.rel) }
        let report = FileCopier(tasks: tasks, destination: base.appendingPathComponent("dest"), isCancelled: { true }).run()
        expect(report.cancelled)
        expect(report.copied.isEmpty)
    }
}

enum ResolveTests {
    static func parsesTheClipBlob() throws {
        // A real blob from a project: header, zstd frame with a raw block, then the protobuf message.
        let hex = "00000002000000d381 28b52ffd20c94906000a582f566f6c756d65732f3454422053534400"
        _ = hex
        var blob = Data([0, 0, 0, 2, 0, 0, 0, 0xd3, 0x81, 0x28, 0xb5, 0x2f, 0xfd, 0x20, 0xc9, 0x49, 0x06, 0x00])
        let folder = "/Volumes/4TB SSD/SD kaarten/SD 3 Zomervakantie Zweden Marokko Spanje/PRIVATE/M4ROOT/CLIP"
        blob.append(0x0a); blob.append(UInt8(folder.utf8.count)); blob.append(Data(folder.utf8))
        blob.append(0x12); blob.append(9); blob.append(Data("C2507.MP4".utf8))
        blob.append(0x1a); blob.append(3); blob.append(Data("abc".utf8))
        expect(ResolveDatabase.parseClipBlob(blob) == folder + "/C2507.MP4")
        expect(ResolveDatabase.parseClipBlob(Data([1, 2, 3])) == nil)
    }

    static func indexLookupSurvivesMovedDisksAndRenamedFolders() {
        let index = ResolveIndex(references: [
            .init(project: "Zweden", timeline: "Spot", source: .timeline,
                  card: "sd3|private/m4root/clip/c2405.mp4", volume: "sd kaarten/sd 3 zomervakantie/private/m4root/clip/c2405.mp4", name: "c2405.mp4", count: 2),
            .init(project: "Zweden", timeline: nil, source: .pool, card: "sd3|private/m4root/clip/c2406.mp4", volume: nil, name: "c2406.mp4", count: 1),
            .init(project: "Anders", timeline: nil, source: .pool, card: "sd9|clip/c2407.mp4", volume: nil, name: "c2407.mp4", count: 1),
        ], projects: [])
        let used = index.usage(ofPath: "/Volumes/4TB SSD/SD 3 Zweden/PRIVATE/M4ROOT/CLIP/C2405.MP4")
        expect(used.status == .used)
        expect(used.projects.first?.timelines == ["Spot"])
        expect(used.projects.first?.clipCount == 2)
        expect(index.usage(ofPath: "/Volumes/4TB SSD/SD 3/PRIVATE/M4ROOT/CLIP/C2406.MP4").status == .poolOnly)
        // Another card with the same clip number is not the same clip.
        expect(index.usage(ofPath: "/Volumes/4TB SSD/SD 5/PRIVATE/M4ROOT/CLIP/C2405.MP4").status == .possible)
        expect(index.usage(ofPath: "/Volumes/4TB SSD/SD 5/PRIVATE/M4ROOT/CLIP/C9999.MP4").status == .unused)
    }

    static func roundTripsThroughJSON() throws {
        let index = ResolveIndex(references: [.init(project: "P", timeline: "T", source: .timeline, card: "sd1|a.mp4", volume: nil, name: "a.mp4", count: 1)],
                                 projects: [.init(name: "P", modified: Date(), timelineClips: 1, poolClips: 0, failed: false)])
        let data = try JSONEncoder().encode(index)
        let back = try JSONDecoder().decode(ResolveIndex.self, from: data)
        expect(back.usage(ofPath: "/Volumes/X/SD 1/a.mp4").status == .used)
    }

    /// Runs against the real database of this Mac when there is one.
    static func readsTheRealProjects() throws {
        let projects = ResolveDatabase.findProjects(roots: ResolveDatabase.defaultRoots)
        guard !projects.isEmpty else { return }
        let index = ResolveIndex.build(roots: ResolveDatabase.defaultRoots, mappings: [("/run/media/Mark", "/Volumes")])
        expect(index.projects.count == projects.count)
        expect(index.projects.allSatisfy { !$0.failed })
        expect(index.references.count > 0)
    }
}

enum LedgerTests {
    static func remembersFilesCardsAndSkips() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).db").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let ledger = try Ledger(path: path)
        let id = ledger.beginImport(cardUUID: "U1", cardName: "NO NAME", folder: "/x/SD 1", label: "SD 1", backupFolder: nil)
        let file = entry("DCIM/A.MP4", size: 5, seconds: 1234)
        ledger.recordFile(importID: id, entry: file, hash: "abc", dest: "/x/SD 1/DCIM/A.MP4", kind: "video")
        expect(ledger.hasImported(file))
        expect(!ledger.hasImported(entry("DCIM/A.MP4", size: 5, seconds: 9999)))
        expect(ledger.existingCopy(withHash: "abc", excludingImport: id + 1) == "/x/SD 1/DCIM/A.MP4")
        ledger.markSkipped([entry("DCIM/B.MP4")], cardUUID: "U1")
        expect(ledger.wasSkipped(entry("DCIM/B.MP4")))
        ledger.unmarkSkipped([entry("DCIM/B.MP4")])
        expect(!ledger.wasSkipped(entry("DCIM/B.MP4")))
        ledger.saveCard(.init(uuid: "U1", name: "NO NAME", number: 4, folder: "/x/SD 4", firstSeen: Date(), lastSeen: Date()))
        expect(ledger.highestCardNumber() == 4)
        ledger.rewriteDestinations(from: "/x/SD 1", to: "/x/SD 1 Zweden")
        expect(ledger.files(ofImport: id).first?.dest == "/x/SD 1 Zweden/DCIM/A.MP4")
        ledger.setChoice(key: "sd1|a", verdict: "keep", rating: 3)
        expect(ledger.choice(forKey: "sd1|a")?.rating == 3)
    }
}

enum MiscTests {
    static func theSlotOfAMacIsStillACard() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rushes-slot-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("DCIM"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        func volume(builtIn: Bool, removable: Bool) -> VolumeInfo {
            VolumeInfo(url: folder, name: "SD", uuid: "x", capacity: 256 << 30, available: 100 << 30, isRemovable: removable,
                       isEjectable: removable, isInternal: builtIn, isReadOnly: false, format: "ExFAT")
        }
        expect(volume(builtIn: true, removable: true).looksLikeCard, "the card slot of a Mac reports internal")
        expect(volume(builtIn: false, removable: true).looksLikeCard)
        expect(!volume(builtIn: true, removable: false).looksLikeCard, "a fixed internal disk is never a card")
    }

    static func cardNames() {
        expect(CardNaming.nextNumber(ledgerHighest: 2, existingFolders: ["SD 3 Zweden", "SD 4", "Backups"]) == 5)
        expect(CardNaming.folderName(number: 5, name: "Zweden: dag/1") == "SD 5 Zweden dag 1")
        expect(CardNaming.folderName(number: 5, name: nil) == "SD 5")
    }

    static func binNames() {
        let day = ISO8601DateFormatter().date(from: "2026-10-11T12:00:00Z")!
        expect(CardNaming.binName(template: "{datum}", day: day, importDate: day, sd: "SD 5", name: nil) == "2026-10-11")
        expect(CardNaming.binName(template: "{datum} {sd} {naam}", day: day, importDate: day, sd: "SD 5", name: "Zweden") == "2026-10-11 SD 5 Zweden")
    }

    static func cubeLUT() throws {
        let text = "# test\nLUT_3D_SIZE 2\n0 0 0\n1 0 0\n0 1 0\n1 1 0\n0 0 1\n1 0 1\n0 1 1\n1 1 1\n"
        let lut = try CubeLUT.parse(text)
        expect(lut.size == 2)
        expect(lut.data.count == 2 * 2 * 2 * 4 * MemoryLayout<Float>.size)
        expect(CubeLUT.sLog3Preview(size: 5).size == 5)
    }

    static func sonyXML() {
        let xml = """
        <NonRealTimeMeta><Duration value="60"/><CreationDate value="2026-09-21T21:56:55+02:00"/>
        <VideoFormat><VideoFrame videoCodec="AVC140_3840_2160_H422P@L51" captureFps="25.00p" formatFps="25p"/><VideoLayout pixel="3840" numOfVerticalLine="2160"/></VideoFormat>
        <Device modelName="ILCE-7CM2"/><AcquisitionRecord><Group name="CameraUnitMetadataSet"><Item name="CaptureGammaEquation" value="s-log3-cine"/></Group></AcquisitionRecord>
        <RelevantFiles><RelatedTo file="SV2look.cube" rel="LUT"/></RelevantFiles></NonRealTimeMeta>
        """
        let metadata = SonyClipXML.parse(Data(xml.utf8))
        expect(metadata.duration == 2.4)
        expect(metadata.width == 3840)
        expect(metadata.camera == "ILCE-7CM2")
        expect(metadata.isLog)
        expect(metadata.lutFile == "SV2look.cube")
        expect(metadata.codec == "AVC 4:2:2")
    }

    static func suggestions() {
        let now = Date()
        var flat = ClipAnalysis(); flat.detail = 0.005
        var sharp = ClipAnalysis(); sharp.sharpness = 100; sharp.hash = 0b1010
        var soft = ClipAnalysis(); soft.sharpness = 10; soft.hash = 0b1011
        var other = ClipAnalysis(); other.sharpness = 90; other.hash = UInt64.max
        let inputs = [
            SuggestionEngine.Input(id: "v1", kind: .video, date: now, duration: 0.4, analysis: nil),
            SuggestionEngine.Input(id: "v2", kind: .video, date: now, duration: 30, analysis: flat),
            SuggestionEngine.Input(id: "p1", kind: .photo, date: now, duration: nil, analysis: sharp),
            SuggestionEngine.Input(id: "p2", kind: .photo, date: now.addingTimeInterval(1), duration: nil, analysis: soft),
            SuggestionEngine.Input(id: "p3", kind: .photo, date: now.addingTimeInterval(60), duration: nil, analysis: other),
        ]
        let result = SuggestionEngine.evaluate(inputs, settings: SuggestionSettings())
        expect(result["v1"] == .tooShort)
        expect(result["v2"] == .flatFrame)
        expect(result["p2"] == .nearDuplicate(of: "p1"))
        expect(result["p1"] == nil)
        expect(result["p3"] == nil)

        // A run of ordinary shots with one that is far softer than the ones around it, and one that is only a bit softer.
        func shot(_ id: String, _ sharpness: Double, at seconds: Double) -> SuggestionEngine.Input {
            var analysis = ClipAnalysis()
            analysis.sharpness = sharpness
            analysis.hash = UInt64(abs(id.hashValue)) | 0x5555_0000_0000_0000
            return SuggestionEngine.Input(id: id, kind: .photo, date: now.addingTimeInterval(seconds), duration: nil, analysis: analysis)
        }
        var run = (0 ..< 9).map { shot("a\($0)", 100 + Double($0), at: Double($0) * 60) }
        run.append(shot("far", 8, at: 600))
        run.append(shot("bit", 60, at: 660))
        let blur = SuggestionEngine.evaluate(run, settings: SuggestionSettings())
        expect(blur["far"] == .blurry, "much softer than its neighbours")
        expect(blur["bit"] == nil, "a bit softer is not out of focus")
        expect(blur["a3"] == nil)
        // Three photos are too few to tell what is normal.
        let few = SuggestionEngine.evaluate(Array(run.prefix(3)) + [shot("soft", 5, at: 700)], settings: SuggestionSettings())
        expect(few["soft"] == nil, "not enough shots around it to judge")
    }
}
