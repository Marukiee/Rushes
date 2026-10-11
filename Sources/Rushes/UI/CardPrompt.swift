import AppKit
import RushesKit
import SwiftUI

/// What the little floating card has to say right now.
enum PromptState {
    case scanning(CardSession)
    case needsDisk(CardSession)
    case ask(CardSession)
    case nothingNew(CardSession)
    case copying(ImportJob)
    case done(ImportJob)
    case failed(ImportJob)
}

/// The glass card that appears in the corner of the screen when a card is put in: it says the card and the disk were
/// recognised and asks what to do. It floats over everything without taking the focus away from what the person is doing.
@MainActor
final class CardPromptController {
    static let shared = CardPromptController()

    private var panel: NSPanel?
    private var host: NSHostingView<PromptView>?
    private var lastState: String?

    static func state(for model: AppModel) -> PromptState? {
        if let job = model.job {
            switch job.phase {
            case .preparing, .copying, .finishing: return .copying(job)
            case .done: return .done(job)
            case .failed, .cancelled: return .failed(job)
            }
        }
        guard let session = model.sessions.first(where: { $0.stage != .dismissed && $0.stage != .imported }) else { return nil }
        switch session.phase {
        case .scanning: return .scanning(session)
        case .failed: return nil
        case .ready:
            if session.hasNothingNew { return .nothingNew(session) }
            if model.destination == nil { return .needsDisk(session) }
            return session.stage == .waiting ? .ask(session) : nil
        }
    }

    func sync(model: AppModel) {
        guard Prefs.bool(PrefKey.showRecognitionCard), let state = Self.state(for: model) else { hide(); return }
        // The window shows the same thing, so the card stays out of its way.
        if WindowOpener.shared.mainWindowIsFront, model.page == .overview || model.page == .review { hide(); return }
        show(state, model: model)
    }

    private func show(_ state: PromptState, model: AppModel) {
        let view = PromptView(state: state, model: model)
        if panel == nil { makePanel() }
        guard let panel else { return }
        if let host { host.rootView = view } else {
            let host = NSHostingView(rootView: view)
            host.sizingOptions = [.intrinsicContentSize]
            self.host = host
            panel.contentView = host
        }
        host?.layoutSubtreeIfNeeded()
        let size = host?.fittingSize ?? NSSize(width: 400, height: 150)
        position(panel, size: NSSize(width: 448, height: max(110, size.height)))
        // The system draws the shadow from what is on the window, so it follows the rounded shape and is never cut off.
        panel.invalidateShadow()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.35
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.0)
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak panel] in panel?.orderOut(nil) })
    }

    private func makePanel() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        self.panel = panel
    }

    private func position(_ panel: NSPanel, size: NSSize) {
        guard let screen = NSScreen.main else { return }
        let area = screen.visibleFrame
        let origin = NSPoint(x: area.maxX - size.width - 14, y: area.maxY - size.height - 10)
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

private struct PromptView: View {
    let state: PromptState
    var model: AppModel

    var body: some View {
        content
            .padding(18)
            .frame(width: 440)
            .rushesGlass(RoundedRectangle(cornerRadius: 32, style: .continuous))
            .padding(4)
            .environment(\.inFloatingPanel, true)
            .environment(model)
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case let .scanning(session):
            header(card: true, disk: model.destination != nil, title: String(localized: "\(session.name) found"), subtitle: String(localized: "Reading what is on it...")) {
                Button("Later") { model.dismiss(session) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        case let .needsDisk(session):
            header(card: true, disk: false, title: String(localized: "\(session.name) is in"), subtitle: String(localized: "Connect your disk and Rushes goes on by itself.")) {
                Button("Later") { model.dismiss(session) }.buttonStyle(.plain).foregroundStyle(.secondary)
            }
        case let .ask(session):
            VStack(alignment: .leading, spacing: 14) {
                header(card: true, disk: true, title: String(localized: "\(session.name) and \(model.destination?.name ?? String(localized: "your disk")) are in"), subtitle: AppModel.recognitionSummary(session, destination: model.destination)) { EmptyView() }
                ButtonRow {
                    let review = Prefs.cardBehavior != .copyAll
                    ActionButton(title: "Review", symbol: "eye", prominent: review, wide: true) { model.openReview(session) }
                    ActionButton(title: "Copy all", symbol: "square.and.arrow.down", prominent: !review, wide: true) { model.startImport(session, everything: true) }
                }
                HStack {
                    Spacer()
                    Button("Not now") { model.dismiss(session) }.buttonStyle(.plain).foregroundStyle(.secondary).font(.callout)
                    Spacer()
                }
            }
        case let .nothingNew(session):
            VStack(alignment: .leading, spacing: 14) {
                header(card: true, disk: true, title: String(localized: "Nothing new on \(session.name)"), subtitle: String(localized: "Everything on it is already on your disk.")) { EmptyView() }
                ButtonRow {
                    ActionButton(title: "Eject", symbol: "eject.fill", prominent: true, wide: true) { model.eject(session) }
                    ActionButton(title: "Close", symbol: "xmark", wide: true) { model.dismiss(session) }
                }
            }
        case let .copying(job):
            ImportCard(job: job, compact: true, bare: true)
        case let .done(job):
            ImportCard(job: job, compact: true, bare: true)
        case let .failed(job):
            ImportCard(job: job, compact: true, bare: true)
        }
    }

    private func header<Trailing: View>(card: Bool, disk: Bool, title: String, subtitle: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 14) {
            PairGlyph(disk: disk)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline).lineLimit(2)
                Text(subtitle).font(.callout).foregroundStyle(.secondary).lineLimit(3)
            }
            Spacer(minLength: 0)
            trailing()
        }
    }
}

/// The card and the disk, with a line between them that lights up when both are there.
struct PairGlyph: View {
    let disk: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "sdcard.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Palette.indigo.gradient, in: .circle)
            Capsule()
                .fill(disk ? VerdictStyle.keep : Color.secondary.opacity(0.4))
                .frame(width: 12, height: 3)
            Image(systemName: "externaldrive.fill")
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(disk ? .white : .secondary)
                .frame(width: 38, height: 38)
                .background(disk ? AnyShapeStyle(Palette.rose.gradient) : AnyShapeStyle(Color.secondary.opacity(0.18)), in: .circle)
        }
        .animation(.rushesBouncy, value: disk)
    }
}
