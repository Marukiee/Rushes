import AppKit
import SwiftUI

/// Development helper. With `RUSHES_DEBUG_DIR` set, the app saves its own windows as PNG whenever it receives SIGUSR1.
/// That is how the interface gets checked without screen recording. Glass draws as flat colour in these pictures, the
/// layout is right.
///
/// `RUSHES_DEBUG_PAGE=overview|review|library|history|resolve` opens that page, `RUSHES_DEBUG_SETTINGS=<section>` the settings,
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
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSettingsWindow() }
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

    /// `RUSHES_DEBUG_SETTINGS=<section>` opens the settings on that section (general, disks, reviewing, library, davinci, updates, about).
    static func initialSettingsSection() -> SettingsSection? {
        variable("RUSHES_DEBUG_SETTINGS").flatMap(SettingsSection.init(rawValue:))
    }

    private static var settingsWindow: NSWindow?

    /// The settings in a window of their own, so a screenshot can be made without reaching the system's Settings scene.
    private static func showSettingsWindow() {
        let host = NSHostingView(rootView: SettingsView().environment(AppModel.shared))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 780, height: 620), styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = host
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
    }

    /// Called when the main window has come up, so a page can be chosen without clicking.
    static func windowAppeared() {
        // `RUSHES_DEBUG_WINDOW=1800x1000` sets the size of the main window, to see how a page lays out at that size.
        if let size = variable("RUSHES_DEBUG_WINDOW")?.split(separator: "x").compactMap({ Double($0) }), size.count == 2 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if let window = NSApp.windows.first(where: { $0.isVisible && $0.contentView != nil && $0.frame.width > 600 }) {
                    window.setFrame(NSRect(x: 60, y: 60, width: size[0], height: size[1]), display: true)
                }
            }
        }
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
        case "hover":
            // The pointer over a clip: `hover:<index>:<fraction>`.
            guard let review, parts.count > 2, let index = Int(parts[1]), let fraction = Double(parts[2]), review.visible.indices.contains(index) else {
                FileHandle.standardError.write(Data("hover: no clip to hover yet\n".utf8))
                return
            }
            let item = review.visible[index]
            HoverPreview.shared.hover(item, root: review.root, at: fraction, knownDuration: review.metadata[item.id]?.duration, look: review.look(for: item))
        case "rate":
            // `rate:<index>:<stars>` gives a clip stars.
            guard let review, parts.count > 2, let index = Int(parts[1]), let stars = Int(parts[2]), review.visible.indices.contains(index) else { return }
            review.focus(review.visible[index].id)
            review.rate(stars)
        case "rating":
            // `rating:any`, `rating:unrated` or `rating:<stars>` for that many stars and more.
            guard let review, parts.count > 1 else { return }
            review.ratingFilter = parts[1] == "any" ? .any : (parts[1] == "unrated" ? .unrated : .atLeast(Int(parts[1]) ?? 1))
            review.refresh()
        case "zoom":
            // `zoom:<factor>` zooms the photo in view from its middle.
            PhotoZoom.current?.zoom(by: CGFloat(Double(parts.last ?? "2") ?? 2))
        case "view":
            withAnimation(.rushes) { model.viewing.toggle() }
        case "look":
            PlayerController.current?.toggleLook()
        case "pause":
            PlayerController.current?.pause()
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
            // The theme frame around the content, so the toolbar is in the picture too.
            guard let view = window.contentView?.superview ?? window.contentView, view.bounds.width > 50 else { continue }
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
        let numbers = NSApp.windows.filter(\.isVisible).map { "\($0.windowNumber)" }.joined(separator: " ")
        try? "\(count) windows\n\(numbers)\n".write(to: directory.appendingPathComponent("snapshot.txt"), atomically: true, encoding: .utf8)
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
