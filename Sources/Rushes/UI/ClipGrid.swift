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
    /// The same in one short word, for the small pill on a thumbnail.
    var shortBadge: (text: String, symbol: String, color: Color) {
        let full = badge
        switch status {
        case .used: return (String(localized: "Project"), full.symbol, full.color)
        case .poolOnly: return (String(localized: "Pool"), full.symbol, full.color)
        case .possible: return (String(localized: "Maybe"), full.symbol, full.color)
        case .unused: return (String(localized: "Unused"), full.symbol, full.color)
        }
    }

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

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: Space.s)]

    /// The clip at the top of what is in view, for the date beside the scroller and for staying on that day.
    @LocalState private var topID: String?
    @LocalState private var scrolling = false
    @LocalState private var scroll = ScrollPlace()
    /// A jump the grid makes itself, so the scroll that follows a new focus does not undo it.
    @LocalState private var holdFocusScroll = false

    struct ScrollPlace: Equatable {
        var offset: CGFloat = 0
        var content: CGFloat = 1
        var container: CGFloat = 1
    }

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
                .scrollTargetLayout()
                .padding(.bottom, Space.xl)
                .background(GeometryReader { geometry in
                    Color.clear.onChange(of: geometry.size.width, initial: true) { _, width in
                        model.gridColumns = max(1, Int((width + 8) / (150 + 8)))
                    }
                })
            }
            .onScrollTargetVisibilityChange(idType: String.self, threshold: 0.5) { ids in
                if let first = ids.first { topID = first }
            }
            .onScrollGeometryChange(for: ScrollPlace.self) { geometry in
                ScrollPlace(offset: geometry.contentOffset.y + geometry.contentInsets.top, content: geometry.contentSize.height, container: geometry.containerSize.height)
            } action: { _, place in scroll = place }
            .onScrollPhaseChange { _, phase in
                withAnimation(.rushesFade) { scrolling = phase != .idle }
            }
            .overlay(alignment: .topTrailing) { dateBubble }
            .scrollIndicators(.automatic)
            .contentMargins(.top, topInset, for: .scrollContent)
            .contentMargins(.top, topInset, for: .scrollIndicators)
            .scrollEdgeEffectStyle(.soft, for: .top)
            .onChange(of: model.focusID) { _, id in
                if holdFocusScroll { holdFocusScroll = false; return }
                if let id { withAnimation(.rushes) { proxy.scrollTo(id, anchor: .center) } }
            }
            // Switching between all, videos and photos stays on the day that was in view, it does not start over at the top.
            .onChange(of: model.kindFilter) { _, _ in
                guard let day = topDay else { return }
                let start = Calendar.current.startOfDay(for: day)
                guard let target = model.visible.first(where: { model.date(of: $0) >= start }) ?? model.visible.last else { return }
                DispatchQueue.main.async {
                    holdFocusScroll = model.focusID != target.id
                    model.focus(target.id)
                    proxy.scrollTo(target.id, anchor: .top)
                }
            }
        }
    }
}

extension ClipGrid {
    /// The day of the clip at the top of the view.
    private var topDay: Date? {
        guard let topID, let item = model.allItems.first(where: { $0.id == topID }) else { return nil }
        return model.date(of: item)
    }

    /// While the list is scrolled, the day in view floats beside the scroller, where the thumb is, the way Photos does it.
    @ViewBuilder
    private var dateBubble: some View {
        if scrolling, let day = topDay, scroll.content > scroll.container {
            GeometryReader { geometry in
                let track = max(1, geometry.size.height - topInset - 44)
                let fraction = min(1, max(0, scroll.offset / max(1, scroll.content - scroll.container)))
                Text(Format.shortDay(day))
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, Space.m)
                    .padding(.vertical, 6)
                    .rushesGlass(Capsule())
                    .fixedSize()
                    .offset(y: topInset + fraction * track)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .padding(.trailing, 18)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

/// The head of a day: a click selects the whole day, and the menu holds what can be done with all of it at once.
private struct DayHeader: View {
    @Environment(AppModel.self) private var app
    let section: ReviewSection
    var model: ReviewModel

    var body: some View {
        let kept = section.items.filter { model.verdict(of: $0) == .keep }.count
        let left = section.items.filter { model.verdict(of: $0) == .skip }.count
        let selected = !section.items.isEmpty && section.items.allSatisfy { model.selection.contains($0.id) }
        HStack(spacing: 8) {
            Text(Format.shortDay(section.day)).font(.callout.weight(.semibold)).lineLimit(1)
            Text("\(section.items.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            Text(Format.bytes(section.items.reduce(0) { $0 + $1.totalBytes })).font(.caption).foregroundStyle(.tertiary).lineLimit(1)
            Spacer(minLength: 4)
            if kept > 0 { tally(kept, symbol: VerdictStyle.symbol(.keep, mode: model.mode), tint: VerdictStyle.keep) }
            if left > 0, model.mode == .card { tally(left, symbol: "xmark", tint: VerdictStyle.skip) }
            DayMenu(section: section, model: model)
        }
        .padding(.leading, Space.m)
        .padding(.trailing, Space.xs)
        .padding(.vertical, Space.xs)
        .frame(minHeight: 36)
        .background(.regularMaterial, in: Capsule())
        .overlay { Capsule().strokeBorder(Palette.accent.opacity(selected ? 0.7 : 0), lineWidth: 2) }
        .contentShape(Capsule())
        .onTapGesture { model.selectDay(section) }
        .help("Click to select the whole day")
        .animation(.rushesFade, value: selected)
        .padding(.top, Space.xs)
        .padding(.bottom, Space.xs)
    }

    private func tally(_ count: Int, symbol: String, tint: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 9, weight: .heavy))
            Text("\(count)").font(.caption.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(tint)
    }
}

/// The three dots of a day: choose, copy or start over for every clip and photo of that day.
private struct DayMenu: View {
    @Environment(AppModel.self) private var app
    let section: ReviewSection
    var model: ReviewModel

    var body: some View {
        Menu {
            Button("Select the whole day", systemImage: "checklist") { model.selectDay(section) }
            Divider()
            if model.mode == .card {
                Button("Keep all of this day", systemImage: "checkmark.circle") { model.setDay(section, to: .keep) }
                Button("Leave out all of this day", systemImage: "xmark.circle") { model.setDay(section, to: .skip) }
                if let session, app.destination != nil {
                    Divider()
                    copyButtons(session)
                }
            } else {
                Button("Protect all of this day", systemImage: "lock") { model.setDay(section, to: .keep) }
            }
            Divider()
            Button("Reset the choices of this day...", systemImage: "arrow.counterclockwise") {
                model.pendingReset = .init(title: String(localized: "Reset the choices and stars of \(Format.shortDay(section.day))?"), items: section.items)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("This day")
    }

    private var session: CardSession? { app.sessions.first { $0.review === model } }

    @ViewBuilder
    private func copyButtons(_ session: CardSession) -> some View {
        let ids = Set(model.items(ofDay: section.day).map(\.id))
        let day = Format.shortDay(section.day)
        let kept = model.toCopy(kinds: .all, undecidedMeansKeep: false, only: ids)
        let videos = model.toCopy(kinds: .video, undecidedMeansKeep: false, everything: true, only: ids)
        let photos = model.toCopy(kinds: .photo, undecidedMeansKeep: false, everything: true, only: ids)
        let all = model.toCopy(kinds: .all, undecidedMeansKeep: false, everything: true, only: ids)
        let running = app.job?.isRunning == true
        Group {
            Button("Copy what I kept of this day (\(kept.count), \(Format.bytes(kept.bytes)))", systemImage: "checkmark.circle.fill") {
                app.startImport(session, request: ImportRequest(only: ids, kinds: .all, undecidedMeansKeep: false, scope: day))
            }
            .disabled(kept.count == 0)
            Button("Copy all videos of this day (\(videos.count), \(Format.bytes(videos.bytes)))", systemImage: "film") {
                app.startImport(session, request: ImportRequest(everything: true, only: ids, kinds: .video, scope: day))
            }
            .disabled(videos.count == 0)
            if photos.count > 0 {
                Button("Copy all photos of this day (\(photos.count), \(Format.bytes(photos.bytes)))", systemImage: "photo") {
                    app.startImport(session, request: ImportRequest(everything: true, only: ids, kinds: .photo, scope: day))
                }
            }
            Button("Copy all of this day (\(all.count), \(Format.bytes(all.bytes)))", systemImage: "square.and.arrow.down") {
                app.startImport(session, request: ImportRequest(everything: true, only: ids, kinds: .all, scope: day))
            }
            .disabled(all.count == 0)
        }
        .disabled(running)
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
                        // A picture that fills the cell must not make the cell taller, or the chips along the bottom fall outside it.
                        Color.clear.overlay {
                            Image(decorative: image, scale: 1)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        }
                        .clipped()
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
                    preview.hover(item, root: model.root, at: Double(point.x / max(width, 1)), knownDuration: model.metadata[item.id]?.duration, look: model.look(for: item))
                }
            case .ended:
                hovering = false
                videoReady = false
                preview.end(item.id)
            }
        }
        .contextMenu { CellMenu(model: model, item: item) }
        .task(id: item.id + Prefs.lutMode.rawValue) {
            image = await Thumbnailer.shared.image(for: item, root: model.root, maxPixel: 480, look: Prefs.lutMode.look)
        }
        .help(item.name)
    }

    /// The playhead of the skimming: a thin line where the pointer is, with the time it stands for.
    private var skimLine: some View {
        GeometryReader { proxy in
            let x = preview.playhead * proxy.size.width
            // Beside the line, and on the other side of it when the line is near the right edge.
            let labelX = x > proxy.size.width - 64 ? max(4, x - 58) : x + 6
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.white.opacity(0.9)).frame(width: 1.5, height: proxy.size.height).shadow(radius: 2).offset(x: x - 0.75)
                Text(Format.timecode(preview.seconds))
                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.white)
                    .fixedSize()
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(.bottom, 6)
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottomLeading)
                    .offset(x: labelX)
            }
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
                if model.mode == .library, verdict == .undecided, model.leftOutOnCard.contains(item.id) {
                    // Left out while the card was in, and here anyway: the same sign as on the card, so it reads the same.
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 24, height: 24)
                        .background(VerdictStyle.skip.gradient, in: .circle)
                        .help("Left out on the card")
                }
                Spacer(minLength: 0)
                if let suggestion = model.suggestions[item.id], verdict == .undecided, !model.isOnDisk(item) {
                    badge(suggestion.text, symbol: suggestion.symbol, color: VerdictStyle.hint)
                } else if model.isOnDisk(item) {
                    // Only the sign: once a whole card is copied every clip has it, and words on all of them would be noise.
                    Image(systemName: "externaldrive.fill.badge.checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: .capsule)
                        .help("On disk")
                } else if showUsage, let usage = model.usage[item.id], item.kind == .video || usage.status != .unused {
                    let info = usage.shortBadge
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
                    // How much room it takes, for deciding what is worth keeping.
                    Text(Format.bytes(item.totalBytes)).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(.white.opacity(0.7))
                }
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(.black.opacity(0.55), in: .capsule)
                // While the clip is skimmed the time under the line says where it is, so the length steps aside.
                .opacity(item.kind == .video && preview.activeID == item.id ? 0 : 1)
                Spacer(minLength: 0)
                if let rating = model.ratings[item.id], rating > 0 {
                    Text(String(repeating: "\u{2605}", count: rating))
                        .font(.system(size: 10))
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
        HStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 8, weight: .bold))
            Text(text).font(.system(size: 9, weight: .bold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.92), in: .capsule)
    }
}

/// A right click on a clip: the same choices as the keys, for the clip or for the selection it is part of.
private struct CellMenu: View {
    @Environment(AppModel.self) private var app
    var model: ReviewModel
    let item: MediaItem

    var body: some View {
        let library = model.mode == .library
        Button(library ? "Protect" : "Keep", systemImage: library ? "lock" : "checkmark") { target(); model.set(.keep, advance: false) }
        if !library {
            Button("Leave out", systemImage: "xmark") { target(); model.set(.skip, advance: false) }
        }
        Button("Reset choice and stars (R)", systemImage: "arrow.counterclockwise") { target(); model.reset() }
        Divider()
        if !library, let session = app.sessions.first(where: { $0.review === model }), app.destination != nil {
            let ids = Set((model.selection.contains(item.id) ? model.targets : [item]).map(\.id))
            Button(ids.count == 1 ? "Copy this one" : "Copy these \(ids.count)", systemImage: "square.and.arrow.down") {
                app.startImport(session, request: ImportRequest(everything: true, only: ids, kinds: .all, scope: String(localized: "the selection")))
            }
            .disabled(app.job?.isRunning == true || model.toCopy(kinds: .all, undecidedMeansKeep: true, everything: true, only: ids).count == 0)
        }
        Button("Show in Finder", systemImage: "folder") { NSWorkspace.shared.activateFileViewerSelecting([model.url(of: item)]) }
    }

    /// A right click on a clip outside the selection makes it the one in hand, as everywhere on the Mac.
    private func target() {
        if !model.selection.contains(item.id) { model.focus(item.id) }
    }
}
