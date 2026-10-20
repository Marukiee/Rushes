import AppKit
import RushesKit
import SwiftUI

/// Keys for the review, taken straight from the window. SwiftUI's own key handling needs the right view to have the
/// focus, and a grid that is clicked in rarely has it; this works wherever the pointer last was.
struct KeyHandler: NSViewRepresentable {
    var model: ReviewModel
    var player: PlayerController
    var zoom: PhotoZoom
    let perform: (Verdict) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install()
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        context.coordinator.model = model
        context.coordinator.player = player
        context.coordinator.zoom = zoom
        context.coordinator.perform = perform
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.remove() }

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.model = model
        coordinator.player = player
        coordinator.zoom = zoom
        coordinator.perform = perform
        return coordinator
    }

    @MainActor
    final class Coordinator {
        var model: ReviewModel!
        var player: PlayerController!
        var zoom: PhotoZoom!
        var perform: ((Verdict) -> Void)!
        let toggleDetails: () -> Void = { Prefs.defaults.set(!Prefs.bool(PrefKey.showInspector), forKey: PrefKey.showInspector) }
        private var monitor: Any?

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                return MainActor.assumeIsolated { self.handle(event) ? nil : event }
            }
        }

        func remove() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        private func handle(_ event: NSEvent) -> Bool {
            guard let window = NSApp.keyWindow, window.identifier?.rawValue.contains("main") == true else { return false }
            if window.firstResponder is NSTextView || window.attachedSheet != nil { return false }
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

            // Zooming a photo, with and without Command, like in Preview.
            if model.focusItem?.kind == .photo, !flags.contains(.option), !flags.contains(.control) {
                switch key {
                case "=", "+": withAnimation(.rushes) { zoom.zoom(by: 1.5) }; return true
                case "-": withAnimation(.rushes) { zoom.zoom(by: 1 / 1.5) }; return true
                case "0" where flags.contains(.command): withAnimation(.rushes) { zoom.reset() }; return true
                default: break
                }
            }
            if flags.contains(.command) {
                switch key {
                case "z": model.undo(); return true
                case "a": model.selection = Set(model.visible.map(\.id)); return true
                default: return false
                }
            }
            if flags.contains(.control) || flags.contains(.option) { return false }
            let extend = flags.contains(.shift)

            switch event.keyCode {
            case 123: model.move(-1, extend: extend); return true            // left
            case 124: model.move(1, extend: extend); return true             // right
            case 126: model.move(-max(1, model.gridColumns), extend: extend); return true   // up
            case 125: model.move(max(1, model.gridColumns), extend: extend); return true    // down
            case 36, 76: perform(.keep); return true                          // return
            case 51, 117: perform(.skip); return true                         // delete
            case 48: model.moveToNextUndecided(); return true                 // tab
            case 53:                                                          // escape
                if model.selection.count > 1 { model.focus(model.focusID) ; return true }
                return false
            default: break
            }

            switch key {
            case " ": player.togglePlay(); return model.focusItem?.kind == .video
            case "k": player.pause(); return true
            case "l": player.shuttle(forward: true); return true
            case "j": player.shuttle(forward: false); return true
            case ",": player.step(frames: -1); return true
            case ".": player.step(frames: 1); return true
            case "[": player.skip(seconds: -5); return true
            case "]": player.skip(seconds: 5); return true
            case "x": perform(.skip); return true
            case "u": model.set(.undecided, advance: false); return true
            case "r": model.reset(); return true
            case "z": model.undo(); return true
            case "m": player.muted.toggle(); return true
            case "c": player.toggleLook(); return true
            case "i": toggleDetails(); return true
            case "0": model.rate(0); return true
            case "1", "2", "3", "4", "5": model.rate(Int(key) ?? 0); return true
            default: return false
            }
        }
    }
}
