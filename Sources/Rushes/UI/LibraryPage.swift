import AppKit
import RushesKit
import SwiftUI

/// The card folders on the disk, each with what DaVinci Resolve does with its clips. This is where space comes back.
struct LibraryPage: View {
    @Environment(AppModel.self) private var app
    @LocalState private var pendingDelete: [MediaItem]?
    @LocalState private var confirmCleanup = false
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
            } else {
                HStack(alignment: .top, spacing: 0) {
                    FolderList()
                        .frame(width: 290)
                    if let folder = library.selected {
                        VStack(spacing: 0) {
                            FolderHeader(
                                folder: folder,
                                onCleanup: { confirmCleanup = true },
                                onRename: { newName = ""; renaming = true }
                            )
                            ReviewBody(model: folder.review, showUsage: true) { requestDelete(in: folder) }
                        }
                        .id(folder.id)
                    } else {
                        EmptyState(symbol: "square.grid.2x2", title: "Choose a folder", text: "Pick one on the left to look through it.")
                    }
                }
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
        .sheet(isPresented: $renaming) {
            RenameSheet(name: $newName, folder: library.selected) {
                if let folder = library.selected { app.renameFolder(folder, to: newName) }
                renaming = false
            } cancel: { renaming = false }
        }
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

// MARK: Folder list

private struct FolderList: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let library = app.library
        VStack(alignment: .leading, spacing: 12) {
            SavingsTile()
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(library.folders) { folder in
                        FolderRow(folder: folder, selected: library.selectedID == folder.id) { library.selectedID = folder.id }
                    }
                    if library.isLoading {
                        HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Reading folders...").font(.caption).foregroundStyle(.secondary) }
                            .padding(8)
                    }
                }
                .padding(.bottom, 20)
            }
            .scrollIndicators(.never)
        }
        .padding(.leading, 20)
        .padding(.trailing, 12)
    }
}

private struct SavingsTile: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let library = app.library
        VStack(alignment: .leading, spacing: 8) {
            Text("You can free up").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(Format.bytes(library.reclaimableBytes))
                .font(.system(size: 30, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundStyle(Palette.rose)
                .contentTransition(.numericText())
            Text(app.resolve.hasIndex
                 ? Format.count(library.reclaimableCount, one: String(localized: "clip that no project uses"), other: String(localized: "clips that no project uses"))
                 : "Scan DaVinci Resolve to find out which clips are used")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                if app.resolve.isScanning {
                    ProgressView(value: app.resolve.scanProgress).controlSize(.small)
                } else {
                    Button { Task { await app.resolve.scan(); app.library.recount(index: app.resolve.index) } } label: {
                        Label(app.resolve.hasIndex ? "Scan again" : "Scan DaVinci", systemImage: "arrow.triangle.2.circlepath")
                            .font(.caption.weight(.semibold))
                    }
                    .glassButtonStyle()
                    .controlSize(.small)
                }
                if app.resolve.hasIndex {
                    Text(app.resolve.index.scannedAt.formatted(.relative(presentation: .named))).font(.caption2).foregroundStyle(.tertiary)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Metrics.card, tint: Palette.rose)
    }
}

private struct FolderRow: View {
    let folder: LibraryModel.Folder
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    Text(folder.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(Format.bytes(folder.totalBytes)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                StorageBar(capacity: max(folder.totalBytes, 1), used: folder.totalBytes, reclaimable: folder.reclaimableBytes)
                HStack(spacing: 6) {
                    Text("\(folder.itemCount) items").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if folder.reclaimableBytes > 0 {
                        Text("\(Format.bytes(folder.reclaimableBytes)) free to take")
                            .font(.caption.weight(.semibold)).foregroundStyle(Palette.rose)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(selected ? Palette.indigo.opacity(0.16) : Color(nsColor: .controlBackgroundColor))
                    .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(selected ? Palette.indigo.opacity(0.5) : Color.primary.opacity(0.06), lineWidth: 1) }
            }
            .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
        .buttonStyle(.bouncy)
        .animation(.rushesFade, value: selected)
    }
}

// MARK: Folder header

private struct FolderHeader: View {
    @Environment(AppModel.self) private var app
    let folder: LibraryModel.Folder
    let onCleanup: () -> Void
    let onRename: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(folder.name).font(.title2.weight(.bold)).lineLimit(1)
                HStack(spacing: 8) {
                    Chip(text: Format.bytes(folder.totalBytes), symbol: "internaldrive")
                    if app.resolve.hasIndex {
                        Chip(text: String(localized: "\(Format.bytes(folder.usedBytes)) in projects"), symbol: "checkmark.seal.fill", tint: VerdictStyle.keep)
                        Chip(text: String(localized: "\(Format.bytes(folder.reclaimableBytes)) unused"), symbol: "circle.slash", tint: VerdictStyle.skip)
                    }
                    if folder.review.enriching {
                        ProgressView().controlSize(.mini)
                    }
                }
            }
            Spacer(minLength: 12)
            if folder.reclaimableCount > 0 {
                ActionButton(title: "Clean up", symbol: "sparkles", prominent: true, tint: Palette.roseDeep, action: onCleanup)
            }
            Menu {
                Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
                if PathKeys.cardNumber(in: folder.name) != nil {
                    Button("Rename...", systemImage: "pencil", action: onRename)
                }
                Button("Check the files again", systemImage: "checkmark.shield") { app.verify(folder) }
                Divider()
                Button("Read the folder again", systemImage: "arrow.clockwise") { app.reloadLibrary() }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.button)
            .glassButtonStyle()
            .controlSize(.large)
            .menuIndicator(.hidden)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
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
