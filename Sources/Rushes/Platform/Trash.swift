import AppKit
import Foundation

/// Moves files to the Trash and back. Nothing in this app deletes for good: what goes to the Trash can be put back,
/// by Rushes with Undo and by the Finder with Put Back.
enum TrashService {
    struct Moved {
        let original: URL
        let trashed: URL
    }

    /// Trashes the given files. Files that cannot be trashed are reported, the others still go.
    static func trash(_ urls: [URL]) -> (moved: [Moved], failed: [URL]) {
        var moved: [Moved] = []
        var failed: [URL] = []
        for url in urls {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var result: NSURL?
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: &result)
                moved.append(Moved(original: url, trashed: (result as URL?) ?? url))
            } catch {
                failed.append(url)
            }
        }
        return (moved, failed)
    }

    static func restore(_ moved: [Moved]) {
        for item in moved {
            try? FileManager.default.createDirectory(at: item.original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? FileManager.default.moveItem(at: item.trashed, to: item.original)
        }
    }
}
