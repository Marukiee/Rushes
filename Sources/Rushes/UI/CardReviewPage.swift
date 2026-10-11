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
                if session.newItems == 0, !review.showKnown {
                    NothingNewView(session: session)
                } else {
                    ReviewBody(model: review) { SuggestionBanner(model: review) }
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if let review = session.review, session.phase == .ready, session.newItems > 0 || review.showKnown {
                ImportBar(session: session, review: review)
            }
        }
        .navigationTitle(session.name)
        .navigationSubtitle([headline(for: session), session.review?.progressText ?? ""].filter { !$0.isEmpty }.joined(separator: "  ·  "))
        .toolbar {
            if let review = session.review, session.phase == .ready, session.newItems > 0 || review.showKnown {
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
                text: "There is nothing new to copy. The card can be taken out.",
                tint: VerdictStyle.keep
            )
            HStack(spacing: 12) {
                ActionButton(title: "Eject the card", symbol: "eject.fill", prominent: true) { app.eject(session) }
                ActionButton(title: "Look at what was copied", symbol: "eye") {
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
    @AppStorage(PrefKey.undecidedMeansKeep) private var undecidedMeansKeep = true

    var body: some View {
        let counts = review.counts()
        let bytesKeep = review.bytes(for: .keep)
        let bytesSkip = review.bytes(for: .skip)
        let bytesRest = review.bytes(for: .undecided)
        let copyCount = counts.keep + (undecidedMeansKeep ? counts.undecided : 0)
        let copyBytes = bytesKeep + (undecidedMeansKeep ? bytesRest : 0)
        let running = app.job?.isRunning == true

        HStack(spacing: Space.xl) {
            HStack(spacing: Space.xl) {
                Stat(symbol: "checkmark", tint: VerdictStyle.keep, value: "\(counts.keep)", detail: Format.bytes(bytesKeep))
                Stat(symbol: "xmark", tint: VerdictStyle.skip, value: "\(counts.skip)", detail: Format.bytes(bytesSkip))
                Stat(symbol: "circle.dashed", tint: .secondary, value: "\(counts.undecided)", detail: Format.bytes(bytesRest))
            }
            Spacer(minLength: Space.m)
            if let destination = app.destination {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("To \(destination.name)").font(.caption.weight(.medium))
                    Text("\(Format.bytes(destination.available)) free").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Text("Connect your disk to copy").font(.caption.weight(.medium)).foregroundStyle(VerdictStyle.hint)
            }
            Menu {
                Toggle("Also copy what I have not judged", isOn: $undecidedMeansKeep)
                Divider()
                Button("Copy everything new, whatever I chose") { app.startImport(session, everything: true) }
            } label: {
                Label("More", systemImage: "chevron.up").labelStyle(.iconOnly)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            Button { app.startImport(session) } label: {
                Label(running ? LocalizedStringKey("Copying...") : LocalizedStringKey("Copy \(copyCount) (\(Format.bytes(copyBytes)))"), systemImage: "square.and.arrow.down.fill")
                    .fixedSize()
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
            .disabled(running || app.destination == nil || copyCount == 0)
        }
        .padding(.horizontal, Space.xl)
        .padding(.vertical, Space.m)
        .rushesGlass(Capsule())
        .padding(.horizontal, Space.page)
        .padding(.bottom, Space.l)
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
