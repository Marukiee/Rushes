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

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 10)]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVGrid(columns: columns, spacing: 10, pinnedViews: [.sectionHeaders]) {
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
                .padding(.horizontal, 14)
                .padding(.bottom, 24)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                        model.gridColumns = max(1, Int((width + 10) / (150 + 10)))
                    }
                })
            }
            .scrollIndicators(.automatic)
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
            Text(Format.day(section.day)).font(.callout.weight(.semibold))
            Text("\(section.items.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(Format.bytes(section.items.reduce(0) { $0 + $1.totalBytes })).font(.caption).foregroundStyle(.tertiary)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .rushesGlass(.capsule)
        .padding(.top, 8)
        .padding(.bottom, 2)
    }
}

struct ClipCell: View {
    var model: ReviewModel
    let item: MediaItem
    var showUsage: Bool

    @LocalState private var image: CGImage?
    @LocalState private var strip: [CGImage] = []
    @LocalState private var scrubIndex: Int?
    @LocalState private var hovering = false

    var body: some View {
        let selected = model.selection.contains(item.id)
        let focused = model.focusID == item.id
        let verdict = model.verdict(of: item)
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)

        Color.black.opacity(0.9)
            .aspectRatio(16 / 9, contentMode: .fit)
            .overlay {
                ZStack {
                    if let shown = scrubIndex.flatMap({ strip.indices.contains($0) ? strip[$0] : nil }) ?? image {
                        Image(decorative: shown, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Image(systemName: item.kind == .video ? "film" : "photo")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.25))
                    }
                    if verdict == .skip {
                        Rectangle().fill(Color.black.opacity(0.55))
                    }
                    overlays(verdict: verdict)
                }
            }
            .clipShape(shape)
        .overlay {
            shape.strokeBorder(
                focused ? Palette.indigoLight : (selected ? Palette.indigo : Color.white.opacity(0.06)),
                lineWidth: focused ? 3 : (selected ? 2 : 1)
            )
        }
        .shadow(color: .black.opacity(hovering ? 0.28 : 0.10), radius: hovering ? 10 : 4, y: hovering ? 5 : 2)
        .scaleEffect(hovering && !focused ? 1.02 : 1)
        .animation(.rushesSpringy, value: hovering)
        .animation(.rushesFade, value: verdict)
        .contentShape(shape)
        .onTapGesture {
            let flags = NSEvent.modifierFlags
            model.focus(item.id, extend: flags.contains(.shift), toggle: flags.contains(.command))
        }
        .onContinuousHover { phase in
            switch phase {
            case let .active(point):
                hovering = true
                if item.kind == .video { scrub(at: point.x) }
            case .ended:
                hovering = false
                scrubIndex = nil
            }
        }
        .task(id: item.id) {
            image = await Thumbnailer.shared.image(for: item, root: model.root, maxPixel: 480)
        }
        .help(item.name)
    }

    private func scrub(at x: CGFloat) {
        if strip.isEmpty {
            Task {
                let frames = await Thumbnailer.shared.strip(for: item, root: model.root, count: 12, maxPixel: 320)
                strip = frames
            }
            return
        }
        let width: CGFloat = 170
        scrubIndex = min(strip.count - 1, max(0, Int(x / width * CGFloat(strip.count))))
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
