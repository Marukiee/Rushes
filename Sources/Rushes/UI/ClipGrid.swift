import RushesKit
import SwiftUI

/// What to say about a verdict, with its colour. Green leaves, red goes, so it reads without a word.
enum VerdictStyle {
    static let keep = Color(hex: 0x34C77B)
    static let skip = Color(hex: 0xF0526E)
    static let hint = Color(hex: 0xF5A524)

    static func color(_ verdict: Verdict) -> Color {
        switch verdict {
        case .keep: keep
        case .skip: skip
        case .undecided: .secondary
        }
    }

    static func symbol(_ verdict: Verdict, mode: ReviewModel.Mode) -> String {
        switch verdict {
        case .keep: mode == .library ? "lock.fill" : "checkmark"
        case .skip: mode == .library ? "trash.fill" : "xmark"
        case .undecided: "circle.dashed"
        }
    }
}

extension Suggestion {
    var text: String {
        switch self {
        case .flatFrame: String(localized: "Black or covered")
        case .tooShort: String(localized: "Very short")
        case .blurry: String(localized: "Out of focus")
        case .nearDuplicate: String(localized: "Near copy")
        }
    }

    var symbol: String {
        switch self {
        case .flatFrame: "moon.fill"
        case .tooShort: "scissors"
        case .blurry: "camera.metering.unknown"
        case .nearDuplicate: "square.on.square"
        }
    }
}

extension ResolveIndex.Usage {
    var badge: (text: String, symbol: String, color: Color) {
        switch status {
        case .used: (String(localized: "In a project"), "checkmark.seal.fill", VerdictStyle.keep)
        case .poolOnly: (String(localized: "Media pool only"), "tray.fill", VerdictStyle.hint)
        case .possible: (String(localized: "Maybe used"), "questionmark.circle.fill", VerdictStyle.hint)
        case .unused: (String(localized: "Not used"), "circle.slash", VerdictStyle.skip)
        }
    }
}

struct ClipGrid: View {
    var model: ReviewModel
    var showUsage = false
    /// Room kept free at the top for a control that floats over the list. The clips pass under it as they scroll.
    var topInset: CGFloat = 0

    private let columns = [GridItem(.adaptive(minimum: 120, maximum: 200), spacing: Space.s)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: Space.s, pinnedViews: [.sectionHeaders]) {
                    ForEach(model.sections) { section in
                        Section {
                            ForEach(section.items) { item in
                                ClipCell(model: model, item: item, showUsage: showUsage)
                                    .id(item.id)
                            }
                        } header: {
                            DayHeader(section: section, model: model)
                        }
                    }
                }
                .padding(.bottom, Space.xl)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                        model.gridColumns = max(1, Int((width + 8) / (120 + 8)))
                    }
                })
            }
            .scrollIndicators(.automatic)
            .contentMargins(.top, topInset, for: .scrollContent)
            .contentMargins(.top, topInset, for: .scrollIndicators)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onChange(of: model.focusID) { _, id in
                if let id { withAnimation(.rushes) { proxy.scrollTo(id, anchor: .center) } }
            }
        }
    }
}

private struct DayHeader: View {
    let section: ReviewSection
    var model: ReviewModel

    var body: some View {
        HStack(spacing: 8) {
            Text(Format.shortDay(section.day)).font(.callout.weight(.semibold)).lineLimit(1)
            Text("\(section.items.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(Format.bytes(section.items.reduce(0) { $0 + $1.totalBytes })).font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.s)
        .background(.regularMaterial, in: Capsule())
        .padding(.top, Space.xs)
        .padding(.bottom, Space.xs)
    }
}

struct ClipCell: View {
    var model: ReviewModel
    let item: MediaItem
    var showUsage: Bool
    private var preview: HoverPreview { HoverPreview.shared }

    @LocalState private var image: CGImage?
    @LocalState private var hovering = false
    @LocalState private var width: CGFloat = 160
    @LocalState private var videoReady = false
    @LocalState private var pointerX: CGFloat = 0

    var body: some View {
        let selected = model.selection.contains(item.id)
        let focused = model.focusID == item.id
        let verdict = model.verdict(of: item)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        Color.black.opacity(0.9)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                ZStack {
                    if let image {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: item.kind == .video ? "film" : "photo")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    // The pointer over a clip skims it, and a pointer at rest plays it, the way DaVinci Resolve does.
                    if item.kind == .video, preview.activeID == item.id, let player = preview.player(for: item.id) {
                        HoverSurface(player: player) { ready in withAnimation(.rushesFade) { videoReady = ready } }
                            .opacity(videoReady ? 1 : 0)
                        skimLine
                    }
                    if verdict == .skip {
                        Rectangle().fill(Color.black.opacity(0.55))
                    }
                    overlays(verdict: verdict)
                }
            }
            .clipShape(shape)
        .overlay {
            // The pointer, the choice and the one in view are all shown inside the picture's own edge. Nothing grows or throws a
            // shadow, because the list clips at its sides and a zoomed cell would lose its edge there.
            shape.strokeBorder(
                focused ? Palette.accent : (selected ? Palette.accent.opacity(0.7) : (hovering ? Color.primary.opacity(0.45) : Color.primary.opacity(0.08))),
                lineWidth: focused ? 3 : (selected || hovering ? 2 : 0.5)
            )
        }
        .animation(.rushesFade, value: hovering)
        .animation(.rushesFade, value: verdict)
        .contentShape(shape)
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.focus(item.id, extend: flags.contains(.shift), toggle: flags.contains(.command))
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onContinuousHover { phase in
            switch phase {
            case let .active(point):
                hovering = true
                pointerX = point.x
                if item.kind == .video {
                    preview.hover(item, root: model.root, at: Double(point.x / max(width, 1)), knownDuration: model.metadata[item.id]?.duration)
                }
            case .ended:
                hovering = false
                videoReady = false
                preview.end(item.id)
            }
        }
        .task(id: item.id) {
            image = await Thumbnailer.shared.image(for: item, root: model.root, maxPixel: 480)
        }
        .help(item.name)
    }

    /// The playhead of the skimming: a thin line where the pointer is, with the time it stands for.
    private var skimLine: some View {
        ZStack(alignment: .leading) {
            Rectangle().fill(.white.opacity(0.9)).frame(width: 1.5).shadow(radius: 2).offset(x: pointerX)
            Text(Format.timecode(preview.seconds))
                .font(.system(size: 10, weight: .semibold).monospacedDigit())
                .foregroundStyle(.white)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(.black.opacity(0.55), in: Capsule())
                .offset(x: min(max(pointerX + 6, 4), width - 44), y: 0)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 6)
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func overlays(verdict: Verdict) -> some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                if verdict != .undecided {
                    Image(systemName: VerdictStyle.symbol(verdict, mode: model.mode))
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(VerdictStyle.color(verdict).gradient, in: .circle)
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer(minLength: 0)
                if let suggestion = model.suggestions[item.id], verdict == .undecided {
                    badge(suggestion.text, symbol: suggestion.symbol, color: VerdictStyle.hint)
                } else if showUsage, let usage = model.usage[item.id], item.kind == .video || usage.status != .unused {
                    let info = usage.badge
                    badge(info.text, symbol: info.symbol, color: info.color)
                }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                HStack(spacing: 4) {
                    if item.kind == .video {
                        Image(systemName: "play.fill").font(.system(size: 8))
                        Text(Format.duration(model.metadata[item.id]?.duration)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                    } else {
                        Image(systemName: "photo").font(.system(size: 9))
                        if item.companion(.pair) != nil { Text("RAW+JPG").font(.system(size: 9, weight: .bold)) }
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: .capsule)
                Spacer(minLength: 0)
                if let rating = model.ratings[item.id], rating > 0 {
                    HStack(spacing: 1) {
                        ForEach(0 ..< rating, id: \.self) { _ in Image(systemName: "star.fill").font(.system(size: 8)) }
                    }
                    .foregroundStyle(VerdictStyle.hint)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(.black.opacity(0.55), in: .capsule)
                }
            }
        }
        .padding(8)
    }

    private func badge(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 9, weight: .bold))
            Text(text).font(.system(size: 10, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.92), in: .capsule)
    }
}
