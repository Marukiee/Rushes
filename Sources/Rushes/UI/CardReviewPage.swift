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
            if let review = session.review, session.phase == .ready, review.actionableCount > 0, app.job?.isRunning != true {
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
                Button { app.eject(session) } label: { Label("Eject", systemImage: "eject").labelStyle(.titleAndIcon) }
                    .disabled(app.job?.isRunning == true)
                    .help("Eject the card")
            }
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

    var body: some View {
        let kinds = CopyKinds(rawValue: kindsRaw) ?? .all
        let counts = review.counts()
        let copy = review.toCopy(kinds: kinds, undecidedMeansKeep: undecidedMeansKeep)
        let everything = review.toCopy(kinds: kinds, undecidedMeansKeep: true, everything: true)
        let selected = review.selection.count > 1 ? review.selection : nil
        let running = app.job?.isRunning == true

        HStack(spacing: Space.xl) {
            HStack(spacing: Space.xl) {
                Stat(symbol: "checkmark", tint: VerdictStyle.keep, value: "\(counts.keep)", detail: Format.bytes(review.bytes(for: .keep)))
                Stat(symbol: "xmark", tint: VerdictStyle.skip, value: "\(counts.skip)", detail: Format.bytes(review.bytes(for: .skip)))
                Stat(symbol: "circle.dashed", tint: .secondary, value: "\(counts.undecided)", detail: Format.bytes(review.bytes(for: .undecided)))
            }
            Spacer(minLength: Space.m)
            if let destination = app.destination {
                VStack(alignment: .trailing, spacing: 1) {
                    if copy.count == 0, counts.keep == 0 {
                        Text("Keep (⏎) what should go to the disk").font(.caption.weight(.medium)).foregroundStyle(VerdictStyle.hint)
                    } else {
                        Text("To \(destination.name)").font(.caption.weight(.medium))
                    }
                    Text("\(Format.bytes(destination.available)) free").font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize()
            } else {
                Text("Connect your disk to copy").font(.caption.weight(.medium)).foregroundStyle(VerdictStyle.hint)
            }
            Menu {
                Picker("Copy", selection: $kindsRaw) {
                    Label("Videos and photos", systemImage: "square.stack").tag(CopyKinds.all.rawValue)
                    Label("Only videos", systemImage: "film").tag(CopyKinds.video.rawValue)
                    Label("Only photos", systemImage: "photo").tag(CopyKinds.photo.rawValue)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Label(kindTitle(kinds), systemImage: kindSymbol(kinds))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("What a copy takes along")
            Menu {
                Toggle("Also copy what I have not judged", isOn: $undecidedMeansKeep)
                Divider()
                if let selected {
                    let chosen = review.toCopy(kinds: .all, undecidedMeansKeep: true, everything: true, only: selected)
                    Button("Copy the \(selected.count) selected (\(Format.bytes(chosen.bytes)))", systemImage: "checklist") {
                        app.startImport(session, request: ImportRequest(everything: true, only: selected, kinds: .all, scope: String(localized: "the selection")))
                    }
                    .disabled(chosen.count == 0)
                }
                Button("Copy everything new, whatever I chose (\(everything.count), \(Format.bytes(everything.bytes)))", systemImage: "square.and.arrow.down.on.square") {
                    app.startImport(session, everything: true)
                }
                .disabled(everything.count == 0)
            } label: {
                Label("More", systemImage: "chevron.up").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More ways to copy")
            Button { app.startImport(session) } label: {
                Label("Copy \(copy.count) (\(Format.bytes(copy.bytes)))", systemImage: "square.and.arrow.down.fill")
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(running || app.destination == nil || copy.count == 0)
            .help(undecidedMeansKeep ? "Copies what you kept and what you did not judge" : "Copies only what you kept")
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .rushesGlass(Capsule())
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.l)
    }

    private func kindTitle(_ kinds: CopyKinds) -> LocalizedStringKey {
        switch kinds {
        case .all: "Videos and photos"
        case .video: "Only videos"
        case .photo: "Only photos"
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

private struct Stat: View {
    let symbol: String
    let tint: Color
    let value: String
    let detail: String

    var body: some View {
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
    }
}
