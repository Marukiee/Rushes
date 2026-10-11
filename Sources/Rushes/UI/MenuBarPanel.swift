import AppKit
import RushesKit
import SwiftUI

/// The icon in the menu bar: a card that fills in when one is in, and pulses while copying.
struct MenuBarIcon: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let copying = app.job?.isRunning == true
        let present = !app.sessions.isEmpty
        Image(systemName: present ? "sdcard.fill" : "sdcard")
            .symbolEffect(.pulse, isActive: copying)
            .task {
                WindowOpener.shared.open = { openWindow(id: "main") }
                app.start()
                DebugSupport.install()
            }
    }
}

struct MenuBarPanel: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                PairGlyph(disk: app.destination != nil && !app.sessions.isEmpty)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.headline).lineLimit(1)
                    Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer(minLength: 0)
            }

            UpdateBanner(compact: true)

            if let job = app.job {
                ImportCard(job: job, compact: true)
            } else if let session = app.sessions.first(where: { $0.phase == .ready && $0.newItems > 0 && $0.stage != .imported }) {
                ButtonRow(spacing: 8) {
                    ActionButton(title: "Review", symbol: "eye", prominent: true, wide: true) { app.openReview(session); NSApp.activate() }
                    ActionButton(title: "Copy all", symbol: "square.and.arrow.down", wide: true) { app.startImport(session, everything: true) }
                        .disabled(app.destination == nil)
                }
            }

            if app.library.reclaimableBytes > 0 {
                Button {
                    app.page = .library
                    WindowOpener.shared.openMain()
                } label: {
                    HStack {
                        Image(systemName: "leaf.fill").foregroundStyle(Palette.roseInk)
                        Text("\(Format.bytes(app.library.reclaimableBytes)) can be freed")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                    .font(.callout)
                    .padding(10)
                    .background(Palette.rose.opacity(0.12), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                }
                .buttonStyle(.bouncy)
            }

            Divider()
            HStack {
                Button { WindowOpener.shared.openMain() } label: { Label("Open Rushes", systemImage: "macwindow") }
                    .buttonStyle(.plain)
                Spacer()
                SettingsLink { Image(systemName: "gearshape") }.buttonStyle(.icon)
                Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }.buttonStyle(.icon).help("Quit")
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 340)
    }

    private var title: String {
        if app.job?.isRunning == true { return String(localized: "Copying...") }
        if let session = app.sessions.first {
            return app.destination == nil ? String(localized: "\(session.name) is in") : String(localized: "\(session.name) and your disk")
        }
        return app.destination.map { $0.name } ?? String(localized: "Rushes")
    }

    private var subtitle: String {
        if let job = app.job, job.isRunning {
            return job.progress.map { "\(Int($0.fraction * 100))%  \(Format.remaining($0.remaining))" } ?? ""
        }
        if let session = app.sessions.first, session.phase == .ready {
            return session.newItems > 0 ? AppModel.recognitionSummary(session, destination: app.destination) : String(localized: "Nothing new on the card")
        }
        if app.destination == nil { return String(localized: "Connect your disk") }
        return String(localized: "Waiting for a card")
    }
}
