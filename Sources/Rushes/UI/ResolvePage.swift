import RushesKit
import SwiftUI

/// What Rushes knows about DaVinci Resolve, and the switches for what it may do there.
struct ResolvePage: View {
    @Environment(AppModel.self) private var app
    @AppStorage(PrefKey.resolveEnabled) private var enabled = true
    @AppStorage(PrefKey.sendToResolve) private var sendAfterImport = false
    @AppStorage(PrefKey.binTemplate) private var template = "{datum}"
    @AppStorage(PrefKey.binPerDay) private var perDay = true
    @AppStorage(PrefKey.makeTimeline) private var makeTimeline = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Rushes reads your Resolve projects to see which clips are used, and can put new footage in a bin for you.")
                    .font(.title3).foregroundStyle(.secondary).padding(.top, 2)

                Card {
                    Toggle(isOn: $enabled) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Look at my Resolve projects").font(.headline)
                            Text("Read-only. The project files are copied first, so Resolve is never disturbed.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .toggleStyle(.switch)
                }

                if enabled {
                    projects
                    scripting
                    sending
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
        }
        .navigationTitle("DaVinci Resolve")
        .task { await app.resolve.refreshBridge() }
    }

    // MARK: Projects

    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle("Projects", detail: app.resolve.hasIndex ? String(localized: "read \(app.resolve.index.scannedAt.formatted(.relative(presentation: .named)))") : nil)
                if app.resolve.isScanning {
                    ProgressView().controlSize(.small)
                } else {
                    Button { Task { await app.resolve.scan(); app.library.recount(index: app.resolve.index) } } label: {
                        Label("Read again", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .glassButtonStyle()
                }
            }
            if let error = app.resolve.lastScanError {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.callout).foregroundStyle(VerdictStyle.hint)
            }
            if app.resolve.projects.isEmpty {
                Card { Text("No projects found yet. Rushes looks in the local database of Resolve. If you use a PostgreSQL database, the projects cannot be read this way.").font(.callout).foregroundStyle(.secondary) }
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(app.resolve.projects.enumerated()), id: \.element.id) { offset, project in
                        HStack(spacing: 12) {
                            Image(systemName: project.failed ? "exclamationmark.triangle.fill" : "film.stack")
                                .foregroundStyle(project.failed ? VerdictStyle.hint : Palette.roseInk)
                                .frame(width: 24)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(project.name).font(.callout.weight(.semibold))
                                Text(project.failed
                                     ? String(localized: "Could not be read")
                                     : String(localized: "\(project.timelineClips) clips on timelines, \(project.poolClips) in the media pool"))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 8)
                            Text("Saved " + project.modified.formatted(.relative(presentation: .named))).font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 9)
                        if offset < app.resolve.projects.count - 1 { Divider().padding(.leading, 50) }
                    }
                }
                .surface(radius: Metrics.card)
                Text("Resolve writes a project to disk when you save it (Cmd S). Clips you used since the last save show as unused until then.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Scripting

    private var scripting: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("Talking to Resolve")
            Card {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Image(systemName: statusSymbol).font(.system(size: 20)).foregroundStyle(statusTint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(statusTitle).font(.headline)
                            Text(statusDetail).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        switch app.resolve.bridge {
                        case .notRunning: Button("Open Resolve") { app.resolve.openResolve() }.prominentButtonStyle().tint(Palette.indigo)
                        default: Button("Check again") { Task { await app.resolve.refreshBridge() } }.glassButtonStyle()
                        }
                    }
                    Text("Bins, importing and renaming need Resolve Studio to be open, with Preferences, General, External scripting using set to Local.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var statusSymbol: String {
        switch app.resolve.bridge {
        case .ready: "checkmark.circle.fill"
        case .notRunning, .unknown, .checking: "moon.zzz.fill"
        case .notInstalled, .unavailable: "exclamationmark.triangle.fill"
        }
    }

    private var statusTint: Color {
        switch app.resolve.bridge {
        case .ready: VerdictStyle.keep
        case .notInstalled, .unavailable: VerdictStyle.hint
        default: .secondary
        }
    }

    private var statusTitle: String {
        switch app.resolve.bridge {
        case let .ready(version, _): String(localized: "Resolve \(version) answers")
        case .notRunning: String(localized: "Resolve is closed")
        case .notInstalled: String(localized: "Resolve is not installed")
        case .checking: String(localized: "Asking Resolve...")
        case .unavailable: String(localized: "Resolve does not answer")
        case .unknown: String(localized: "Not checked yet")
        }
    }

    private var statusDetail: String {
        switch app.resolve.bridge {
        case let .ready(_, project): project.map { String(localized: "Open project: \($0)") } ?? String(localized: "No project is open")
        case .notRunning: String(localized: "Open Resolve to send footage to it. Reading which clips are used works without.")
        case let .unavailable(message): message
        default: ""
        }
    }

    // MARK: Sending

    private var sending: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionTitle("New footage")
            Card {
                VStack(alignment: .leading, spacing: 14) {
                    Toggle(isOn: $sendAfterImport) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Put new footage in a bin after each import").font(.callout.weight(.semibold))
                            Text("In the project that is open in Resolve. If Resolve is closed, nothing is lost: send it later from the history.").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Divider()
                    HStack {
                        Text("Bin name").frame(width: 110, alignment: .leading)
                        TextField("{datum}", text: $template).textFieldStyle(.roundedBorder)
                    }
                    Text("Now: \(example)").font(.caption).foregroundStyle(.secondary).padding(.leading, 110)
                    Text("{datum} the day of shooting, {sd} like SD 5, {naam} the words after the number, {importdatum}, {jaar}, {maand}")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.leading, 110)
                    Toggle("A bin for each day of shooting", isOn: $perDay)
                    Toggle("Also make a timeline of the video clips, in shooting order", isOn: $makeTimeline)
                }
            }
        }
    }

    private var example: String {
        CardNaming.binName(template: template.isEmpty ? "{datum}" : template, day: Date(), importDate: Date(), sd: "SD 5", name: "Sweden")
    }
}
