import AppKit
import Foundation
import RushesKit

/// What to copy: what was chosen, or everything in reach, maybe of one day or a selection, maybe only the videos or the photos.
struct ImportRequest {
    var everything = false
    var only: Set<String>?
    var kinds: CopyKinds = Prefs.copyKinds
    var undecidedMeansKeep = Prefs.bool(PrefKey.undecidedMeansKeep)
    /// What part of the card it is, for what the app says while it copies: a day, or the selection.
    var scope: String?
}

extension AppModel {
    // MARK: Starting

    /// Copies what the person chose. With `everything`, every new item goes, whatever was judged.
    func startImport(_ session: CardSession, everything: Bool = false) {
        startImport(session, request: ImportRequest(everything: everything))
    }

    func startImport(_ session: CardSession, request: ImportRequest) {
        guard job?.isRunning != true else {
            showToast(String(localized: "Another import is still running"))
            return
        }
        guard let destination else {
            alert = AppAlert(title: String(localized: "No disk to copy to"), message: String(localized: "Connect your disk, or choose one in the settings."))
            return
        }
        guard let review = session.review, let scan = session.scan else { return }

        let known = ledger.knownFingerprints()
        var dates: [String: Date] = [:]
        for item in scan.items { dates[item.id] = review.date(of: item) }
        let destinationRoot = destinationRoot(on: destination)
        let (card, folderName) = folderFor(session, destinationRoot: destinationRoot)
        let plan = ImportPlanner.plan(
            scan: scan, verdicts: review.verdicts, imported: known.imported, skipped: known.skipped, dates: dates,
            undecidedMeansKeep: request.undecidedMeansKeep, everything: request.everything, only: request.only, kinds: request.kinds,
            destinationPrefix: folderName + "/"
        )

        if plan.keptItems.isEmpty {
            session.updateCounts()
            if plan.alreadyThere > 0 {
                showToast(String(localized: "What you chose is already on \(destination.name)"))
            } else if request.everything {
                showToast(String(localized: "All of it is already on \(destination.name)"))
            } else {
                showToast(String(localized: "Nothing chosen yet. Mark clips with Keep, or copy all of them from the menu."))
            }
            return
        }

        let backupRoot = backup.map { self.backupRoot(on: $0) }
        let needed = plan.totalBytes
        guard let free = DiskSpace.available(at: destination.url), free > needed + (512 << 20) else {
            alert = AppAlert(
                title: String(localized: "Not enough room on \(destination.name)"),
                message: String(localized: "This needs \(Self.sizeText(needed)) and \(Self.sizeText(destination.available)) is free. Leave out more, or make room in the library first.")
            )
            return
        }
        if let backup, let free = DiskSpace.available(at: backup.url), free <= needed {
            alert = AppAlert(
                title: String(localized: "Not enough room on \(backup.name)"),
                message: String(localized: "The second copy needs \(Self.sizeText(needed)). Turn off the second copy or free up space.")
            )
            return
        }

        let folder = destinationRoot.appendingPathComponent(folderName, isDirectory: true)
        let job = ImportJob(cardName: session.name, cardUUID: session.volume.uuid, folderName: folderName, folder: folder, plan: plan)
        job.request = request
        job.backupFolder = backupRoot?.appendingPathComponent(folderName, isDirectory: true)
        job.phase = .copying
        self.job = job
        session.stage = .importing
        ledger.saveCard(card)
        job.recordID = ledger.beginImport(
            cardUUID: session.volume.uuid, cardName: session.name, folder: folder.path, label: folderName, backupFolder: job.backupFolder?.path
        )
        if Prefs.bool(PrefKey.backupEnabled), backupRoot == nil {
            showToast(String(localized: "The second copy disk is not connected, copying to \(destination.name) only"))
        }
        beginWork(reason: "Copying a card")
        syncPrompt()
        run(job, session: session, destinationRoot: destinationRoot, backupRoot: backupRoot)
    }

    func destinationRoot(on volume: VolumeInfo) -> URL {
        let sub = volume.uuid == Self.macFolderID ? "" : Prefs.string(PrefKey.destinationSubfolder)
        return sub.isEmpty ? volume.url : volume.url.appendingPathComponent(sub, isDirectory: true)
    }

    func backupRoot(on volume: VolumeInfo) -> URL {
        let sub = Prefs.string(PrefKey.backupSubfolder)
        return sub.isEmpty ? volume.url : volume.url.appendingPathComponent(sub, isDirectory: true)
    }

    /// The same card goes back in its own folder; a new card gets the next number.
    private func folderFor(_ session: CardSession, destinationRoot: URL) -> (Ledger.CardRecord, String) {
        let uuid = session.volume.uuid
        let now = Date()
        if var known = ledger.card(uuid: uuid) {
            let url = URL(fileURLWithPath: known.folder)
            if url.deletingLastPathComponent().standardizedFileURL == destinationRoot.standardizedFileURL,
               FileManager.default.fileExists(atPath: url.path) {
                known.lastSeen = now
                return (known, url.lastPathComponent)
            }
            // The folder was moved or renamed outside the app: look for the same card number next to the others.
            if let found = existingFolders(at: destinationRoot).first(where: { PathKeys.cardNumber(in: $0) == known.number }) {
                known.folder = destinationRoot.appendingPathComponent(found).path
                known.lastSeen = now
                return (known, found)
            }
        }
        let number = CardNaming.nextNumber(ledgerHighest: ledger.highestCardNumber(), existingFolders: existingFolders(at: destinationRoot))
        let name = CardNaming.folderName(number: number, name: nil)
        let record = Ledger.CardRecord(
            uuid: uuid, name: session.name, number: number, folder: destinationRoot.appendingPathComponent(name).path,
            firstSeen: now, lastSeen: now
        )
        return (record, name)
    }

    private func existingFolders(at root: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !MediaTypes.isJunk($0) }
    }

    // MARK: Running

    private func run(_ job: ImportJob, session: CardSession, destinationRoot: URL, backupRoot: URL?) {
        let ledger = ledger
        let importID = job.recordID
        let cancel = job.cancelFlag
        let tasks = job.plan.tasks
        let started = Date()
        let kinds = Dictionary(uniqueKeysWithValues: job.plan.keptItems.flatMap { item in
            item.files.map { file in (file.rel, Self.kindName(of: file, in: item)) }
        })

        Task {
            let copier = FileCopier(
                tasks: tasks, destination: destinationRoot, backup: backupRoot,
                onProgress: { progress in
                    Task { @MainActor in job.progress = progress }
                },
                onFileDone: { copied in
                    let kind = kinds[copied.task.entry.rel] ?? "extra"
                    ledger.recordFile(importID: importID, entry: copied.task.entry, hash: copied.hash, dest: copied.destination.path, kind: kind)
                },
                isCancelled: { cancel.isSet }
            )
            let report = await Task.detached(priority: .userInitiated) { copier.run() }.value
            job.duration = Date().timeIntervalSince(started)
            finish(job, report: report, session: session)
        }
    }

    private static func kindName(of file: FileEntry, in item: MediaItem) -> String {
        if file.rel == item.primary.rel { return item.kind.rawValue }
        return item.companions.first { $0.entry.rel == file.rel }?.role.rawValue ?? "extra"
    }

    private func finish(_ job: ImportJob, report: CopyReport, session: CardSession) {
        job.phase = .finishing
        job.report = report
        endWork()

        let prefix = job.folderName + "/"
        let entries = report.copied.map { copied -> Manifest.Entry in
            let rel = copied.task.destinationRel.hasPrefix(prefix) ? String(copied.task.destinationRel.dropFirst(prefix.count)) : copied.task.destinationRel
            return Manifest.Entry(path: rel, size: copied.task.entry.size, sha256: copied.hash)
        }
        if !entries.isEmpty {
            try? Manifest.merge(entries, into: job.folder)
            if let backup = job.backupFolder { try? Manifest.merge(entries, into: backup) }
        }

        let dates = report.copied.map { $0.task.entry.modified }
        let status: String
        if report.cancelled { status = Ledger.ImportStatus.cancelled } else if report.failed.isEmpty { status = Ledger.ImportStatus.done } else { status = Ledger.ImportStatus.failed }
        ledger.finishImport(
            id: job.recordID, status: status, files: report.copied.count, bytes: report.bytes,
            skippedFiles: job.plan.skippedItems.count, skippedBytes: job.plan.skippedBytes, duration: job.duration,
            verified: report.verified, shotFrom: job.plan.shotRange?.lowerBound ?? dates.min(), shotTo: job.plan.shotRange?.upperBound ?? dates.max()
        )
        refreshHistory()

        if report.cancelled {
            job.phase = .cancelled
            session.stage = .reviewing
        } else if !report.failed.isEmpty {
            job.phase = .failed(String(localized: "\(report.failed.count) files could not be copied or did not check out"))
            session.stage = .reviewing
        } else {
            job.phase = .done
            session.stage = .imported
            job.needsName = Prefs.bool(PrefKey.askForName)
        }
        // What arrived is on the disk now. It stays in view with its choice, so the next day can follow without a jump.
        if let review = session.review {
            let known = ledger.knownFingerprints()
            for item in review.allItems where ImportPlanner.status(of: item, imported: known.imported, skipped: []) == .imported {
                review.statuses[item.id] = .imported
            }
            review.refresh()
        }
        session.updateCounts()
        reloadLibrary()
        applyTags(for: job)

        if job.phase == .done {
            if Prefs.bool(PrefKey.notifyWhenDone) {
                Notifier.shared.importFinished(
                    title: String(localized: "\(job.folderName) is on your disk"),
                    body: String(localized: "\(report.copied.count) files, \(Self.sizeText(report.bytes)), every file checked"),
                    folder: job.folder.path, card: session.id
                )
            }
            if Prefs.bool(PrefKey.sendToResolve) { Task { await sendToResolve(job) } }
            if Prefs.bool(PrefKey.ejectAfterImport) { eject(session) }
        } else if Prefs.bool(PrefKey.notifyWhenDone) {
            Notifier.shared.post(
                id: "failed.\(job.id)", title: String(localized: "The copy of \(job.cardName) needs a look"),
                body: job.phase == .cancelled ? String(localized: "It was stopped.") : String(localized: "Some files did not arrive intact."), sound: true
            )
        }
        syncPrompt()
    }

    func cancelImport() { job?.cancel() }

    func dismissJob() {
        guard job?.isRunning != true else { return }
        job = nil
        syncPrompt()
    }

    /// Tries the files that failed, or were left because the copy was stopped.
    func retry(_ session: CardSession) {
        let request = job?.request ?? ImportRequest()
        job = nil
        session.updateCounts()
        startImport(session, request: request)
    }

    // MARK: Naming the folder

    /// Gives the folder of an import a name (`SD 5` becomes `SD 5 Sweden`) and keeps everything that points at it correct.
    func rename(job: ImportJob, to name: String) async {
        let newName = CardNaming.folderName(number: PathKeys.cardNumber(in: job.folderName) ?? 0, name: name)
        guard newName != job.folderName else { job.needsName = false; return }
        let old = job.folder
        let new = old.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: new.path) else {
            alert = AppAlert(title: String(localized: "That name is already in use"), message: newName)
            return
        }
        do {
            try FileManager.default.moveItem(at: old, to: new)
        } catch {
            alert = AppAlert(title: String(localized: "The folder could not be renamed"), message: error.localizedDescription)
            return
        }
        var newBackup: URL?
        if let backup = job.backupFolder {
            let target = backup.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
            if (try? FileManager.default.moveItem(at: backup, to: target)) != nil { newBackup = target } else { newBackup = backup }
        }
        ledger.rewriteDestinations(from: old.path, to: new.path)
        if let backup = job.backupFolder, let newBackup, newBackup != backup { ledger.rewriteDestinations(from: backup.path, to: newBackup.path) }
        ledger.updateImportLabel(id: job.recordID, label: newName, folder: new.path)
        job.folder = new
        job.folderName = newName
        job.backupFolder = newBackup ?? job.backupFolder
        job.needsName = false
        refreshHistory()
        reloadLibrary()
        // Clips already in Resolve still point at the old folder.
        if job.resolve != nil, !(job.resolve?.failed ?? true) {
            if let moved = try? await resolve.bridgeClient.relink(from: old.path, to: new.path, allProjects: false), moved.relinked > 0 {
                showToast(String(localized: "Renamed, and \(moved.relinked) clips in Resolve now point to the new name"))
                return
            }
        }
        showToast(String(localized: "Renamed to \(newName)"))
    }

    // MARK: Finder tags

    private func applyTags(for job: ImportJob) {
        // Only useful when asked for: on exFAT every tag leaves a small file next to the clip.
        guard Prefs.bool(PrefKey.finderTags), let report = job.report else { return }
        for copied in report.copied { try? (copied.destination as NSURL).setResourceValue([String(localized: "Rushes: imported")], forKey: .tagNamesKey) }
    }

    // MARK: DaVinci Resolve

    struct SendItem {
        let path: String
        let date: Date
        let isVideo: Bool
    }

    /// Puts the clips of an import in bins of the open Resolve project: one bin per day of shooting, named with the date.
    func sendToResolve(_ job: ImportJob) async {
        let items = sendItems(ofImport: job.recordID)
        job.resolve = ImportJob.ResolveOutcome(message: String(localized: "Sending to Resolve..."), failed: false)
        job.resolve = await send(items: items, folderName: job.folderName, label: nil)
        if let outcome = job.resolve, outcome.failed { showToast(outcome.message) }
    }

    func sendToResolve(record: Ledger.ImportRecord) async -> ImportJob.ResolveOutcome {
        let items = sendItems(ofImport: record.id)
        let outcome = await send(items: items, folderName: record.label, label: record.label)
        if !outcome.failed { ledger.markSentToResolve(importID: record.id); refreshHistory() }
        return outcome
    }

    /// The footage of an import: the clips and pictures themselves, not their proxies, thumbnails and notes.
    private func sendItems(ofImport id: Int64) -> [SendItem] {
        ledger.files(ofImport: id).compactMap { row in
            guard let kind = MediaKind(rawValue: row.kind),
                  let date = try? URL(fileURLWithPath: row.dest).resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            else { return nil }
            return SendItem(path: row.dest, date: date, isVideo: kind == .video)
        }
    }

    private func send(items: [SendItem], folderName: String, label: String?) async -> ImportJob.ResolveOutcome {
        guard !items.isEmpty else { return .init(message: String(localized: "There are no clips to send."), failed: true) }
        let template = Prefs.string(PrefKey.binTemplate).isEmpty ? "{datum}" : Prefs.string(PrefKey.binTemplate)
        let perDay = Prefs.bool(PrefKey.binPerDay)
        let calendar = Calendar.current
        let importDate = Date()
        let name = folderName.split(separator: " ").dropFirst(2).joined(separator: " ")

        var groups: [(day: Date, items: [SendItem])] = []
        if perDay || !template.contains("{datum}") {
            let byDay = Dictionary(grouping: items) { calendar.startOfDay(for: $0.date) }
            groups = byDay.keys.sorted().map { ($0, byDay[$0]!.sorted { $0.date < $1.date }) }
        }
        if groups.isEmpty || !perDay {
            let first = items.map(\.date).min() ?? importDate
            groups = [(calendar.startOfDay(for: first), items.sorted { $0.date < $1.date })]
        }
        let sd = folderName.split(separator: " ").prefix(2).joined(separator: " ")
        var bins: [ResolveBridge.BinRequest] = []
        for group in groups {
            let binName = CardNaming.binName(template: template, day: group.day, importDate: importDate, sd: sd, name: name.isEmpty ? nil : name)
            if let at = bins.firstIndex(where: { $0.name == binName }) {
                bins[at].files += group.items.map(\.path)
                bins[at].videos += group.items.filter(\.isVideo).map(\.path)
            } else {
                bins.append(.init(name: binName, files: group.items.map(\.path), videos: group.items.filter(\.isVideo).map(\.path)))
            }
        }
        var timeline: String?
        if Prefs.bool(PrefKey.makeTimeline) {
            let first = items.map(\.date).min() ?? importDate
            timeline = CardNaming.binName(template: Prefs.string(PrefKey.timelineTemplate), day: first, importDate: importDate, sd: sd, name: name.isEmpty ? nil : name)
        }
        do {
            let result = try await resolve.bridgeClient.send(bins: bins, parent: Prefs.string(PrefKey.binParent), timeline: timeline)
            await resolve.refreshBridge()
            var text = String(localized: "\(result.imported) clips are in \(result.bins.joined(separator: ", ")) in the project \(result.project)")
            if result.alreadyThere > 0 { text += ", " + String(localized: "\(result.alreadyThere) were already there") }
            if let timeline = result.timeline { text += ", " + String(localized: "timeline \(timeline) made") }
            return .init(message: text, failed: false)
        } catch {
            return .init(message: error.localizedDescription, failed: true)
        }
    }
}
