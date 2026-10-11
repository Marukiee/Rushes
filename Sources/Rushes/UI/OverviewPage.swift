import RushesKit
import SwiftUI

/// The first page: what is plugged in, what is being copied, and where space could come back.
struct OverviewPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                UpdateBanner()
                header
                HStack(alignment: .top, spacing: 14) {
                    CardSlot()
                    DiskSlot()
                    ResolveSlot()
                }
                .fixedSize(horizontal: false, vertical: true)

                if let job = app.job {
                    ImportCard(job: job)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                ForEach(app.sessions.filter { $0.phase == .ready && ($0.stage == .waiting || $0.stage == .dismissed) && !$0.hasNothingNew }) { session in
                    WaitingCard(session: session)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
                if app.library.reclaimableBytes > 0 { SavingsCard() }
                RecentImports()
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
            .padding(.top, 6)
        }
        .animation(.rushes, value: app.job?.id)
        .animation(.rushes, value: app.sessions.map(\.id))
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rushes").font(.largeTitle.weight(.bold))
            Text(sentence).font(.title3).foregroundStyle(.secondary)
        }
        .padding(.top, 6)
    }

    private var sentence: String {
        if app.job?.isRunning == true { return String(localized: "Copying right now. Everything is checked when it lands.") }
        if let session = app.sessions.first, session.phase == .ready, session.newItems > 0 {
            return String(localized: "\(session.name) is in with \(session.newItems) new clips and photos.")
        }
        if !app.sessions.isEmpty { return String(localized: "A card is in. Nothing new on it.") }
        if app.destination == nil { return String(localized: "Connect your disk and put a card in. Rushes does the rest.") }
        return String(localized: "Put a card in. Rushes sees it and asks what to do.")
    }
}

// MARK: Slots

private struct Slot<Content: View>: View {
    let title: LocalizedStringKey
    let symbol: String
    var tint: Color = Palette.indigo
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 12, weight: .bold)).foregroundStyle(tint)
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            }
            content
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .surface(radius: Metrics.card)
    }
}

private struct CardSlot: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Slot(title: "Card", symbol: "sdcard.fill") {
            if let session = app.sessions.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(session.name).font(.title3.weight(.bold)).lineLimit(1)
                    switch session.phase {
                    case .scanning:
                        HStack(spacing: 8) { PillSpinner(size: 16); Text("Reading...").foregroundStyle(.secondary) }
                    case .ready:
                        if session.newItems > 0 {
                            Text("\(session.newItems) new, \(Format.bytes(session.newBytes))").foregroundStyle(.secondary)
                        } else {
                            Label("Nothing new", systemImage: "checkmark.circle.fill").foregroundStyle(VerdictStyle.keep)
                        }
                    case let .failed(message):
                        Text(message).foregroundStyle(VerdictStyle.skip)
                    }
                    if app.sessions.count > 1 { Text("+ \(app.sessions.count - 1) more").font(.caption).foregroundStyle(.tertiary) }
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text("No card").font(.title3.weight(.bold)).foregroundStyle(.secondary)
                    Text("Put one in and Rushes shows what is new on it.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct DiskSlot: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Slot(title: "Disk", symbol: "externaldrive.fill") {
            if let disk = app.destination {
                VStack(alignment: .leading, spacing: 8) {
                    Text(disk.name).font(.title3.weight(.bold)).lineLimit(1)
                    StorageBar(capacity: disk.capacity, used: disk.used, reclaimable: app.library.reclaimableBytes)
                    Text("\(Format.bytes(disk.available)) free of \(Format.bytes(disk.capacity))").font(.caption).foregroundStyle(.secondary)
                    if let forecast = forecast(disk) {
                        Text(forecast).font(.caption).foregroundStyle(.tertiary)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not connected").font(.title3.weight(.bold)).foregroundStyle(.secondary)
                    if app.destinationCandidates.isEmpty {
                        Text("Connect your disk.").font(.caption).foregroundStyle(.secondary)
                    } else {
                        Menu("Choose a disk") {
                            ForEach(app.destinationCandidates) { disk in
                                Button("\(disk.name) (\(Format.bytes(disk.available)) free)") { app.chooseDestination(disk) }
                            }
                        }
                        .menuStyle(.button).glassButtonStyle()
                    }
                }
            }
        }
    }

    /// How many more cards fit, going by the cards that were copied before.
    private func forecast(_ disk: VolumeInfo) -> String? {
        let sizes = app.history.filter { $0.status == Ledger.ImportStatus.done && $0.bytes > 0 }.prefix(6).map(\.bytes)
        guard !sizes.isEmpty else { return nil }
        let average = sizes.reduce(0, +) / UInt64(sizes.count)
        guard average > 0 else { return nil }
        return String(localized: "Room for about \(disk.available / average) more cards like your last ones")
    }
}

private struct ResolveSlot: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Slot(title: "DaVinci Resolve", symbol: "film.stack", tint: Palette.rose) {
            if !Prefs.bool(PrefKey.resolveEnabled) {
                Text("Off").font(.title3.weight(.bold)).foregroundStyle(.secondary)
            } else if app.resolve.isScanning {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Reading projects...").font(.title3.weight(.bold))
                    ProgressCapsule(fraction: app.resolve.scanProgress, tint: Palette.rose).frame(height: 6)
                }
            } else if app.resolve.hasIndex {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Format.count(app.resolve.projects.count, one: String(localized: "project"), other: String(localized: "projects"))).font(.title3.weight(.bold))
                    Text("Read \(app.resolve.index.scannedAt.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary)
                    Text(bridgeText).font(.caption).foregroundStyle(.tertiary)
                }
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not read yet").font(.title3.weight(.bold)).foregroundStyle(.secondary)
                    Button("Read projects") { Task { await app.resolve.scan(); app.library.recount(index: app.resolve.index) } }
                        .glassButtonStyle()
                }
            }
        }
    }

    private var bridgeText: String {
        switch app.resolve.bridge {
        case .ready: String(localized: "Resolve is open and answers")
        case .notRunning: String(localized: "Resolve is closed")
        case .notInstalled: String(localized: "Resolve is not installed")
        case .checking: String(localized: "Checking Resolve...")
        case .unavailable: String(localized: "Resolve does not answer")
        case .unknown: ""
        }
    }
}

// MARK: Cards

private struct WaitingCard: View {
    @Environment(AppModel.self) private var app
    let session: CardSession

    var body: some View {
        Card(tint: Palette.indigo) {
            HStack(spacing: 16) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Palette.indigo.gradient, in: .circle)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(session.name) and your disk are in").font(.headline)
                    Text(AppModel.recognitionSummary(session, destination: app.destination)).font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ButtonRow {
                    ActionButton(title: "Review", symbol: "eye", prominent: true) { app.openReview(session) }
                    ActionButton(title: "Copy all", symbol: "square.and.arrow.down") { app.startImport(session, everything: true) }
                        .disabled(app.destination == nil)
                }
                .fixedSize()
            }
        }
    }
}

private struct SavingsCard: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let library = app.library
        Card(tint: Palette.rose) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Space you can get back").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(Format.bytes(library.reclaimableBytes))
                        .font(.system(size: 34, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.rose)
                    Text("\(Format.count(library.reclaimableCount, one: String(localized: "clip"), other: String(localized: "clips"))) in your card folders are in no DaVinci Resolve project.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                ActionButton(title: "Review them", symbol: "arrow.right", prominent: true, tint: Palette.roseDeep) {
                    app.page = .library
                    if let best = library.folders.max(by: { $0.reclaimableBytes < $1.reclaimableBytes }) {
                        library.selectedID = best.id
                        best.review.stateFilter = .unused
                        best.review.kindFilter = .video
                        best.review.refresh()
                    }
                }
            }
        }
    }
}

private struct RecentImports: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let recent = app.history.prefix(4)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionTitle("Recent")
                    Button("All imports") { app.page = .history }.buttonStyle(.plain).foregroundStyle(Palette.indigoLight)
                }
                VStack(spacing: 0) {
                    ForEach(Array(recent.enumerated()), id: \.element.id) { offset, record in
                        HistoryRow(record: record, compact: true)
                        if offset < recent.count - 1 { Divider().padding(.leading, 56) }
                    }
                }
                .surface(radius: Metrics.card)
            }
        }
    }
}
