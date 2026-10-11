import AppKit
import SwiftUI

/// Development helper. With `RUSHES_DEBUG_DIR` set, the app saves its own windows as PNG whenever it receives SIGUSR1.
/// That is how the interface gets checked without screen recording. Glass draws as flat colour in these pictures, the
/// layout is right.
///
/// `RUSHES_DEBUG_PAGE=overview|review|library|history|resolve` opens that page, `RUSHES_DEBUG_SETTINGS=1` the settings,
/// `RUSHES_DEBUG_PANEL=1` the menu bar panel in a window, `RUSHES_DEBUG_NO_WINDOW=1` closes the window after a while.
/// `RUSHES_DEBUG_CARD=<folder>` and `RUSHES_DEBUG_DEST=<folder>` make folders stand in for a card and for the disk.
@MainActor
enum DebugSupport {
    private static var signalSource: DispatchSourceSignal?
    private static var installed = false
    private static var panelWindow: NSWindow?

    static var directory: URL? {
        ProcessInfo.processInfo.environment["RUSHES_DEBUG_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private static func variable(_ name: String) -> String? {
        guard directory != nil else { return nil }
        return ProcessInfo.processInfo.environment[name]
    }

    static func install() {
        guard !installed, let directory else { return }
        installed = true
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { snapshot(into: directory) }
        source.resume()
        signalSource = source
        switch variable("RUSHES_DEBUG_APPEARANCE") {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
        if let script = variable("RUSHES_DEBUG_ACTIONS") {
            let steps = script.split(separator: ",").map(String.init)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(6))
                for step in steps { await perform(step, directory: directory); try? await Task.sleep(for: .seconds(1.5)) }
            }
        }
        if variable("RUSHES_DEBUG_SETTINGS") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) }
        }
        if variable("RUSHES_DEBUG_PANEL") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { showPanelWindow() }
        }
        if variable("RUSHES_DEBUG_NO_WINDOW") != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) {
                for window in NSApp.windows where window.isVisible && window.identifier?.rawValue.contains("main") == true { window.close() }
            }
        }
    }

    /// Called when the main window has come up, so a page can be chosen without clicking.
    static func windowAppeared() {
        guard let page = variable("RUSHES_DEBUG_PAGE") else { return }
        let model = AppModel.shared
        switch page {
        case "review": model.page = .review
        case "library": model.page = .library
        case "history": model.page = .history
        case "resolve": model.page = .resolve
        default: model.page = .overview
        }
    }

    private static var shots = 0

    /// A scripted run: `RUSHES_DEBUG_ACTIONS=skip:0,keep:1,wait:3,snapshot,import,wait:8,page:overview,snapshot`.
    private static func perform(_ step: String, directory: URL) async {
        let model = AppModel.shared
        let parts = step.split(separator: ":").map(String.init)
        let review = model.currentReviewSession?.review
        switch parts[0] {
        case "skip", "keep":
            guard let review, parts.count > 1, let index = Int(parts[1]), review.visible.indices.contains(index) else { return }
            review.focus(review.visible[index].id)
            review.set(parts[0] == "skip" ? .skip : .keep)
        case "page":
            switch parts.last ?? "" {
            case "review": model.page = .review
            case "library": model.page = .library
            case "history": model.page = .history
            case "resolve": model.page = .resolve
            default: model.page = .overview
            }
        case "wait":
            try? await Task.sleep(for: .seconds(Double(parts.last ?? "1") ?? 1))
        case "import":
            if let session = model.currentReviewSession { model.startImport(session) }
        case "importall":
            if let session = model.currentReviewSession { model.startImport(session, everything: true) }
        case "snapshot":
            shots += 1
            snapshot(into: directory, prefix: "step\(shots)-")
        case "scanresolve":
            await model.resolve.scan()
            model.library.recount(index: model.resolve.index)
        case "quit":
            NSApp.terminate(nil)
        default: break
        }
    }

    static func snapshot(into directory: URL, prefix: String = "") {
        var count = 0
        for window in NSApp.windows where window.isVisible {
            guard let view = window.contentView, view.bounds.width > 50 else { continue }
            guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            // The window's own background is not part of what a view draws, so it is put underneath.
            let flattened = NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8, samplesPerPixel: 4,
                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
            )!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: flattened)
            var background = NSColor.windowBackgroundColor
            window.effectiveAppearance.performAsCurrentDrawingAppearance { background = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? .black }
            background.setFill()
            NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh).fill()
            rep.draw(in: NSRect(x: 0, y: 0, width: rep.pixelsWide, height: rep.pixelsHigh))
            NSGraphicsContext.restoreGraphicsState()
            guard let png = flattened.representation(using: .png, properties: [:]) else { continue }
            let name = (window.identifier?.rawValue ?? window.title).replacingOccurrences(of: "/", with: "-")
            try? png.write(to: directory.appendingPathComponent("\(prefix)window-\(count)-\(name).png"))
            count += 1
        }
        try? "\(count) windows\n".write(to: directory.appendingPathComponent("snapshot.txt"), atomically: true, encoding: .utf8)
    }

    private static func showPanelWindow() {
        let hosting = NSHostingView(rootView: MenuBarPanel().environment(AppModel.shared))
        hosting.frame = NSRect(x: 0, y: 0, width: 340, height: 420)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Panel"
        window.contentView = hosting
        window.center()
        window.makeKeyAndOrderFront(nil)
        panelWindow = window
    }
}
