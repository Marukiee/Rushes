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
        VStack(spacing: 0) {
            CardHeader(session: session)
            if session.phase == .scanning {
                VStack(spacing: 14) {
                    PillSpinner(size: 34)
                    Text("Reading \(session.name)...").font(.title3.weight(.semibold))
                    Text("Looking at what is on the card. Nothing is copied yet.").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let review = session.review {
                if session.newItems == 0, !review.showKnown {
                    NothingNewView(session: session)
                } else {
                    ReviewBody(model: review)
                    ImportBar(session: session, review: review)
                }
            }
        }
    }
}

private struct CardHeader: View {
    @Environment(AppModel.self) private var app
    let session: CardSession

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 42, height: 42)
                .background(Palette.indigo.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.title2.weight(.bold))
                Text(headline).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            if app.sessions.count > 1 {
                Picker("Card", selection: Binding(get: { app.reviewSessionID ?? session.id }, set: { app.reviewSessionID = $0 })) {
                    ForEach(app.sessions) { Text($0.name).tag($0.id) }
                }
                .frame(width: 160)
            }
            Button { app.eject(session) } label: {
                Label("Eject", systemImage: "eject.fill")
            }
            .glassButtonStyle()
            .disabled(app.job?.isRunning == true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 8)
    }

    private var headline: String {
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

/// What will be copied, and the button that copies it.
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

        HStack(spacing: 18) {
            Group {
                Stat(symbol: "checkmark", tint: VerdictStyle.keep, value: "\(counts.keep)", detail: Format.bytes(bytesKeep))
                Stat(symbol: "xmark", tint: VerdictStyle.skip, value: "\(counts.skip)", detail: Format.bytes(bytesSkip))
                Stat(symbol: "circle.dashed", tint: .secondary, value: "\(counts.undecided)", detail: Format.bytes(bytesRest))
            }
            Spacer(minLength: 8)
            if let destination = app.destination {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("To \(destination.name)").font(.caption.weight(.semibold))
                    Text("\(Format.bytes(destination.available)) free").font(.caption).foregroundStyle(.secondary)
                }
            }
            Menu {
                Toggle("Also copy what I have not judged", isOn: $undecidedMeansKeep)
                Divider()
                Button("Copy everything new, whatever I chose") { app.startImport(session, everything: true) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .menuStyle(.button)
            .glassButtonStyle()
            .controlSize(.large)
            .menuIndicator(.hidden)

            ActionButton(title: running ? "Copying..." : "Copy \(copyCount) (\(Format.bytes(copyBytes)))", symbol: "square.and.arrow.down.fill", prominent: true) {
                app.startImport(session)
            }
            .disabled(running || app.destination == nil || copyCount == 0)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .rushesGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 20)
        .padding(.bottom, 14)
        .overlay(alignment: .top) {
            if app.destination == nil {
                Text("Connect your disk to copy").font(.caption.weight(.semibold)).foregroundStyle(VerdictStyle.hint).offset(y: -12)
            }
        }
    }
}

private struct Stat: View {
    let symbol: String
    let tint: Color
    let value: String
    let detail: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .heavy))
                .foregroundStyle(.white)
                .frame(width: 22, height: 22)
                .background(tint.gradient, in: .circle)
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.callout.weight(.bold).monospacedDigit()).contentTransition(.numericText())
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }
}
