import AppKit
import RushesKit
import SwiftUI

struct MainWindow: View {
    @Environment(AppModel.self) private var app
    @Environment(\.openWindow) private var openWindow
    @LocalState private var columnVisibility: NavigationSplitViewVisibility = .all
    @LocalState private var settling = false

    var body: some View {
        @Bindable var app = app
        NavigationSplitView(columnVisibility: $columnVisibility) {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 230, ideal: 250, max: 300)
        } detail: {
            detail
                .scrollEdgeEffectHidden(settling || columnVisibility != .detailOnly, for: .top)
                .toolbar(removing: .title)
                .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
                .animation(.rushes, value: app.page)
                .onChange(of: app.page) {
                    settling = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { settling = false }
                }
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

struct Sidebar: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 10) {
                    Image(systemName: "sdcard.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 32, height: 32)
                        .background(Palette.indigo.gradient, in: .circle)
                    Text(AppIdentity.displayName).font(.title3.weight(.bold))
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 12)

                row(.overview, "Overview", "square.grid.2x2.fill", badge: nil)
                row(.review, "Card", "sdcard.fill", badge: cardBadge)
                row(.library, "Library", "externaldrive.fill", badge: libraryBadge)
                row(.history, "Imports", "clock.arrow.circlepath", badge: nil)
                row(.resolve, "DaVinci Resolve", "film.stack", badge: nil)
            }
            .padding(.horizontal, 10)
        }
        .scrollContentBackground(.hidden)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 8) {
                UpdateBanner(compact: true, fromBottom: true).padding(.horizontal, 10)
                DiskFooter()
            }
            .padding(.bottom, 10)
        }
    }

    private var cardBadge: Badge? {
        let waiting = app.sessions.filter { $0.phase == .ready && $0.newItems > 0 && $0.stage != .imported }.count
        if app.job?.isRunning == true { return .progress }
        return waiting > 0 ? .count(waiting) : nil
    }

    private var libraryBadge: Badge? {
        app.library.reclaimableBytes > 0 ? .text(Format.bytes(app.library.reclaimableBytes)) : nil
    }

    enum Badge {
        case count(Int)
        case text(String)
        case progress
    }

    private func row(_ page: AppPage, _ title: LocalizedStringKey, _ symbol: String, badge: Badge?) -> some View {
        SidebarButton(selected: app.page == page) {
            app.page = page
        } content: {
            HStack(spacing: 11) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(app.page == page ? Palette.indigoLight : .secondary)
                    .frame(width: 22)
                Text(title).font(.callout.weight(.semibold))
                Spacer(minLength: 4)
                switch badge {
                case let .count(count): Chip(text: "\(count)", tint: Palette.indigoLight)
                case let .text(text): Chip(text: text, tint: Palette.rose)
                case .progress: PillSpinner(size: 15)
                case nil: EmptyView()
                }
            }
            .padding(.vertical, 5)
        }
    }
}

private struct SidebarButton<Content: View>: View {
    let selected: Bool
    let action: () -> Void
    @ViewBuilder var content: Content
    @Environment(\.hoverEnabled) private var hoverEnabled
    @LocalState private var hovering = false

    var body: some View {
        Button(action: action) {
            content
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(selected ? Palette.indigo.opacity(0.16) : Color.primary.opacity(hovering && hoverEnabled ? 0.07 : 0))
                }
                .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(SidebarPressStyle())
        .onHover { hovering = $0 }
        .animation(.rushesFade, value: selected)
        .animation(.rushesFade, value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct SidebarPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.rushesBouncy, value: configuration.isPressed)
    }
}

/// The disk at the foot of the sidebar: whether it is there, and how full it is.
private struct DiskFooter: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "externaldrive.fill")
                .foregroundStyle(app.destination == nil ? Color.secondary : Palette.indigoLight)
            if let disk = app.destination {
                VStack(alignment: .leading, spacing: 4) {
                    Text(disk.name).font(.caption.weight(.semibold)).lineLimit(1)
                    StorageBar(capacity: disk.capacity, used: disk.used, reclaimable: app.library.reclaimableBytes)
                    Text("\(Format.bytes(disk.available)) free").font(.caption2).foregroundStyle(.secondary)
                }
            } else {
                Text("Disk not connected").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .rushesGlass(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .padding(.horizontal, 10)
    }
}
