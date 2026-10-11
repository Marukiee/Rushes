import Foundation
import RushesKit

/// What happens when a card and the disk are both in.
enum CardBehavior: String, CaseIterable, Identifiable {
    /// Open the review. Only what is kept is copied.
    case review
    /// Copy everything new at once. Looking through it can be done afterwards, on the disk.
    case copyAll
    /// Show the card and wait for a choice.
    case ask

    var id: String { rawValue }
}

enum LUTMode: String, CaseIterable, Identifiable {
    case off, auto, builtIn

    var id: String { rawValue }
}

/// Every setting, by key. Views use these keys with `@AppStorage`; everything else reads through `Prefs`, at the
/// moment it needs the value, so a change takes effect without restarting anything.
enum PrefKey {
    static let cardBehavior = "cardBehavior"
    static let showRecognitionCard = "showRecognitionCard"
    static let openWindowOnCard = "openWindowOnCard"
    static let notifyWhenDone = "notifyWhenDone"
    static let ejectAfterImport = "ejectAfterImport"
    static let showInDock = "showInDock"
    static let destinationUUID = "destinationUUID"
    static let destinationName = "destinationName"
    static let destinationSubfolder = "destinationSubfolder"
    static let askForName = "askForName"
    static let backupEnabled = "backupEnabled"
    static let backupUUID = "backupUUID"
    static let backupName = "backupName"
    static let backupSubfolder = "backupSubfolder"
    static let undecidedMeansKeep = "undecidedMeansKeep"
    static let showInspector = "showInspector"
    static let showKnown = "showKnown"
    static let autoplay = "autoplay"
    static let soundOn = "soundOn"
    static let loopClips = "loopClips"
    static let advanceAfterVerdict = "advanceAfterVerdict"
    static let useProxies = "useProxies"
    static let lutMode = "lutMode"
    static let finderTags = "finderTags"
    static let suggestionsEnabled = "suggestionsEnabled"
    static let shortClipSeconds = "shortClipSeconds"
    static let blurRatio = "blurRatio"
    static let extraFolders = "extraFolders"
    static let photosInSavings = "photosInSavings"
    static let resolveEnabled = "resolveEnabled"
    static let resolveAutoScan = "resolveAutoScan"
    static let resolveRoots = "resolveRoots"
    static let resolveMappings = "resolveMappings"
    static let sendToResolve = "sendToResolve"
    static let binTemplate = "binTemplate"
    static let binParent = "binParent"
    static let binPerDay = "binPerDay"
    static let makeTimeline = "makeTimeline"
    static let timelineTemplate = "timelineTemplate"
    static let pythonPath = "pythonPath"
    static let autoCheckUpdates = "autoCheckUpdates"
}

enum Prefs {
    static let defaults = UserDefaults.standard

    static func register() {
        defaults.register(defaults: [
            PrefKey.cardBehavior: CardBehavior.review.rawValue,
            PrefKey.showRecognitionCard: true,
            PrefKey.openWindowOnCard: true,
            PrefKey.notifyWhenDone: true,
            PrefKey.ejectAfterImport: false,
            PrefKey.showInDock: true,
            PrefKey.askForName: true,
            PrefKey.undecidedMeansKeep: true,
            PrefKey.showInspector: true,
            PrefKey.showKnown: false,
            PrefKey.autoplay: true,
            PrefKey.soundOn: false,
            PrefKey.loopClips: true,
            PrefKey.advanceAfterVerdict: true,
            PrefKey.useProxies: true,
            PrefKey.lutMode: LUTMode.auto.rawValue,
            PrefKey.finderTags: false,
            PrefKey.suggestionsEnabled: true,
            PrefKey.shortClipSeconds: 1.0,
            PrefKey.blurRatio: 0.35,
            PrefKey.photosInSavings: false,
            PrefKey.resolveEnabled: true,
            PrefKey.resolveAutoScan: true,
            PrefKey.sendToResolve: false,
            PrefKey.binTemplate: "{datum}",
            PrefKey.binParent: "",
            PrefKey.binPerDay: true,
            PrefKey.makeTimeline: false,
            PrefKey.timelineTemplate: "{datum} Selects",
            PrefKey.autoCheckUpdates: true,
        ])
    }

    static func bool(_ key: String) -> Bool { defaults.bool(forKey: key) }
    static func string(_ key: String) -> String { defaults.string(forKey: key) ?? "" }
    static func double(_ key: String) -> Double { defaults.double(forKey: key) }

    static var cardBehavior: CardBehavior { CardBehavior(rawValue: string(PrefKey.cardBehavior)) ?? .review }
    static var lutMode: LUTMode { LUTMode(rawValue: string(PrefKey.lutMode)) ?? .auto }

    static var extraFolders: [String] {
        get { defaults.stringArray(forKey: PrefKey.extraFolders) ?? [] }
        set { defaults.set(newValue, forKey: PrefKey.extraFolders) }
    }

    static var resolveRoots: [String] {
        get { defaults.stringArray(forKey: PrefKey.resolveRoots) ?? [] }
        set { defaults.set(newValue, forKey: PrefKey.resolveRoots) }
    }

    /// "old prefix=new prefix", one per line.
    static var resolveMappings: [(from: String, to: String)] {
        string(PrefKey.resolveMappings).split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 ? (parts[0], parts[1]) : nil
        }
    }

    static var suggestions: SuggestionSettings {
        var settings = SuggestionSettings()
        settings.enabled = bool(PrefKey.suggestionsEnabled)
        settings.shortClipSeconds = double(PrefKey.shortClipSeconds)
        settings.blurRatio = double(PrefKey.blurRatio)
        return settings
    }
}
