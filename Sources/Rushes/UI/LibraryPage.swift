import AppKit
import RushesKit
import SwiftUI

/// The card folders on the disk, each with what DaVinci Resolve does with its clips. This is where space comes back.
struct LibraryPage: View {
    @Environment(AppModel.self) private var app
    @LocalState private var pendingDelete: [MediaItem]?
    @LocalState private var confirmCleanup = false
    @LocalState private var confirmLeftOut = false
    @LocalState private var renaming = false
    @LocalState private var newName = ""

    var body: some View {
        let library = app.library
        Group {
            if app.destination == nil, library.folders.isEmpty {
                EmptyState(
                    symbol: "externaldrive.badge.questionmark",
                    title: "Your disk is not connected",
                    text: "Connect your disk to see the folders on it and which clips DaVinci Resolve uses."
                )
            } else if library.folders.isEmpty, !library.isLoading {
                EmptyState(
                    symbol: "folder",
                    title: "No card folders yet",
                    text: "Folders named SD 1, SD 2 and so on show up here. The first card you copy makes the first one."
                )
            } else if let folder = library.selected {
                ReviewBody(model: folder.review, showUsage: true, onRequestDelete: { requestDelete(in: folder) }) {
                    LeftOutBanner(folder: folder) { confirmLeftOut = true }
                    SavingsBanner(folder: folder) { confirmCleanup = true }
                }
                .id(folder.id)
            } else {
                EmptyState(symbol: "square.grid.2x2", title: "Choose a folder", text: "Pick one in the sidebar to look through it.")
            }
        }
        .navigationTitle(library.selected?.name ?? String(localized: "Library"))
        .navigationSubtitle(library.selected.map { [subtitle(for: $0), $0.review.progressText].filter { !$0.isEmpty }.joined(separator: "  ·  ") } ?? "")
        .toolbar {
            if let folder = library.selected {
                ReviewToolbar(model: folder.review)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) { FolderMenu(folder: folder) { newName = ""; renaming = true } }
            }
        }
        .confirmationDialog(
            deleteTitle, isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
            titleVisibility: .visible, presenting: pendingDelete
        ) { items in
            Button("Move to the Trash", role: .destructive) {
                if let folder = library.selected { folder.review.trashItems(items) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { items in
            Text(deleteMessage(items))
        }
        .confirmationDialog(
            "Move every clip no project uses to the Trash?", isPresented: $confirmCleanup, titleVisibility: .visible
        ) {
            if let folder = library.selected {
                let items = app.unusedItems(in: folder)
                Button("Move \(items.count) clips (\(Format.bytes(items.reduce(0) { $0 + $1.totalBytes }))) to the Trash", role: .destructive) {
                    folder.review.trashItems(items)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Only clips that are in no DaVinci Resolve project, and that you did not protect. They go to the Trash, so you can still put them back.")
        }
        .confirmationDialog(
            "Move what you left out on the card to the Trash?", isPresented: $confirmLeftOut, titleVisibility: .visible
        ) {
            if let folder = library.selected {
                let items = app.leftOutItems(in: folder)
                Button("Move \(items.count) (\(Format.bytes(items.reduce(0) { $0 + $1.totalBytes }))) to the Trash", role: .destructive) {
                    folder.review.trashItems(items)
                    folder.review.leftOutOnCard.subtract(items.map(\.id))
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            if let folder = library.selected, app.leftOutInUse(in: folder) > 0 {
                Text("\(app.leftOutInUse(in: folder)) of them are used in DaVinci Resolve and stay. The rest goes to the Trash, so you can still put it back.")
            } else {
                Text("They go to the Trash, so you can still put them back. The card is not touched.")
            }
        }
        .sheet(isPresented: $renaming) {
            RenameSheet(name: $newName, folder: library.selected) {
                if let folder = library.selected { app.renameFolder(folder, to: newName) }
                renaming = false
            } cancel: { renaming = false }
        }
    }

    private func subtitle(for folder: LibraryModel.Folder) -> String {
        var parts = [Format.bytes(folder.totalBytes)]
        if app.resolve.hasIndex {
            parts.append(String(localized: "\(Format.bytes(folder.usedBytes)) in projects"))
            parts.append(String(localized: "\(Format.bytes(folder.reclaimableBytes)) unused"))
        }
        return parts.joined(separator: "  ·  ")
    }

    // MARK: Deleting

    private func requestDelete(in folder: LibraryModel.Folder) {
        let review = folder.review
        let ids = review.selection.isEmpty ? [review.focusID].compactMap { $0 } : Array(review.selection)
        let items = review.visible.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        // A clip that a project uses gets a question first. One that nothing uses just goes, and Undo brings it back.
        let risky = items.contains { review.usage[$0.id].map { $0.status != .unused } ?? false }
        if risky || items.count > 1 && items.contains(where: { review.verdicts[$0.id] == .keep }) {
            pendingDelete = items
        } else {
            review.set(.skip)
        }
    }

    private var deleteTitle: String {
        guard let items = pendingDelete else { return "" }
        return items.count == 1 ? String(localized: "This clip is used in DaVinci Resolve") : String(localized: "\(items.count) clips, some in use")
    }

    private func deleteMessage(_ items: [MediaItem]) -> String {
        guard let review = app.library.selected?.review else { return "" }
        let projects = Set(items.flatMap { review.usage[$0.id]?.projects.map(\.project) ?? [] }).sorted()
        let names = projects.prefix(4).joined(separator: ", ")
        if projects.isEmpty { return String(localized: "They may be protected. They go to the Trash and can be put back.") }
        return String(localized: "In: \(names). The clip will be offline in those projects until you put it back.")
    }
}

// MARK: Banner and menu

/// What was left out while the card was in and is here anyway, because it was copied before it was judged.
private struct LeftOutBanner: View {
    @Environment(AppModel.self) private var app
    let folder: LibraryModel.Folder
    let cleanup: () -> Void

    var body: some View {
        let items = app.leftOutItems(in: folder)
        if !items.isEmpty {
            InfoBanner(
                symbol: "xmark.circle.fill", tint: VerdictStyle.skip,
                text: String(localized: "\(items.count) you left out on the card are still here (\(Format.bytes(items.reduce(0) { $0 + $1.totalBytes })))")
            ) {
                Button("Show") { folder.review.stateFilter = .leftOut; folder.review.refresh() }
                    .buttonStyle(.bordered)
                Button("Move to the Trash", action: cleanup)
                    .buttonStyle(.borderedProminent)
                    .tint(VerdictStyle.skip)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// What can be freed in this folder, with the button that does it. Before DaVinci has been read it offers to read it.
private struct SavingsBanner: View {
    @Environment(AppModel.self) private var app
    let folder: LibraryModel.Folder
    let cleanup: () -> Void

    var body: some View {
        if !app.resolve.hasIndex {
            InfoBanner(symbol: "film.stack", text: String(localized: "Scan DaVinci Resolve to find out which clips are used")) {
                if app.resolve.isScanning {
                    ProgressView(value: app.resolve.scanProgress).frame(width: 120)
                } else {
                    Button("Scan DaVinci") { rescan() }.buttonStyle(.borderedProminent)
                }
            }
        } else if folder.reclaimableCount > 0 {
            InfoBanner(
                symbol: "leaf.fill", tint: Palette.roseInk,
                text: String(localized: "\(Format.bytes(folder.reclaimableBytes)) can be freed here: \(Format.count(folder.reclaimableCount, one: String(localized: "clip that no project uses"), other: String(localized: "clips that no project uses")))")
            ) {
                Button { rescan() } label: { Label("Scan again", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.bordered)
                    .disabled(app.resolve.isScanning)
                Button("Clean up", action: cleanup).buttonStyle(.borderedProminent)
            }
        } else {
            InfoBanner(symbol: "checkmark.seal.fill", tint: VerdictStyle.keep, text: String(localized: "Every clip here is used by a project, or protected")) {
                Button { rescan() } label: { Label("Scan again", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(.bordered)
                    .disabled(app.resolve.isScanning)
            }
        }
    }

    private func rescan() {
        Task { await app.resolve.scan(); app.library.recount(index: app.resolve.index) }
    }
}

private struct FolderMenu: View {
    @Environment(AppModel.self) private var app
    let folder: LibraryModel.Folder
    let onRename: () -> Void

    var body: some View {
        Menu {
            Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
            if PathKeys.cardNumber(in: folder.name) != nil {
                Button("Rename...", systemImage: "pencil", action: onRename)
            }
            Button("Check the files again", systemImage: "checkmark.shield") { app.verify(folder) }
            Divider()
            Button("Read the folder again", systemImage: "arrow.clockwise") { app.reloadLibrary() }
        } label: {
            Label("Folder", systemImage: "ellipsis")
        }
        .help("Folder")
    }
}

private struct RenameSheet: View {
    @Binding var name: String
    let folder: LibraryModel.Folder?
    let save: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename \(folder?.name ?? "")").font(.title3.weight(.semibold))
            Text("The number stays, so Rushes and DaVinci Resolve still know the folder. Only the words after it change.")
                .font(.callout).foregroundStyle(.secondary)
            TextField("Name, like Sweden Morocco Spain", text: $name).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel", action: cancel).glassButtonStyle()
                Button("Rename", action: save).prominentButtonStyle().tint(Palette.indigo)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(22)
        .frame(width: 420)
    }
}
