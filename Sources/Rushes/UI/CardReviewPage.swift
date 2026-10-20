import RushesKit
import SwiftUI

/// The page for the card that is in: look through it, then copy what is wanted.
struct CardReviewPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        Group {
            if let session = app.currentReviewSession {
                content(for: session)
            } else {
                EmptyState(
                    symbol: "sdcard",
                    title: "No card in",
                    text: "Put a memory card in your Mac. Rushes sees it, shows what is new on it, and lets you choose what is worth copying."
                )
            }
        }
        .animation(.rushes, value: app.currentReviewSession?.id)
    }

    @ViewBuilder
    private func content(for session: CardSession) -> some View {
        Group {
            if session.phase == .scanning {
                VStack(spacing: Space.l) {
                    PillSpinner(size: 34)
                    Text("Reading \(session.name)...").font(.title3.weight(.semibold))
                    Text("Looking at what is on the card. Nothing is copied yet.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review = session.review {
                if review.actionableCount == 0 {
                    NothingNewView(session: session)
                } else {
                    ReviewBody(model: review) { SuggestionBanner(model: review) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            // While it copies, the bar along the bottom of the window shows how far it is instead.
            if let review = session.review, session.phase == .ready, review.actionableCount > 0, app.job?.isRunning != true, !app.viewing {
                ImportBar(session: session, review: review)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.rushes, value: app.job?.isRunning)
        .navigationTitle(session.name)
        .navigationSubtitle([headline(for: session), session.review?.progressText ?? ""].filter { !$0.isEmpty }.joined(separator: "  ·  "))
        .toolbar {
            if let review = session.review, session.phase == .ready, review.actionableCount > 0 {
                ReviewToolbar(model: review)
            }
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItem(placement: .primaryAction) {
                Button { app.eject(session) } label: { Label("Eject", systemImage: "eject").labelStyle(.titleAndIcon).padding(.horizontal, Space.xs) }
                    .disabled(app.job?.isRunning == true)
                    .help("Eject the card")
            }
            // A little room after the last button, so it does not press against the rounded corner of the window.
            ToolbarSpacer(.fixed, placement: .primaryAction)
        }
    }

    private func headline(for session: CardSession) -> String {
        guard session.phase == .ready else { return String(localized: "Reading...") }
        var parts = ["\(session.newItems) " + String(localized: "new") + " (\(Format.bytes(session.newBytes)))"]
        if session.knownItems > 0 { parts.append(String(localized: "\(session.knownItems) already on your disk")) }
        if session.skippedBefore > 0 { parts.append(String(localized: "\(session.skippedBefore) left out before")) }
        return parts.joined(separator: "  ·  ")
    }
}

private struct NothingNewView: View {
    @Environment(AppModel.self) private var app
    let session: CardSession

    var body: some View {
        VStack(spacing: 18) {
            EmptyState(
                symbol: "checkmark.seal.fill",
                title: "Everything on this card is already on your disk",
                text: session.skippedBefore > 0
                    ? "What you left out stays on the card and is not offered again. The card can be taken out."
                    : "There is nothing new to copy. The card can be taken out.",
                tint: VerdictStyle.keep
            )
            HStack(spacing: 12) {
                ActionButton(title: "Eject the card", symbol: "eject.fill", prominent: true) { app.eject(session) }
                ActionButton(title: "Look through all of it", symbol: "eye") {
                    session.review?.showKnown = true
                    session.review?.refresh()
                }
            }
            .padding(.bottom, 40)
        }
    }
}

/// What will be copied, and the button that copies it. It floats over the clips as one glass bar; what is in it is plain.
private struct ImportBar: View {
    @Environment(AppModel.self) private var app
    let session: CardSession
    var review: ReviewModel
    @AppStorage(PrefKey.undecidedMeansKeep) private var undecidedMeansKeep = false
    @AppStorage(PrefKey.copyKinds) private var kindsRaw = CopyKinds.all.rawValue
    @AppStorage(PrefKey.chosenAction) private var actionRaw = ChosenAction.copy.rawValue
    @LocalState private var marking = false
    /// How far marking on the card has got, for the bar that shows it while it works.
    @LocalState private var progress: (done: Int, total: Int)?
    @LocalState private var conflicts = 0
    @LocalState private var askOverwrite = false
    @LocalState private var pending: ChosenAction = .stars
    @LocalState private var outcome: String?

    var body: some View {
        let kinds = CopyKinds(rawValue: kindsRaw) ?? .all
        let action = ChosenAction(rawValue: actionRaw) ?? .copy
        let counts = review.counts()
        let copy = review.toCopy(kinds: kinds, undecidedMeansKeep: undecidedMeansKeep)
        let chosen = review.chosenItems(kinds: kinds, undecidedMeansKeep: undecidedMeansKeep)

        // The whole bar when it fits, then without the line about the disk, then with the kinds as symbols only.
        ViewThatFits(in: .horizontal) {
            bar(kinds: kinds, action: action, counts: counts, copy: copy, chosen: chosen, detail: true, kindWords: true)
            bar(kinds: kinds, action: action, counts: counts, copy: copy, chosen: chosen, detail: false, kindWords: true)
            bar(kinds: kinds, action: action, counts: counts, copy: copy, chosen: chosen, detail: false, kindWords: false)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .rushesGlass(Capsule())
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.l)
        .confirmationDialog(
            pending == .stars ? Text("\(conflicts) already have stars") : Text("\(conflicts) already have another label"),
            isPresented: $askOverwrite, titleVisibility: .visible
        ) {
            Button(pending == .stars ? "Give them five stars" : "Flag them anyway") { run(pending, overwrite: true) }
            Button(pending == .stars ? "Leave their stars as they are" : "Leave their labels as they are") { run(pending, overwrite: false) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Some of what you chose was marked before, on the camera or in another app.")
        }
        .alert(outcome ?? "", isPresented: Binding(get: { outcome != nil }, set: { if !$0 { outcome = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    private func bar(
        kinds: CopyKinds, action: ChosenAction, counts: (keep: Int, skip: Int, undecided: Int, suggested: Int),
        copy: (count: Int, bytes: UInt64), chosen: [MediaItem], detail: Bool, kindWords: Bool
    ) -> some View {
        HStack(spacing: Space.l) {
            // The counts are filters too: a click shows only what you kept (or left out, or did not judge yet), again shows all.
            HStack(spacing: Space.xs) {
                Stat(symbol: "checkmark", tint: VerdictStyle.keep, value: "\(counts.keep)", detail: Format.bytes(review.bytes(for: .keep)),
                     active: review.stateFilter == .keep, help: "Show only what you kept") { show(.keep) }
                Stat(symbol: "xmark", tint: VerdictStyle.skip, value: "\(counts.skip)", detail: Format.bytes(review.bytes(for: .skip)),
                     active: review.stateFilter == .skip, help: "Show only what you left out") { show(.skip) }
                Stat(symbol: "circle.dashed", tint: .secondary, value: "\(counts.undecided)", detail: Format.bytes(review.bytes(for: .undecided)),
                     active: review.stateFilter == .undecided, help: "Show only what you did not judge yet") { show(.undecided) }
            }
            .fixedSize()
            Spacer(minLength: Space.m)
            // What goes along, always in sight: videos, photos or both.
            Picker("What goes along", selection: $kindsRaw) {
                ForEach([CopyKinds.all, .video, .photo], id: \.rawValue) { kind in
                    if kindWords {
                        Label(kindTitle(kind), systemImage: kindSymbol(kind)).tag(kind.rawValue)
                    } else {
                        Image(systemName: kindSymbol(kind)).help(kindTitle(kind)).tag(kind.rawValue)
                    }
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .help("What goes along: videos, photos or both")
            actionMenu(action: action, kinds: kinds, withDisk: detail)
            primary(action: action, copy: copy, chosen: chosen)
        }
    }

    private func show(_ filter: ReviewStateFilter) {
        withAnimation(.rushes) {
            review.stateFilter = review.stateFilter == filter ? .all : filter
            review.refresh()
        }
    }

    private func actionMenu(action: ChosenAction, kinds: CopyKinds, withDisk: Bool) -> some View {
        let selected = review.selection.count > 1 ? review.selection : nil
        let everything = review.toCopy(kinds: kinds, undecidedMeansKeep: true, everything: true)
        return Menu {
            Picker("What happens with what you chose", selection: $actionRaw) {
                Label("Copy to the disk", systemImage: "square.and.arrow.down").tag(ChosenAction.copy.rawValue)
                Label("Give five stars on the card", systemImage: "star.fill").tag(ChosenAction.stars.rawValue)
                Label("Flag on the card", systemImage: "flag.fill").tag(ChosenAction.flag.rawValue)
            }
            .pickerStyle(.inline)
            if action == .copy {
                Divider()
                // Where it goes: one of the disks, or a folder on this Mac.
                Picker("Where to", selection: Binding(get: { app.destination?.uuid ?? "" }, set: { uuid in
                    if let disk = app.destinationCandidates.first(where: { $0.uuid == uuid }) { app.chooseDestination(disk) }
                })) {
                    ForEach(app.destinationCandidates) { disk in
                        Label(disk.name, systemImage: disk.uuid == AppModel.macFolderID ? "laptopcomputer" : "externaldrive").tag(disk.uuid)
                    }
                }
                .pickerStyle(.inline)
                Button("A folder on this Mac...", systemImage: "folder.badge.plus") { app.chooseMacFolder() }
            }
            Divider()
            Toggle("Also what I have not judged", isOn: $undecidedMeansKeep)
            if action == .copy {
                Divider()
                if let selected {
                    let picked = review.toCopy(kinds: .all, undecidedMeansKeep: true, everything: true, only: selected)
                    Button("Copy the \(selected.count) selected (\(Format.bytes(picked.bytes)))", systemImage: "checklist") {
                        app.startImport(session, request: ImportRequest(everything: true, only: selected, kinds: .all, scope: String(localized: "the selection")))
                    }
                    .disabled(picked.count == 0)
                }
                Button("Copy everything new, whatever I chose (\(everything.count), \(Format.bytes(everything.bytes)))", systemImage: "square.and.arrow.down.on.square") {
                    app.startImport(session, everything: true)
                }
                .disabled(everything.count == 0)
            }
        } label: {
            // Where it goes is part of the choice: copying names the disk, so the bar needs no line of its own for it.
            if action == .copy, withDisk, let destination = app.destination {
                Label("To \(destination.name)", systemImage: app.copiesToMac ? "laptopcomputer" : "externaldrive")
            } else {
                Label(actionTitle(action), systemImage: actionSymbol(action))
            }
        }
        .menuStyle(.button)
        .buttonStyle(.bordered)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .fixedSize()
        .hoverSwell(1.03)
        .help("What happens with what you chose")
    }

    @ViewBuilder
    private func primary(action: ChosenAction, copy: (count: Int, bytes: UInt64), chosen: [MediaItem]) -> some View {
        let running = app.job?.isRunning == true
        if let progress {
            // While the card is being marked, the button makes way for how far it is.
            HStack(spacing: Space.m) {
                ProgressCapsule(fraction: Double(progress.done) / Double(max(1, progress.total)))
                    .frame(width: 140, height: 6)
                Text("\(progress.done) of \(progress.total)").font(.callout.weight(.semibold).monospacedDigit()).fixedSize()
            }
            .padding(.horizontal, Space.l)
            .frame(height: 34)
            .transition(.opacity)
        } else {
            primaryButton(action: action, copy: copy, chosen: chosen, running: running)
        }
    }

    @ViewBuilder
    private func primaryButton(action: ChosenAction, copy: (count: Int, bytes: UInt64), chosen: [MediaItem], running: Bool) -> some View {
        Group {
            switch action {
            case .copy:
                Button { app.startImport(session) } label: {
                    Group {
                        if app.destination == nil {
                            Label("No disk connected", systemImage: "externaldrive.badge.xmark")
                        } else if copy.count == 0 {
                            Label("Keep something first", systemImage: "checkmark.circle")
                        } else {
                            Label("Copy \(copy.count) (\(Format.bytes(copy.bytes)))", systemImage: "square.and.arrow.down.fill")
                        }
                    }
                    .fixedSize()
                }
                .disabled(running || app.destination == nil || copy.count == 0)
                .help(app.destination == nil ? "Connect your disk to copy" : copy.count == 0 ? "Keep (⏎) what should go to the disk"
                      : undecidedMeansKeep ? "Copies what you kept and what you did not judge" : "Copies only what you kept")
            case .stars:
                Button { start(.stars, items: chosen) } label: {
                    Label("Five stars for \(chosen.count)", systemImage: "star.fill").fixedSize()
                }
                .disabled(marking || chosen.isEmpty)
                .help("Puts five stars in what you kept, on the card, the way the camera does, so the camera and Creators' App see them")
            case .flag:
                Button { start(.flag, items: chosen) } label: {
                    Label("Flag \(chosen.count)", systemImage: "flag.fill").fixedSize()
                }
                .disabled(marking || chosen.isEmpty)
                .help("Puts a green label next to what you kept, on the card")
            }
        }
        .buttonStyle(.borderedProminent)
        .buttonBorderShape(.capsule)
        .controlSize(.large)
        .hoverSwell(1.03)
    }

    // MARK: Marking on the card

    /// Looks first whether any of it was rated before, and asks before a rating of someone else is replaced.
    private func start(_ mark: CardMark, items: [MediaItem]) {
        let root = review.root
        marking = true
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                items.filter { item in
                    let existing = CardMarker.existing(item, root: root)
                    return mark == .stars ? (existing.rating ?? 5) != 5 : (existing.label ?? CardMarker.label) != CardMarker.label
                }.count
            }.value
            marking = false
            pending = mark == .stars ? .stars : .flag
            if found > 0 {
                conflicts = found
                askOverwrite = true
            } else {
                run(mark == .stars ? .stars : .flag, overwrite: true)
            }
        }
    }

    private func run(_ action: ChosenAction, overwrite: Bool) {
        guard let mark = action.mark else { return }
        let kinds = CopyKinds(rawValue: kindsRaw) ?? .all
        let items = review.chosenItems(kinds: kinds, undecidedMeansKeep: undecidedMeansKeep)
        let root = review.root
        marking = true
        Task {
            progress = (0, items.count)
            let report: @Sendable (Int) async -> Void = { done in await MainActor.run { progress = (done, items.count) } }
            let result = await Task.detached(priority: .userInitiated) { () -> (written: [String], kept: Int, beside: Int, failure: String?) in
                var written: [String] = [], kept = 0, beside = 0
                for (index, item) in items.enumerated() {
                    if index % 3 == 0 { await report(index) }
                    if !overwrite {
                        let existing = CardMarker.existing(item, root: root)
                        let other = mark == .stars ? (existing.rating ?? 5) != 5 : (existing.label ?? CardMarker.label) != CardMarker.label
                        if other { kept += 1; continue }
                    }
                    do {
                        if mark == .stars {
                            if try CardMarker.giveStars(5, to: item, root: root) == .sidecar { beside += 1 }
                        } else {
                            try CardMarker.write(mark, to: item, root: root)
                        }
                        written.append(item.id)
                    } catch {
                        return (written, kept, beside, error.localizedDescription)
                    }
                }
                return (written, kept, beside, nil)
            }.value
            marking = false
            withAnimation(.rushesFade) { progress = nil }
            // Keeping means five stars here too, so what the app shows matches what is on the card.
            if mark == .stars {
                for id in result.written {
                    guard let item = review.allItems.first(where: { $0.id == id }) else { continue }
                    review.ratings[id] = 5
                    review.persistChoice?(item, review.verdicts[id], 5)
                }
            }
            if let failure = result.failure {
                outcome = String(localized: "Not everything could be marked. Is the card locked? \(failure)")
            } else {
                var text = mark == .stars
                    ? String(localized: "\(result.written.count) now have five stars on the card.")
                    : String(localized: "\(result.written.count) are now flagged on the card.")
                if result.kept > 0 { text += " " + String(localized: "\(result.kept) kept their own stars.") }
                if result.beside > 0 { text += " " + String(localized: "\(result.beside) videos or files without room have them in a file beside them, which the camera does not read.") }
                if mark == .stars, result.written.count > result.beside {
                    text += " " + String(localized: "If the camera does not show them, choose Recover Image DB in its menu.")
                }
                outcome = text
            }
        }
    }

    private func actionTitle(_ action: ChosenAction) -> LocalizedStringKey {
        switch action {
        case .copy: "Copy"
        case .stars: "Stars"
        case .flag: "Flag"
        }
    }

    private func actionSymbol(_ action: ChosenAction) -> String {
        switch action {
        case .copy: "square.and.arrow.down"
        case .stars: "star"
        case .flag: "flag"
        }
    }

    private func kindTitle(_ kinds: CopyKinds) -> LocalizedStringKey {
        switch kinds {
        case .all: "Both"
        case .video: "Videos"
        case .photo: "Photos"
        }
    }

    private func kindSymbol(_ kinds: CopyKinds) -> String {
        switch kinds {
        case .all: "square.stack"
        case .video: "film"
        case .photo: "photo"
        }
    }
}

/// What the main button of a card does with what was chosen.
enum ChosenAction: String {
    case copy, stars, flag

    var mark: CardMark? {
        switch self {
        case .copy: nil
        case .stars: .stars
        case .flag: .flag
        }
    }
}

private struct Stat: View {
    let symbol: String
    let tint: Color
    let value: String
    let detail: String
    var active = false
    var help: LocalizedStringKey = ""
    var action: () -> Void = {}

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(tint.gradient, in: .circle)
                VStack(alignment: .leading, spacing: 0) {
                    Text(value).font(.callout.weight(.semibold).monospacedDigit()).contentTransition(.numericText())
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.leading, Space.xs)
            .padding(.trailing, Space.m)
            .padding(.vertical, Space.xs)
            // The one being shown has a pill behind it, so it is plain which part of the card the list is.
            .background { Capsule().fill(active ? tint.opacity(0.18) : .clear) }
            .contentShape(Capsule())
        }
        .buttonStyle(.bouncy)
        .help(help)
    }
}
