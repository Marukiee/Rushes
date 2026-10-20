import AppKit
import RushesKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @LocalState private var columns: NavigationSplitViewVisibility = .all

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columns) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
                .animation(.rushes, value: app.page)
                // The copy shows on every page while the window is open. The overview has it as a card of its own.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let job = app.job, app.page != .overview {
                        JobBar(job: job).transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.rushes, value: app.job?.id)
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(text: toast)
                    .padding(.bottom, 26)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.rushesSpringy, value: app.toast)
        .alert(item: $app.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message), dismissButton: .default(Text("OK")))
        }
        .confirmationDialog(
            "Point DaVinci Resolve at the new name?",
            isPresented: Binding(get: { app.pendingRelink != nil }, set: { if !$0 { app.pendingRelink = nil } }),
            titleVisibility: .visible, presenting: app.pendingRelink
        ) { request in
            Button("In the open project") { Task { await app.relink(request, allProjects: false) } }
            Button("In all projects") { Task { await app.relink(request, allProjects: true) } }
            Button("Not now", role: .cancel) { app.pendingRelink = nil }
        } message: { _ in
            Text("Clips that Resolve already has keep the old folder name and show as offline. Opening every project briefly takes a moment, and the open project is opened again afterwards.")
        }
        .sheet(item: $app.integrity) { state in IntegritySheet(state: state) }
        // The view mode puts the sidebar away and brings it back when it ends.
        .onChange(of: app.viewing) { _, viewing in withAnimation(.rushes) { columns = viewing ? .detailOnly : .all } }
        .onChange(of: app.page) { _, page in if page != .review && page != .library { app.viewing = false } }
        .onAppear {
            WindowOpener.shared.open = { openWindow(id: "main") }
            DebugSupport.windowAppeared()
        }
        .environment(\.hoverEnabled, !(app.alert != nil || app.pendingRelink != nil || app.integrity != nil))
    }

    @ViewBuilder
    private var detail: some View {
        switch app.page {
        case .overview: OverviewPage()
        case .review: CardReviewPage()
        case .library: LibraryPage()
        case .history: HistoryPage()
        case .resolve: ResolvePage()
        }
    }
}

private struct IntegritySheet: View {
    @Environment(AppModel.self) private var app
    let state: AppModel.IntegrityState

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Checking \(state.folder)").font(.title3.weight(.semibold))
            if state.missingManifest {
                Text("This folder has no list of checksums, because it was not copied by Rushes. Folders copied from now on get one.")
                    .foregroundStyle(.secondary)
            } else if let report = state.report {
                if report.isClean {
                    Label("All \(report.ok) files are exactly as they were copied", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(VerdictStyle.keep)
                } else {
                    Label("\(report.changed.count) changed, \(report.missing.count) missing", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(VerdictStyle.hint)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(report.changed.prefix(30), id: \.self) { Text("Changed: \($0)").font(.caption) }
                            ForEach(report.missing.prefix(30), id: \.self) { Text("Missing: \($0)").font(.caption) }
                        }
                    }
                    .frame(maxHeight: 160)
                }
            } else {
                ProgressCapsule(fraction: state.total > 0 ? Double(state.done) / Double(state.total) : 0).frame(height: 8)
                Text("\(state.done) of \(state.total) files").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { app.integrity = nil }.prominentButtonStyle().tint(Palette.indigo)
            }
        }
        .padding(22)
        .frame(width: 440)
    }
}

// MARK: Sidebar

/// A row of the sidebar that lights up under the pointer, the way the rows of Tandem's sidebar do.
private struct HoverRow<Content: View>: View {
    @Environment(\.hoverEnabled) private var hoverEnabled
    @LocalState private var hovering = false
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                // Drawn a little wider than the label, so it covers the row the way the selection does.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(hovering && hoverEnabled ? 0.08 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -5)
            }
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            .animation(.rushesFade, value: hovering)
    }
}

/// The system sidebar: a list with symbols and badges, the folders of the library under it. Nothing in it is drawn by hand,
/// so it looks and behaves like the sidebar of any other Mac app, glass included.
struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.sidebarSelection) {
            Section {
                HoverRow { Label("Overview", systemImage: "square.grid.2x2") }.tag(SidebarItem.overview)
                HoverRow { Label("Card", systemImage: "sdcard") }
                    .badge(cardBadge)
                    .tag(SidebarItem.card)
            }
            Section("Library") {
                if app.library.folders.isEmpty {
                    HoverRow { Label("Library", systemImage: "externaldrive") }.tag(SidebarItem.library)
                } else {
                    ForEach(app.library.folders) { folder in
                        HoverRow { Label(folder.name, systemImage: "folder") }
                            .badge(folder.reclaimableBytes > 0 ? Text(Format.bytes(folder.reclaimableBytes)) : nil)
                            .tag(SidebarItem.folder(folder.id))
                    }
                }
            }
            Section {
                HoverRow { Label("Imports", systemImage: "clock.arrow.circlepath") }.tag(SidebarItem.history)
                HoverRow { Label("DaVinci Resolve", systemImage: "film.stack") }.tag(SidebarItem.resolve)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Space.s) {
                UpdateBanner(compact: true, fromBottom: true)
                ForEach(app.sessions) { session in CardFooter(session: session) }
                DiskFooter()
            }
            .padding(Space.m)
        }
    }

    private var cardBadge: Int {
        if app.job?.isRunning == true { return 0 }
        return app.sessions.filter { $0.phase == .ready && $0.newItems > 0 && $0.stage != .imported }.count
    }
}

/// A card in the Mac, at the foot of the sidebar above the disk: how full it is, and how much of that is video and how much photos.
private struct CardFooter: View {
    @Environment(AppModel.self) private var app
    var session: CardSession

    var body: some View {
        let volume = session.volume
        let items = session.scan?.items ?? []
        let video = items.filter { $0.kind == .video }.reduce(UInt64(0)) { $0 + $1.totalBytes }
        let photo = items.filter { $0.kind == .photo }.reduce(UInt64(0)) { $0 + $1.totalBytes }
        // What the card holds besides the clips it was read for: the camera's own files, and anything else.
        let other = volume.used > video + photo ? volume.used - video - photo : 0
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: "sdcard.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(Palette.accent)
                    .frame(width: 22)
                Text(volume.name).font(.callout.weight(.medium)).lineLimit(1)
            }
            SegmentedStorageBar(capacity: volume.capacity, parts: [
                .init(id: "video", bytes: session.phase == .ready ? video : volume.used, color: Palette.indigo),
                .init(id: "photo", bytes: photo, color: Palette.rose),
                .init(id: "other", bytes: session.phase == .ready ? other : 0, color: Color.primary.opacity(0.32)),
            ])
            if let job = app.job, job.isRunning, job.cardUUID == volume.uuid {
                // While it copies, the card says how far it is, on every page.
                VStack(alignment: .leading, spacing: 4) {
                    ProgressCapsule(fraction: job.progress?.verifiedFraction ?? 0, ahead: job.progress?.copiedFraction ?? 0).frame(height: 6)
                    Text("Copying to \(job.folderName), \(Int(((job.progress?.fraction ?? 0) * 100).rounded()))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if session.phase == .ready {
                VStack(spacing: 3) {
                    legend("Video", bytes: video, color: Palette.indigo)
                    legend("Photos", bytes: photo, color: Palette.rose)
                    if other > 100 << 20 { legend("Other", bytes: other, color: Color.primary.opacity(0.32)) }
                    legend("Free", bytes: volume.available, color: Color.primary.opacity(0.16))
                }
            } else {
                Text("Reading what is on it...").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Metrics.card)
    }

    /// A dot in the colour of the bar, what it stands for, and how much, with the amounts in one column on the right.
    private func legend(_ title: LocalizedStringKey, bytes: UInt64, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.caption).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(Format.bytes(bytes)).font(.caption.weight(.medium).monospacedDigit())
        }
    }
}

/// The disk at the foot of the sidebar: whether it is there, and how full it is.
private struct DiskFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(spacing: Space.s) {
                Image(systemName: app.copiesToMac ? "laptopcomputer" : "externaldrive.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(app.destination == nil ? Color.secondary : Palette.accent)
                    .frame(width: 22)
                if let disk = app.destination {
                    Text(disk.name).font(.callout.weight(.medium)).lineLimit(1)
                } else {
                    Text("Disk not connected").font(.callout).foregroundStyle(.secondary)
                }
            }
            if let disk = app.destination {
                StorageBar(capacity: disk.capacity, used: disk.used, reclaimable: app.library.reclaimableBytes)
                Text("\(Format.bytes(disk.available)) free").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Metrics.card)
    }
}
