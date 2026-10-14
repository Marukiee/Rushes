import AppKit
import RushesKit
import SwiftUI

extension ImportJob {
    /// What part of the card this copy is, when it is not simply what was chosen: "Tue 29 Sep, videos".
    var scopeText: String? {
        var parts: [String] = []
        if let scope = request.scope { parts.append(scope) }
        switch request.kinds {
        case .video: parts.append(String(localized: "videos only"))
        case .photo: parts.append(String(localized: "photos only"))
        case .all: break
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// The copy in the window, along the bottom of every page: how far it is while it runs, and what to do once it is done.
/// The little card in the corner of the screen says the same, but only when the window is not in front.
struct JobBar: View {
    @Environment(AppModel.self) private var app
    var job: ImportJob

    var body: some View {
        Group {
            switch job.phase {
            case .preparing, .copying, .finishing: running
            case .done: done
            case let .failed(message): problem(message)
            case .cancelled: problem(String(localized: "Stopped. What arrived is safe, the rest can be copied again."))
            }
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .frame(maxWidth: .infinity)
        .rushesGlass(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.l)
        .animation(.rushes, value: job.phase)
    }

    // MARK: Running

    private var running: some View {
        let progress = job.progress
        return HStack(spacing: Space.l) {
            PillSpinner(size: 24)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: Space.s) {
                    Text("Copying \(job.cardName) to \(job.folderName)").font(.headline).lineLimit(1)
                    if let scope = job.scopeText { Text(scope).font(.callout).foregroundStyle(.secondary).lineLimit(1) }
                    Spacer(minLength: Space.s)
                    Text("\(Int(((progress?.fraction ?? 0) * 100).rounded()))%")
                        .font(.title3.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText())
                }
                ProgressCapsule(fraction: progress?.verifiedFraction ?? 0, ahead: progress?.copiedFraction ?? 0).frame(height: 8)
                ViewThatFits(in: .horizontal) {
                    stats(progress, full: true)
                    stats(progress, full: false)
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Button("Stop", role: .destructive) { app.cancelImport() }
                .buttonStyle(CapsuleButtonStyle())
                .disabled(job.phase != .copying)
                .help("Stop the copy. What arrived is kept.")
        }
    }

    private func stats(_ progress: CopyProgress?, full: Bool) -> some View {
        HStack(spacing: Space.m) {
            if let progress {
                let total = job.plan.totalBytes
                Text("\(Format.bytes(UInt64(Double(total) * progress.copiedFraction))) of \(Format.bytes(total)) copied")
                Text("\(progress.filesDone) of \(progress.filesTotal) files checked")
                if full, progress.cardBytesPerSecond > 1_000_000 { Text("\(Format.bytes(UInt64(progress.cardBytesPerSecond)))/s") }
                if let left = progress.remaining { Text(Format.remaining(left)) }
            } else {
                Text("Getting ready...")
            }
        }
        .lineLimit(1)
        .fixedSize()
    }

    // MARK: Done

    private var done: some View {
        HStack(spacing: Space.l) {
            Image(systemName: "checkmark.seal.fill").font(.system(size: 24)).foregroundStyle(VerdictStyle.keep)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(job.folderName) is on your disk").font(.headline).lineLimit(1)
                Text(doneDetail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            .layoutPriority(1)
            Spacer(minLength: Space.s)
            // The buttons give way one by one when the window is narrow, the main one stays.
            ViewThatFits(in: .horizontal) {
                actions(finder: true, look: true)
                actions(finder: false, look: true)
                actions(finder: false, look: false)
            }
            Button { app.dismissJob() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.icon)
                .help("Close")
        }
    }

    private var doneDetail: String {
        var parts = [String(localized: "\(Format.count(job.copiedCount, one: String(localized: "file"), other: String(localized: "files"))), \(Format.bytes(job.copiedBytes)), every file checked")]
        if job.plan.skippedItems.count > 0 {
            parts.append(String(localized: "\(job.plan.skippedItems.count) left out (\(Format.bytes(job.plan.skippedBytes)))"))
        }
        if job.plan.notChosenItems.count > 0 {
            parts.append(String(localized: "\(job.plan.notChosenItems.count) not judged stay on the card"))
        }
        if let outcome = job.resolve { parts.append(outcome.message) }
        return parts.joined(separator: "  ·  ")
    }

    private func actions(finder: Bool, look: Bool) -> some View {
        HStack(spacing: Space.s) {
            if finder {
                Button { NSWorkspace.shared.activateFileViewerSelecting([job.folder]) } label: { Label("Show in Finder", systemImage: "folder") }
                    .buttonStyle(CapsuleButtonStyle())
            }
            if look {
                Button { app.library.selectedID = job.folder.path; app.page = .library } label: { Label("Look through it", systemImage: "square.grid.2x2") }
                    .buttonStyle(CapsuleButtonStyle())
            }
            if Prefs.bool(PrefKey.resolveEnabled) {
                Button { Task { await app.sendToResolve(job) } } label: { Label("Send to DaVinci", systemImage: "film.stack") }
                    .buttonStyle(CapsuleButtonStyle())
            }
            if let session = app.sessions.first(where: { $0.volume.uuid == job.cardUUID }) {
                Button { app.eject(session) } label: { Label("Eject card", systemImage: "eject.fill") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
            }
        }
        .fixedSize()
    }

    // MARK: Problem

    private func problem(_ message: String) -> some View {
        HStack(spacing: Space.l) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 22)).foregroundStyle(VerdictStyle.hint)
            VStack(alignment: .leading, spacing: 2) {
                Text("The copy of \(job.cardName) is not complete").font(.headline).lineLimit(1)
                Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: Space.s)
            if let session = app.sessions.first(where: { $0.volume.uuid == job.cardUUID }) {
                Button { app.retry(session) } label: { Label("Copy the rest again", systemImage: "arrow.clockwise") }
                    .buttonStyle(CapsuleButtonStyle(prominent: true))
                    .fixedSize()
            }
            Button { app.dismissJob() } label: { Image(systemName: "xmark").font(.caption.weight(.bold)) }
                .buttonStyle(.icon)
                .help("Close")
        }
    }
}
