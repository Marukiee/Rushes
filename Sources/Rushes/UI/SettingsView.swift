import AppKit
import RushesKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DiskSettings().tabItem { Label("Disks", systemImage: "externaldrive") }
            ReviewSettings().tabItem { Label("Reviewing", systemImage: "eye") }
            LibrarySettings().tabItem { Label("Library", systemImage: "square.grid.2x2") }
            ResolveSettings().tabItem { Label("DaVinci", systemImage: "film.stack") }
            AboutSettings().tabItem { Label("Updates", systemImage: "arrow.down.circle") }
        }
        .frame(width: 600, height: 520)
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

    var body: some View {
        Form {
            Section {
                Picker("When a card and your disk are in", selection: $behavior) {
                    Text("Let me look through it first").tag(CardBehavior.review.rawValue)
                    Text("Copy everything new at once").tag(CardBehavior.copyAll.rawValue)
                    Text("Only ask me").tag(CardBehavior.ask.rawValue)
                }
                .pickerStyle(.radioGroup)
                Text(explanation).font(.caption).foregroundStyle(.secondary)
                Toggle("Show a small card in the corner when a card is recognised", isOn: $recognition)
                Toggle("Open the window when there is something to look through", isOn: $openWindow)
            }
            Section("After a copy") {
                Toggle("Give a notification when it is done", isOn: $notify)
                Toggle("Ask for a name for the folder (SD 5 becomes SD 5 Sweden)", isOn: $askName)
                Toggle("Eject the card when every file checks out", isOn: $eject)
            }
            Section("The app") {
                Toggle("Start Rushes when I log in", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                Text(loginError ?? String(localized: "Rushes sits in the menu bar and wakes up when a card is put in. That only works while it is running."))
                    .font(.caption).foregroundStyle(loginError == nil ? Color.secondary : VerdictStyle.hint)
                Toggle("Show in the Dock", isOn: $showInDock)
                    .onChange(of: showInDock) { _, value in NSApp.setActivationPolicy(value ? .regular : .accessory) }
            }
        }
        .formStyle(.grouped)
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
            Section("Where the cards go") {
                Picker("Disk", selection: Binding(get: { uuid }, set: choose)) {
                    if uuid.isEmpty || !app.destinationCandidates.contains(where: { $0.uuid == uuid }) {
                        Text(diskName.isEmpty ? String(localized: "Not chosen") : String(localized: "\(diskName) (not connected)")).tag(uuid)
                    }
                    ForEach(app.destinationCandidates) { disk in
                        Text("\(disk.name)  ·  \(Format.bytes(disk.available)) free").tag(disk.uuid)
                    }
                }
                TextField("Folder on the disk (empty is the top)", text: $subfolder)
                Text("Each card gets its own folder there: SD 1, SD 2 and on. The same card goes back into its own folder.").font(.caption).foregroundStyle(.secondary)
            }
            Section("What gets copied") {
                Toggle("Clips and photos I have not judged are copied too", isOn: $undecidedKeep)
                Text("Off: only what you marked Keep is copied.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Second copy") {
                Toggle("Also copy everything to a second disk", isOn: $backup)
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
                    Text("Both copies are checked against the card. If the second disk is not connected, the copy goes to the first one only and says so.")
                        .font(.caption).foregroundStyle(.secondary)
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
    @AppStorage(PrefKey.blurRatio) private var blurRatio = 0.35
    @AppStorage(PrefKey.finderTags) private var tags = false

    var body: some View {
        Form {
            Section("Playing") {
                Toggle("Start playing when a clip is chosen", isOn: $autoplay)
                Toggle("Sound on", isOn: $sound)
                Toggle("Play a clip again when it ends", isOn: $loop)
                Toggle("Go to the next one after Keep or Leave out", isOn: $advance)
                Toggle("Use the camera's small proxy files when there are any", isOn: $proxies)
                Text("A proxy plays smoothly even from a slow card. The original is what gets copied.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Colour") {
                Picker("Show log footage with", selection: $lut) {
                    Text("The camera's own LUT, or a standard one").tag(LUTMode.auto.rawValue)
                    Text("A standard S-Log3 look").tag(LUTMode.builtIn.rawValue)
                    Text("Nothing, as it was shot").tag(LUTMode.off.rawValue)
                }
                Text("Only for the preview. The files are never changed.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Suggestions") {
                Toggle("Suggest what can be left out", isOn: $suggestions)
                if suggestions {
                    HStack {
                        Text("Clips shorter than")
                        Slider(value: $shortClip, in: 0.5 ... 5, step: 0.5)
                        Text("\(shortClip, specifier: "%.1f") s").monospacedDigit().frame(width: 50, alignment: .trailing)
                    }
                    HStack {
                        Text("Photos less sharp than")
                        Slider(value: $blurRatio, in: 0.1 ... 0.8, step: 0.05)
                        Text("\(Int(blurRatio * 100))% of the median").monospacedDigit().frame(width: 120, alignment: .trailing)
                    }
                    Text("Black or covered clips and near copies in a burst are always looked for. Nothing is left out without you pressing the button.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Finder") {
                Toggle("Mark copied files with a Finder tag", isOn: $tags)
                Text("On an exFAT disk every tag adds a small hidden file next to the original.").font(.caption).foregroundStyle(.secondary)
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
            Section("More folders to look through") {
                ForEach(folders, id: \.self) { path in
                    HStack {
                        Image(systemName: "folder")
                        Text(path).lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button { folders.removeAll { $0 == path }; save() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain)
                    }
                }
                Button("Add a folder...") { addFolder() }
                Text("Folders named SD 1, SD 2 and so on on your disk are always included. Add other places that hold footage, like a project's footage folder.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Space you can free up") {
                Toggle("Count photos that no project uses too", isOn: $photos)
                    .onChange(of: photos) { _, _ in app.library.recount(index: app.resolve.index) }
                Text("DaVinci Resolve is rarely where photos are used, so they are left out of the total unless you ask.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Cache") {
                HStack {
                    Text("Thumbnails: \(Format.bytes(cacheSize))")
                    Spacer()
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
                Toggle("Look at my DaVinci Resolve projects", isOn: $enabled)
                Toggle("Read them again when a project is saved", isOn: $autoScan)
                Text("The projects of the local database are read from their files. Resolve does not have to be open.").font(.caption).foregroundStyle(.secondary)
            }
            Section("New footage") {
                Toggle("Put new footage in a bin after every import", isOn: $send)
                TextField("Bin name", text: $template)
                Text("Like {datum} or {datum} {sd}. {datum} is the day of shooting.").font(.caption).foregroundStyle(.secondary)
                TextField("Inside this bin (empty is the top of the media pool)", text: $parent)
                Toggle("A bin for each day of shooting", isOn: $perDay)
                Toggle("Make a timeline of the video clips as well", isOn: $timeline)
                if timeline { TextField("Timeline name", text: $timelineTemplate) }
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

private struct AboutSettings: View {
    @LocalState private var updater = Updater.shared
    @AppStorage(PrefKey.autoCheckUpdates) private var auto = true

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "sdcard.fill").font(.system(size: 22, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 52, height: 52).background(Palette.indigo.gradient, in: .circle)
                    VStack(alignment: .leading) {
                        Text(AppIdentity.displayName).font(.title2.weight(.bold))
                        Text("Version \(updater.currentVersion)").foregroundStyle(.secondary)
                    }
                }
            }
            Section("Updates") {
                Toggle("Check for updates by itself", isOn: $auto)
                HStack {
                    Text(status).foregroundStyle(.secondary)
                    Spacer()
                    Button("Check now") { Task { await updater.check(manual: true) } }
                    if case .available = updater.state { Button("Update and restart") { Task { await updater.install() } }.buttonStyle(.borderedProminent) }
                }
                Text("Updates come from github.com/Marukiee/Rushes. Each one is checked against a signature before it is installed.").font(.caption).foregroundStyle(.secondary)
            }
            Section("What's new") { WhatsNew() }
        }
        .formStyle(.grouped)
    }

    private var status: String {
        switch updater.state {
        case .checking: String(localized: "Looking...")
        case .upToDate: String(localized: "You have the newest version")
        case let .available(release): String(localized: "Version \(release.version) is available")
        case let .downloading(_, progress): String(localized: "Downloading \(Int(progress * 100))%")
        case .installing: String(localized: "Installing...")
        case let .failed(message): message
        case .idle: updater.lastChecked.map { String(localized: "Checked \($0.formatted(.relative(presentation: .named)))") } ?? ""
        }
    }
}

private struct WhatsNew: View {
    var body: some View {
        let entries = Changelog.load()
        if entries.isEmpty {
            Text("Nothing listed yet.").foregroundStyle(.secondary)
        } else {
            ForEach(entries.prefix(3)) { entry in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(entry.version)  ·  \(entry.title)").font(.callout.weight(.semibold))
                    ForEach(entry.new + entry.better, id: \.self) { Text("• \($0)").font(.caption).foregroundStyle(.secondary) }
                }
            }
        }
    }
}
