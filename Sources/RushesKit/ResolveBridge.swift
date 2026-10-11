import AppKit
import Foundation

/// Runs `resolve_bridge.py`, which talks to the scripting API of DaVinci Resolve Studio. Reading which clips are
/// used does not need Resolve at all (see `ResolveDatabase`); this is for the things only Resolve can do: making bins,
/// importing clips, making a timeline, and pointing clips at a folder that was renamed.
public final class ResolveBridge: @unchecked Sendable {
    public enum BridgeError: Error, LocalizedError {
        case notRunning
        case pythonMissing
        case scriptMissing
        case timeout
        case badAnswer
        case failed(code: String, message: String)

        public var errorDescription: String? {
            switch self {
            case .notRunning: String(localized: "DaVinci Resolve is not open.")
            case .pythonMissing: String(localized: "Python 3 was not found. Install the Command Line Tools with xcode-select --install.")
            case .scriptMissing: String(localized: "The Resolve script is missing from the app.")
            case .timeout: String(localized: "Resolve did not answer in time.")
            case .badAnswer: String(localized: "Resolve gave an answer that could not be read.")
            case let .failed(code, message):
                code == "not_connected"
                    ? String(localized: "Resolve does not allow scripts yet. Set Preferences > General > External scripting using to Local, then try again.")
                    : message
            }
        }
    }

    public static let resolveBundleID = "com.blackmagic-design.DaVinciResolve"

    public static var isResolveRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == resolveBundleID }
    }

    public static var isResolveInstalled: Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: resolveBundleID) != nil
    }

    private let pythonOverride: String?

    public init(pythonPath: String? = nil) {
        pythonOverride = (pythonPath?.isEmpty ?? true) ? nil : pythonPath
    }

    static func scriptURL() -> URL? {
        let manager = FileManager.default
        var candidates: [URL] = []
        if let override = ProcessInfo.processInfo.environment["RUSHES_BRIDGE"] { candidates.append(URL(fileURLWithPath: override)) }
        if let resources = Bundle.main.resourceURL { candidates.append(resources.appendingPathComponent("resolve_bridge.py")) }
        // Running from the source tree (swift run, tests).
        candidates.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/resolve_bridge.py"))
        return candidates.first { manager.fileExists(atPath: $0.path) }
    }

    func pythonPath() -> String? {
        let candidates = [pythonOverride, "/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Sends one command and returns the answer. Throws `notRunning` without starting anything when Resolve is closed.
    public func run(_ command: [String: Any], timeout: TimeInterval = 90) async throws -> [String: Any] {
        guard Self.isResolveRunning else { throw BridgeError.notRunning }
        guard let python = pythonPath() else { throw BridgeError.pythonMissing }
        guard let script = Self.scriptURL() else { throw BridgeError.scriptMissing }
        let input = try JSONSerialization.data(withJSONObject: command)

        let output: Data = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: python)
                process.arguments = [script.path]
                let stdin = Pipe(), stdout = Pipe()
                process.standardInput = stdin
                process.standardOutput = stdout
                process.standardError = Pipe()
                do { try process.run() } catch {
                    continuation.resume(throwing: error)
                    return
                }
                let timer = DispatchSource.makeTimerSource(queue: .global())
                timer.schedule(deadline: .now() + timeout)
                var timedOut = false
                timer.setEventHandler { timedOut = true; process.terminate() }
                timer.resume()
                stdin.fileHandleForWriting.write(input)
                try? stdin.fileHandleForWriting.close()
                let data = stdout.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                timer.cancel()
                if timedOut { continuation.resume(throwing: BridgeError.timeout) } else { continuation.resume(returning: data) }
            }
        }
        guard let object = try? JSONSerialization.jsonObject(with: output) as? [String: Any] else { throw BridgeError.badAnswer }
        if object["ok"] as? Bool != true {
            throw BridgeError.failed(code: object["error"] as? String ?? "error", message: object["message"] as? String ?? "")
        }
        return object
    }

    // MARK: Commands

    public struct Status: Sendable {
        public let version: String
        public let project: String?
        public let timeline: String?
    }

    public func status() async throws -> Status {
        let answer = try await run(["command": "status"])
        return Status(version: answer["version"] as? String ?? "", project: answer["project"] as? String, timeline: answer["timeline"] as? String)
    }

    public struct BinRequest: Sendable {
        public var name: String
        public var files: [String]
        public var videos: [String]
        public init(name: String, files: [String], videos: [String]) {
            self.name = name
            self.files = files
            self.videos = videos
        }
    }

    public struct SendResult: Sendable {
        public let project: String
        public let imported: Int
        public let alreadyThere: Int
        public let bins: [String]
        public let timeline: String?
    }

    public func send(bins: [BinRequest], parent: String?, timeline: String?) async throws -> SendResult {
        var command: [String: Any] = [
            "command": "send",
            "bins": bins.map { ["name": $0.name, "files": $0.files, "videos": $0.videos] },
        ]
        if let parent, !parent.isEmpty { command["parent"] = parent }
        if let timeline { command["timeline"] = timeline }
        let answer = try await run(command, timeout: 300)
        return SendResult(
            project: answer["project"] as? String ?? "", imported: answer["imported"] as? Int ?? 0,
            alreadyThere: answer["alreadyThere"] as? Int ?? 0, bins: answer["bins"] as? [String] ?? [],
            timeline: answer["timeline"] as? String
        )
    }

    public func relink(from old: String, to new: String, allProjects: Bool) async throws -> (relinked: Int, projects: [String]) {
        let answer = try await run(["command": "relink", "from": old, "to": new, "allProjects": allProjects], timeout: 600)
        return (answer["relinked"] as? Int ?? 0, answer["projects"] as? [String] ?? [])
    }

    public func usageOfOpenProject() async throws -> (project: String, clips: [(path: String, usage: Int)]) {
        let answer = try await run(["command": "usage"], timeout: 120)
        let clips = (answer["clips"] as? [[String: Any]] ?? []).map { ($0["path"] as? String ?? "", $0["usage"] as? Int ?? 0) }
        return (answer["project"] as? String ?? "", clips)
    }
}
