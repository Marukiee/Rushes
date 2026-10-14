import AppKit
import SwiftUI

@main
struct RushesApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @LocalState private var model = AppModel.shared

    var body: some Scene {
        Window(AppIdentity.displayName, id: "main") {
            ReleasedWhenClosed {
                MainWindow().environment(model)
            }
            .frame(minWidth: 1000, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 800)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarPanel().environment(model)
        } label: {
            MenuBarIcon().environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environment(model)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var terminateSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Prefs.register()
        let showInDock = UserDefaults.standard.object(forKey: PrefKey.showInDock) as? Bool ?? true
        NSApp.setActivationPolicy(showInDock ? .regular : .accessory)
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { RunLoop.main.perform(inModes: [.common]) { NSApp.terminate(nil) } }
        source.resume()
        terminateSignal = source
        watchWindows()
        Task { @MainActor in
            AppModel.shared.start()
            DebugSupport.install()
            Updater.shared.checkIfDue()
            Updater.shared.startPeriodicChecks()
            if ProcessInfo.processInfo.environment["RUSHES_UPDATE_TEST_FROM"] != nil {
                Task { try? await Task.sleep(for: .seconds(4)); await Updater.shared.runTestUpdate() }
            }
        }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        Task { @MainActor in
            Updater.shared.checkIfDue()
            AppModel.shared.syncPrompt()
        }
    }

    /// The card in the corner takes over from the window when the person goes elsewhere.
    func applicationDidResignActive(_ notification: Notification) {
        Task { @MainActor in AppModel.shared.syncPrompt() }
    }

    private func watchWindows() {
        let center = NotificationCenter.default
        for name in [NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification, NSWindow.didBecomeKeyNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                // After the window has settled, so the check sees the new state.
                DispatchQueue.main.async { MainActor.assumeIsolated { AppModel.shared.syncPrompt() } }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// A click on the Dock icon with no window open brings the window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in WindowOpener.shared.openMain() } }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A copy that is running is a reason to ask first: leaving now leaves a half copied folder.
        let running = MainActor.assumeIsolated { AppModel.shared.job?.isRunning == true }
        guard running else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = String(localized: "A card is still being copied")
        alert.informativeText = String(localized: "If you quit now, the files that were not finished are left out. Rushes picks them up again next time the card is in.")
        alert.addButton(withTitle: String(localized: "Keep copying"))
        alert.addButton(withTitle: String(localized: "Quit anyway"))
        return alert.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }
}
