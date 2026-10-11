import AppKit
import RushesKit
import ServiceManagement
import SwiftUI

/// The sections of the Settings window, in the order System Settings would list them.
enum SettingsSection: String, CaseIterable, Identifiable {
    case general, disks, reviewing, library, davinci, updates, about

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .general: "General"
        case .disks: "Disks"
        case .reviewing: "Reviewing"
        case .library: "Library"
        case .davinci: "DaVinci"
        case .updates: "Updates"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .disks: "externaldrive"
        case .reviewing: "eye"
        case .library: "square.grid.2x2"
        case .davinci: "film.stack"
        case .updates: "arrow.down.circle"
        case .about: "info.circle"
        }
    }
}

/// The Settings window like System Settings, and like Tandem: a sidebar with the sections and the section next to it.
struct SettingsView: View {
    @LocalState private var selection: SettingsSection = DebugSupport.initialSettingsSection() ?? .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.title, systemImage: section.symbol)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 190, max: 220)
            // The sections always fit, so there is nothing to fold away.
            .toolbar(removing: .sidebarToggle)
        } detail: {
            detail(for: selection)
                .navigationTitle(Text(selection.title))
        }
        .frame(width: 780, height: 620)
    }

    @ViewBuilder
    private func detail(for section: SettingsSection) -> some View {
        switch section {
        case .general: GeneralSettings()
        case .disks: DiskSettings()
        case .reviewing: ReviewSettings()
        case .library: LibrarySettings()
        case .davinci: ResolveSettings()
        case .updates: UpdateSettings()
        case .about: AboutSettings()
        }
    }
}

/// A toggle with a line of explanation under it, as grouped forms show them.
struct DescribedToggle: View {
    let title: LocalizedStringKey
    let subtitle: LocalizedStringKey?
    @Binding var isOn: Bool

    init(_ title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.subtitle = subtitle
        _isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let subtitle {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// The language of the app: the system's, or one of the two it is written in. It takes a restart.
enum LanguageSetting {
    static var current: String {
        (UserDefaults.standard.array(forKey: "AppleLanguages") as? [String])?.first.flatMap { code in
            ["en", "nl"].first { code.hasPrefix($0) }
        } ?? "system"
    }

    static func apply(_ choice: String) {
        if choice == "system" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([choice], forKey: "AppleLanguages")
        }
    }

    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }
}

// MARK: General

private struct GeneralSettings: View {
    @AppStorage(PrefKey.cardBehavior) private var behavior = CardBehavior.review.rawValue
    @AppStorage(PrefKey.showRecognitionCard) private var recognition = true
    @AppStorage(PrefKey.openWindowOnCard) private var openWindow = true
    @AppStorage(PrefKey.notifyWhenDone) private var notify = true
    @AppStorage(PrefKey.ejectAfterImport) private var eject = false
    @AppStorage(PrefKey.askForName) private var askName = true
    @AppStorage(PrefKey.showInDock) private var showInDock = true
    @LocalState private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @LocalState private var loginError: String?
    @LocalState private var language = LanguageSetting.current
    @LocalState private var needsRestart = false

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: $language) {
                    Text("Same as the system").tag("system")
                    Text("English").tag("en")
                    Text("Nederlands").tag("nl")
                }
                .onChange(of: language) { _, value in
                    LanguageSetting.apply(value)
                    needsRestart = true
                }
                if needsRestart {
                    LabeledContent {
                        Button("Restart now") { LanguageSetting.relaunch() }
                            .buttonStyle(.glassProminent)
                            .tint(Palette.indigo)
                            .controlSize(.small)
                    } label: {
                        Text("Restart Rushes to change the language.").foregroundStyle(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            Section {
                Picker("When a card and your disk are in", selection: $behavior) {
                    Text("Let me look through it first").tag(CardBehavior.review.rawValue)
                    Text("Copy everything new at once").tag(CardBehavior.copyAll.rawValue)
                    Text("Only ask me").tag(CardBehavior.ask.rawValue)
                }
                .pickerStyle(.radioGroup)
                DescribedToggle("Show a small card in the corner when a card is recognised", isOn: $recognition)
                DescribedToggle("Open the window when there is something to look through", isOn: $openWindow)
            } header: {
                Text("A card is put in")
            } footer: {
                Text(explanation)
            }
            Section("After a copy") {
                DescribedToggle("Give a notification when it is done", isOn: $notify)
                DescribedToggle("Ask for a name for the folder", subtitle: "SD 5 becomes SD 5 Sweden. The number stays, so the card is always found again.", isOn: $askName)
                DescribedToggle("Eject the card when every file checks out", isOn: $eject)
            }
            Section("Behaviour") {
                DescribedToggle(
                    "Start Rushes when I log in",
                    subtitle: loginError.map { LocalizedStringKey($0) } ?? "Rushes sits in the menu bar and wakes up when a card is put in. That only works while it is running.",
                    isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin)
                )
                Toggle("Show in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, value in NSApp.setActivationPolicy(value ? .regular : .accessory) }
            }
        }
        .formStyle(.grouped)
        .animation(.rushes, value: needsRestart)
    }

    private var explanation: LocalizedStringKey {
        switch CardBehavior(rawValue: behavior) ?? .review {
        case .review: "Rushes opens the review. Only the clips you keep are copied, so the disk never fills with what you would delete anyway."
        case .copyAll: "Everything new goes to the disk straight away. You can look through it afterwards and move what you do not need to the Trash."
        case .ask: "Rushes shows the card and waits for you to choose."
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = error.localizedDescription
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: Disks

private struct DiskSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(PrefKey.destinationUUID) private var uuid = ""
    @AppStorage(PrefKey.destinationName) private var diskName = ""
    @AppStorage(PrefKey.destinationSubfolder) private var subfolder = ""
    @AppStorage(PrefKey.undecidedMeansKeep) private var undecidedKeep = true
    @AppStorage(PrefKey.backupEnabled) private var backup = false
    @AppStorage(PrefKey.backupUUID) private var backupUUID = ""
    @AppStorage(PrefKey.backupName) private var backupName = ""
    @AppStorage(PrefKey.backupSubfolder) private var backupSubfolder = ""

    var body: some View {
        Form {
            Section {
                Picker("Disk", selection: Binding(get: { uuid }, set: choose)) {
                    if uuid.isEmpty || !app.destinationCandidates.contains(where: { $0.uuid == uuid }) {
                        Text(diskName.isEmpty ? String(localized: "Not chosen") : String(localized: "\(diskName) (not connected)")).tag(uuid)
                    }
                    ForEach(app.destinationCandidates) { disk in
                        Text("\(disk.name)  ·  \(Format.bytes(disk.available)) free").tag(disk.uuid)
                    }
                }
                TextField("Folder on the disk (empty is the top)", text: $subfolder)
            } header: {
                Text("Where the cards go")
            } footer: {
                Text("Each card gets its own folder there: SD 1, SD 2 and on. The same card goes back into its own folder.")
            }
            Section("What gets copied") {
                DescribedToggle("Clips and photos I have not judged are copied too", subtitle: "Off: only what you marked Keep is copied.", isOn: $undecidedKeep)
            }
            Section {
                DescribedToggle("Also copy everything to a second disk", isOn: $backup)
                if backup {
                    Picker("Disk", selection: Binding(get: { backupUUID }, set: chooseBackup)) {
                        if backupUUID.isEmpty || !app.destinationCandidates.contains(where: { $0.uuid == backupUUID }) {
                            Text(backupName.isEmpty ? String(localized: "Not chosen") : String(localized: "\(backupName) (not connected)")).tag(backupUUID)
                        }
                        ForEach(app.destinationCandidates.filter { $0.uuid != uuid }) { disk in
                            Text("\(disk.name)  ·  \(Format.bytes(disk.available)) free").tag(disk.uuid)
                        }
                    }
                    TextField("Folder on that disk", text: $backupSubfolder)
                }
            } header: {
                Text("Second copy")
            } footer: {
                if backup {
                    Text("Both copies are checked against the card. If the second disk is not connected, the copy goes to the first one only and says so.")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: backup) { _, _ in app.refreshVolumes() }
    }

    private func choose(_ new: String) {
        if let disk = app.destinationCandidates.first(where: { $0.uuid == new }) { app.chooseDestination(disk) }
    }

    private func chooseBackup(_ new: String) {
        if let disk = app.destinationCandidates.first(where: { $0.uuid == new }) {
            backupUUID = disk.uuid
            backupName = disk.name
            app.refreshVolumes()
        }
    }
}

// MARK: Reviewing

private struct ReviewSettings: View {
    @AppStorage(PrefKey.autoplay) private var autoplay = true
    @AppStorage(PrefKey.soundOn) private var sound = false
    @AppStorage(PrefKey.loopClips) private var loop = true
    @AppStorage(PrefKey.advanceAfterVerdict) private var advance = true
    @AppStorage(PrefKey.useProxies) private var proxies = true
    @AppStorage(PrefKey.lutMode) private var lut = LUTMode.auto.rawValue
    @AppStorage(PrefKey.suggestionsEnabled) private var suggestions = true
    @AppStorage(PrefKey.shortClipSeconds) private var shortClip = 1.0
    @AppStorage(PrefKey.blurRatio) private var blurRatio = 0.2
    @AppStorage(PrefKey.finderTags) private var tags = false

    var body: some View {
        Form {
            Section("Playing") {
                DescribedToggle("Start playing when a clip is chosen", isOn: $autoplay)
                DescribedToggle("Sound on", isOn: $sound)
                DescribedToggle("Play a clip again when it ends", isOn: $loop)
                DescribedToggle("Go to the next one after Keep or Leave out", isOn: $advance)
                DescribedToggle(
                    "Use the camera's small proxy files when there are any",
                    subtitle: "A proxy plays smoothly even from a slow card. The original is what gets copied.",
                    isOn: $proxies
                )
            }
            Section {
                Picker("Show log footage with", selection: $lut) {
                    Text("The camera's own LUT, or a standard one").tag(LUTMode.auto.rawValue)
                    Text("A standard S-Log3 look").tag(LUTMode.builtIn.rawValue)
                    Text("Nothing, as it was shot").tag(LUTMode.off.rawValue)
                }
            } header: {
                Text("Colour")
            } footer: {
                Text("Only for the preview. The files are never changed.")
            }
            Section {
                DescribedToggle("Suggest what can be left out", isOn: $suggestions)
                if suggestions {
                    HStack {
                        Text("Clips shorter than")
                        Slider(value: $shortClip, in: 0.5 ... 5, step: 0.5)
                        Text("\(shortClip, specifier: "%.1f") s").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                    HStack {
                        Text("Photos less sharp than")
                        Slider(value: $blurRatio, in: 0.05 ... 0.6, step: 0.05)
                        Text("\(Int(blurRatio * 100))% of the shots around it").monospacedDigit().frame(width: 190, alignment: .trailing)
                    }
                }
            } header: {
                Text("Suggestions")
            } footer: {
                if suggestions {
                    Text("Black or covered clips and near copies in a burst are always looked for. Nothing is left out without you pressing the button.")
                }
            }
            Section("Finder") {
                DescribedToggle(
                    "Mark copied files with a Finder tag",
                    subtitle: "On an exFAT disk every tag adds a small hidden file next to the original.",
                    isOn: $tags
                )
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Library

private struct LibrarySettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(PrefKey.photosInSavings) private var photos = false
    @LocalState private var folders = Prefs.extraFolders
    @LocalState private var cacheSize: UInt64 = 0

    var body: some View {
        Form {
            Section {
                ForEach(folders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { folders.removeAll { $0 == path }; save() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                Button("Add a folder...") { addFolder() }
            } header: {
                Text("More folders to look through")
            } footer: {
                Text("Folders named SD 1, SD 2 and so on on your disk are always included. Add other places that hold footage, like a project's footage folder.")
            }
            Section("Space you can free up") {
                DescribedToggle(
                    "Count photos that no project uses too",
                    subtitle: "DaVinci Resolve is rarely where photos are used, so they are left out of the total unless you ask.",
                    isOn: $photos
                )
                .onChange(of: photos) { _, _ in app.library.recount(index: app.resolve.index) }
            }
            Section("Cache") {
                LabeledContent("Thumbnails: \(Format.bytes(cacheSize))") {
                    Button("Clear") { Task { await Thumbnailer.shared.clearCache(); cacheSize = await Thumbnailer.shared.cacheSize() } }
                }
            }
        }
        .formStyle(.grouped)
        .task { cacheSize = await Thumbnailer.shared.cacheSize() }
    }

    private func save() {
        Prefs.extraFolders = folders
        app.reloadLibrary()
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            for url in panel.urls where !folders.contains(url.path) { folders.append(url.path) }
            save()
        }
    }
}

// MARK: DaVinci

private struct ResolveSettings: View {
    @Environment(AppModel.self) private var app
    @AppStorage(PrefKey.resolveEnabled) private var enabled = true
    @AppStorage(PrefKey.resolveAutoScan) private var autoScan = true
    @AppStorage(PrefKey.resolveMappings) private var mappings = ""
    @AppStorage(PrefKey.pythonPath) private var python = ""
    @AppStorage(PrefKey.sendToResolve) private var send = false
    @AppStorage(PrefKey.binTemplate) private var template = "{datum}"
    @AppStorage(PrefKey.binParent) private var parent = ""
    @AppStorage(PrefKey.binPerDay) private var perDay = true
    @AppStorage(PrefKey.makeTimeline) private var timeline = false
    @AppStorage(PrefKey.timelineTemplate) private var timelineTemplate = "{datum} Selects"
    @LocalState private var roots = Prefs.resolveRoots

    var body: some View {
        Form {
            Section("Projects") {
                DescribedToggle(
                    "Look at my DaVinci Resolve projects",
                    subtitle: "The projects of the local database are read from their files. Resolve does not have to be open.",
                    isOn: $enabled
                )
                DescribedToggle("Read them again when a project is saved", isOn: $autoScan)
            }
            Section {
                DescribedToggle("Put new footage in a bin after every import", isOn: $send)
                TextField("Bin name", text: $template)
                TextField("Inside this bin (empty is the top of the media pool)", text: $parent)
                DescribedToggle("A bin for each day of shooting", isOn: $perDay)
                DescribedToggle("Make a timeline of the video clips as well", isOn: $timeline)
                if timeline { TextField("Timeline name", text: $timelineTemplate) }
            } header: {
                Text("New footage")
            } footer: {
                Text("A bin name is like {datum} or {datum} {sd}. {datum} is the day of shooting.")
            }
            Section("Advanced") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Replace the start of a path (old=new, one per line)")
                    TextEditor(text: $mappings)
                        .font(.system(.caption, design: .monospaced))
                        .frame(height: 52)
                        .scrollContentBackground(.hidden)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    Text("Projects made on Linux point at /run/media/..., which Rushes already understands. Use this for anything else.").font(.caption).foregroundStyle(.secondary)
                }
                ForEach(roots, id: \.self) { path in
                    HStack { Text(path).lineLimit(1).truncationMode(.middle); Spacer(); Button { roots.removeAll { $0 == path }; Prefs.resolveRoots = roots } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain) }
                }
                Button("Add a project database folder...") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = true
                    panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { roots.append(url.path); Prefs.resolveRoots = roots }
                }
                TextField("Python 3 (empty finds it by itself)", text: $python)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Updates

private struct UpdateSettings: View {
    @LocalState private var updater = Updater.shared
    @AppStorage(PrefKey.autoCheckUpdates) private var auto = true
    private let entries = Changelog.load()

    var body: some View {
        Form {
            Section {
                LabeledContent("Installed version", value: updater.currentVersion)
                Toggle("Check for updates by itself", isOn: $auto)
            } footer: {
                Text("Updates come from github.com/Marukiee/Rushes. Each one is checked against a signature before it is installed.")
            }
            Section {
                switch updater.state {
                case .idle, .upToDate:
                    LabeledContent {
                        Button("Check now") { Task { await updater.check(manual: true) } }
                    } label: {
                        Text(status).foregroundStyle(.secondary)
                    }
                case .checking:
                    HStack(spacing: 10) { PillSpinner(size: 18); Text("Looking...") }
                case let .available(release):
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Version \(release.version) is available").font(.headline)
                        if !release.notes.isEmpty {
                            ScrollView { Text(release.notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading) }
                                .frame(maxHeight: 90)
                        }
                        Button("Update and restart") { Task { await updater.install() } }
                            .buttonStyle(.glassProminent)
                            .tint(Palette.indigo)
                    }
                case let .downloading(_, progress):
                    VStack(alignment: .leading, spacing: 8) {
                        Text(status)
                        ProgressCapsule(fraction: progress).frame(height: 6)
                    }
                case .installing:
                    HStack(spacing: 10) { PillSpinner(size: 18); Text("Installing...") }
                case let .failed(reason):
                    LabeledContent {
                        Button("Try again") { Task { await updater.check(manual: true) } }
                    } label: {
                        Text(reason).foregroundStyle(Palette.urgent)
                    }
                }
            }
            // What is new in each version sits with the update, not under About.
            if !entries.isEmpty {
                Section("What's new") {
                    ForEach(entries.prefix(5)) { ChangeCard(entry: $0, installed: $0.version == updater.currentVersion) }
                }
            }
        }
        .formStyle(.grouped)
        .animation(.rushes, value: updater.state)
    }

    private var status: String {
        switch updater.state {
        case .upToDate: String(localized: "You have the newest version")
        case let .downloading(_, progress): String(localized: "Downloading \(Int(progress * 100))%")
        case .idle: updater.lastChecked.map { String(localized: "Checked \($0.formatted(.relative(presentation: .named)))") } ?? ""
        default: ""
        }
    }
}

private struct ChangeCard: View {
    let entry: ChangeEntry
    let installed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(entry.version).font(.callout.weight(.semibold)).foregroundStyle(Palette.accent)
                Text(entry.date).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if installed {
                    Text("Installed")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Palette.indigo.opacity(0.14), in: .capsule)
                }
            }
            Text(entry.title).font(.callout.weight(.semibold))
            ForEach(entry.new + entry.better + entry.fixed, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Palette.rose).frame(width: 5, height: 5).offset(y: -1)
                    Text(line).font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: About

private struct AboutSettings: View {
    @LocalState private var updater = Updater.shared

    var body: some View {
        ScrollView {
            VStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 104, height: 104)
                    .padding(.top, 8)
                    .padding(.bottom, 14)
                Text(AppIdentity.displayName)
                    .font(.largeTitle.weight(.bold))
                Text("Version \(updater.currentVersion)")
                    .foregroundStyle(.secondary)
                Text("Cards, disks and DaVinci projects in one place. Open source under AGPL-3.0.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
                    .padding(.top, 10)
                Link("github.com/Marukiee/Rushes", destination: URL(string: "https://github.com/Marukiee/Rushes")!)
                    .padding(.top, 10)
            }
            .frame(maxWidth: .infinity)
            .multilineTextAlignment(.center)
            .padding(24)
        }
    }
}
