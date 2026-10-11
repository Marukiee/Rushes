import Foundation

/// Tells the installed app apart from a development build.
///
/// A debug build carries the bundle id `nl.markmaaktmedia.Rushes.dev`, so macOS gives it its own preferences and
/// permissions. Its data folder differs too, otherwise a test run would rewrite the ledger of the real app.
enum AppIdentity {
    static var isDevelopmentBuild: Bool {
        Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
    }

    static var displayName: String { isDevelopmentBuild ? "Rushes Dev" : "Rushes" }

    /// The folder for this app's data. `RUSHES_DATA_DIR` overrides it for tests.
    static func dataDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["RUSHES_DATA_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent(isDevelopmentBuild ? "Rushes-Dev" : "Rushes", isDirectory: true)
    }
}

extension Bundle {
    var appVersion: String { (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0" }
}
