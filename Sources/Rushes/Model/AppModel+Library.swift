import AppKit
import Foundation
import RushesKit

extension AppModel {
    // MARK: Renaming a folder

    /// Renames a card folder on the disk, keeps the memory of the app right, and offers to point Resolve at the new name.
    func renameFolder(_ folder: LibraryModel.Folder, to name: String) {
        guard let number = PathKeys.cardNumber(in: folder.name) else { return }
        let newName = CardNaming.folderName(number: number, name: name)
        guard newName != folder.name else { return }
        let old = folder.url
        let new = old.deletingLastPathComponent().appendingPathComponent(newName, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: new.path) else {
            alert = AppAlert(title: String(localized: "That name is already in use"), message: newName)
            return
        }
        do {
            try FileManager.default.moveItem(at: old, to: new)
        } catch {
            alert = AppAlert(title: String(localized: "The folder could not be renamed"), message: error.localizedDescription)
            return
        }
        ledger.rewriteDestinations(from: old.path, to: new.path)
        for record in ledger.imports() where record.folder == new.path || record.folder == old.path {
            ledger.updateImportLabel(id: record.id, label: newName, folder: new.path)
        }
        library.selectedID = new.path
        refreshHistory()
        reloadLibrary()
        showToast(String(localized: "Renamed to \(newName)"))
        if Prefs.bool(PrefKey.resolveEnabled), ResolveBridge.isResolveRunning {
            pendingRelink = RelinkRequest(from: old.path, to: new.path)
        }
    }

    func relink(_ request: RelinkRequest, allProjects: Bool) async {
        pendingRelink = nil
        do {
            let result = try await resolve.bridgeClient.relink(from: request.from, to: request.to, allProjects: allProjects)
            if result.relinked > 0 {
                showToast(String(localized: "\(result.relinked) clips in Resolve now point to the new name"))
            } else {
                showToast(String(localized: "No clips in Resolve pointed to the old name"))
            }
            await resolve.scan()
            library.recount(index: resolve.index)
        } catch {
            alert = AppAlert(title: String(localized: "Resolve could not be updated"), message: error.localizedDescription)
        }
    }

    // MARK: Integrity

    /// Reads every file of a card folder again and compares it with what was written when it was copied.
    func verify(_ folder: LibraryModel.Folder) {
        let url = folder.url
        guard let manifest = Manifest.load(from: url) else {
            integrity = IntegrityState(folder: folder.name, done: 0, total: 0, report: nil, missingManifest: true)
            return
        }
        integrity = IntegrityState(folder: folder.name, done: 0, total: manifest.entries.count, report: nil)
        let id = integrity?.id
        Task {
            let report = await Task.detached(priority: .utility) {
                IntegrityChecker.verify(folder: url) { done, total in
                    Task { @MainActor in
                        if AppModel.shared.integrity?.id == id { AppModel.shared.integrity?.done = done; AppModel.shared.integrity?.total = total }
                    }
                }
            }.value
            if integrity?.id == id { integrity?.report = report }
        }
    }

    // MARK: Cleaning up

    /// Clips that no project uses, in a folder or in all of them. Photos only when asked for.
    func unusedItems(in folder: LibraryModel.Folder) -> [MediaItem] {
        let photos = Prefs.bool(PrefKey.photosInSavings)
        let review = folder.review
        return review.allItems.filter { item in
            review.usage[item.id]?.status == .unused && review.verdicts[item.id] != .keep && (item.kind == .video || photos)
        }
    }
}
