import AppKit
import RushesKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        @Bindable var app = app
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 300)
        } detail: {
            detail
                .animation(.rushes, value: app.page)
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

/// The system sidebar: a list with symbols and badges, the folders of the library under it. Nothing in it is drawn by hand,
/// so it looks and behaves like the sidebar of any other Mac app, glass included.
struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        List(selection: $app.sidebarSelection) {
            Section {
                Label("Overview", systemImage: "square.grid.2x2").tag(SidebarItem.overview)
                Label("Card", systemImage: "sdcard")
                    .badge(cardBadge)
                    .tag(SidebarItem.card)
            }
            Section("Library") {
                if app.library.folders.isEmpty {
                    Label("Library", systemImage: "externaldrive").tag(SidebarItem.library)
                } else {
                    ForEach(app.library.folders) { folder in
                        Label(folder.name, systemImage: "folder")
                            .badge(folder.reclaimableBytes > 0 ? Text(Format.bytes(folder.reclaimableBytes)) : nil)
                            .tag(SidebarItem.folder(folder.id))
                    }
                }
            }
            Section {
                Label("Imports", systemImage: "clock.arrow.circlepath").tag(SidebarItem.history)
                Label("DaVinci Resolve", systemImage: "film.stack").tag(SidebarItem.resolve)
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Space.s) {
                UpdateBanner(compact: true, fromBottom: true)
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

/// The disk at the foot of the sidebar: whether it is there, and how full it is.
private struct DiskFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 15))
                .foregroundStyle(app.destination == nil ? Color.secondary : Palette.accent)
                .frame(width: 22)
            if let disk = app.destination {
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(disk.name).font(.callout.weight(.medium)).lineLimit(1)
                    StorageBar(capacity: disk.capacity, used: disk.used, reclaimable: app.library.reclaimableBytes)
                    Text("\(Format.bytes(disk.available)) free").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Disk not connected").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(Space.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Metrics.card)
    }
}
