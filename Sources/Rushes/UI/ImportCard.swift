import AppKit
import RushesKit
import SwiftUI

/// An import as it runs, and what it says when it is done. Used on the overview and in the menu bar panel.
struct ImportCard: View {
    @Environment(AppModel.self) private var app
    var job: ImportJob
    var compact = false
    /// Without a card of its own, for when it sits on glass already.
    var bare = false
    @LocalState private var name = ""

    var body: some View {
        if bare {
            inner
        } else {
            Card(radius: compact ? 22 : Metrics.card, padding: compact ? 14 : 20, tint: tint) { inner }
        }
    }

    private var inner: some View {
        VStack(alignment: .leading, spacing: 14) {
            switch job.phase {
            case .preparing, .copying, .finishing: running
            case .done: done
            case let .failed(message): problem(message)
            case .cancelled: problem(String(localized: "The copy was stopped. What arrived is safe; the rest can be copied again."))
            }
        }
    }

    private var tint: Color? {
        switch job.phase {
        case .done: VerdictStyle.keep
        case .failed: VerdictStyle.skip
        default: nil
        }
    }

    // MARK: Running

    private var running: some View {
        let progress = job.progress
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                PillSpinner(size: 26)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Copying \(job.cardName) to \(job.folderName)").font(.headline).lineLimit(1)
                    Text(phaseText(progress)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(Int(((progress?.fraction ?? 0) * 100).rounded()))%")
                    .font(.title2.weight(.bold).monospacedDigit())
                    .contentTransition(.numericText())
            }
            ProgressCapsule(fraction: progress?.verifiedFraction ?? 0, ahead: progress?.copiedFraction ?? 0).frame(height: 8)
            HStack {
                if let progress {
                    Text("\(progress.filesDone) of \(progress.filesTotal) checked")
                    Text(Format.bytes(job.plan.totalBytes) + " " + String(localized: "in total"))
                    if progress.cardBytesPerSecond > 1_000_000 {
                        Text("\(Format.bytes(UInt64(progress.cardBytesPerSecond)))/s")
                    }
                    if let left = progress.remaining { Text(Format.remaining(left)) }
                }
                Spacer(minLength: 8)
                Button("Stop", role: .destructive) { app.cancelImport() }
                    .glassButtonStyle()
                    .disabled(job.phase != .copying)
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            if let name = progress?.currentName, !name.isEmpty, !compact {
                Text(name).font(.caption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
    }

    /// Copying and checking run side by side, so the line says both until the copying is through.
    private func phaseText(_ progress: CopyProgress?) -> String {
        var text: String
        if let progress, progress.copiedFraction >= 1 {
            text = String(localized: "Checking the last files against the card")
        } else {
            text = String(localized: "Copying, and checking every file against the card")
        }
        if let scope = job.scopeText { text = scope + "  ·  " + text }
        return text
    }

    // MARK: Done

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 26)).foregroundStyle(VerdictStyle.keep)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(job.folderName) is on your disk").font(.headline)
                    Text("\(Format.count(job.copiedCount, one: String(localized: "file"), other: String(localized: "files"))), \(Format.bytes(job.copiedBytes)), " + String(localized: "every file read back and checked") + (job.backupFolder != nil ? ", " + String(localized: "with a second copy") : ""))
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button { app.dismissJob() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.icon)
                    .help("Close")
            }
            if job.plan.skippedItems.count > 0 {
                Label("\(job.plan.skippedItems.count) left out, \(Format.bytes(job.plan.skippedBytes)) saved", systemImage: "leaf.fill")
                    .font(.callout).foregroundStyle(VerdictStyle.keep)
            }
            if job.plan.notChosenItems.count > 0 {
                Label("\(job.plan.notChosenItems.count) not judged stay on the card", systemImage: "circle.dashed")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if job.needsName, !compact {
                HStack(spacing: 8) {
                    TextField("Give \(job.folderName) a name, like Sweden (optional)", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveName)
                    Button("Save name", action: saveName).glassButtonStyle().disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Not now") { job.needsName = false }.buttonStyle(.plain).foregroundStyle(.secondary)
                }
            }
            if let outcome = job.resolve {
                Label(outcome.message, systemImage: outcome.failed ? "exclamationmark.triangle.fill" : "film.stack")
                    .font(.callout)
                    .foregroundStyle(outcome.failed ? VerdictStyle.hint : .secondary)
            }
            if let note = job.integrityNote { Text(note).font(.caption).foregroundStyle(.secondary) }
            WrapRow(spacing: 8) {
                Button { NSWorkspace.shared.activateFileViewerSelecting([job.folder]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .glassButtonStyle()
                Button { app.page = .library; app.library.selectedID = job.folder.path; WindowOpener.shared.openMain() } label: {
                    Label("Look through it", systemImage: "square.grid.2x2")
                }
                .glassButtonStyle()
                if Prefs.bool(PrefKey.resolveEnabled) {
                    Button { Task { await app.sendToResolve(job) } } label: { Label("Send to DaVinci", systemImage: "film.stack") }
                        .glassButtonStyle()
                }
                if let session = app.sessions.first(where: { $0.volume.uuid == job.cardUUID }) {
                    Button { app.eject(session) } label: { Label("Eject card", systemImage: "eject.fill") }
                        .prominentButtonStyle().tint(Palette.indigo)
                }
            }
            .controlSize(compact ? .small : .regular)
        }
    }

    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        Task { await app.rename(job: job, to: trimmed) }
    }

    // MARK: Problem

    private func problem(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 24)).foregroundStyle(VerdictStyle.hint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("The copy of \(job.cardName) is not complete").font(.headline)
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Button { app.dismissJob() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                    .buttonStyle(.icon)
            }
            ForEach(Array(job.failedFiles.prefix(4).enumerated()), id: \.offset) { _, failed in
                Text("\(failed.task.entry.name): \(failed.message)").font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            if job.failedFiles.count > 4 { Text("and \(job.failedFiles.count - 4) more").font(.caption).foregroundStyle(.tertiary) }
            if let session = app.sessions.first(where: { $0.volume.uuid == job.cardUUID }) {
                ActionButton(title: "Copy the rest again", symbol: "arrow.clockwise", prominent: true) { app.retry(session) }
            }
        }
    }
}
