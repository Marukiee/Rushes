import AVFoundation
import RushesKit
import SwiftUI

/// The big picture: the clip or photo that is selected, controls to move through it, and the two buttons that matter.
struct ViewerPanel: View {
    var model: ReviewModel
    /// In the view mode the picture takes all the room, and only details that fit beside it stay.
    var viewing = false
    var onRequestDelete: (() -> Void)?

    @LocalState private var player = PlayerController()
    @LocalState private var photo: CGImage?
    @LocalState private var zoom = PhotoZoom()
    /// The whole photo, loaded the first time it is zoomed into.
    @LocalState private var fullPhoto: CGImage?
    @LocalState private var flash: Verdict?
    @AppStorage(PrefKey.showInspector) private var showDetails = true

    var body: some View {
        GeometryReader { geometry in
            // The picture is as wide as the column and never taller than about two thirds of it, so a tall photo leaves room for
            // the buttons. The frame is exactly the shape of the picture: no bars, and the clip goes round that.
            let barReserve: CGFloat = 76
            let upNextReserve: CGFloat = 104
            let full = geometry.size.height
            // A standing picture leaves room at its side, so the details go there and the picture can use nearly all the height.
            let sideWidth: CGFloat = 260
            let standing = aspect < 0.95
            let sideTallest = min(full * 0.85, full - barReserve)
            let sideHeight = min(sideTallest, max(0, geometry.size.width - sideWidth - Space.l) / aspect)
            let sideBySide = showDetails && !viewing && standing && model.focusItem != nil && sideHeight >= full * 0.45
            let detailsReserve: CGFloat = showDetails && !sideBySide && !viewing ? (model.mode == .library ? 240 : 176) : 0
            // The picture comes first, then the details. The look ahead only gets what is left over, it never makes the picture smaller.
            let cap = viewing ? 1.0 : (standing ? 0.85 : 0.7)
            let tallest = min(full * cap, max(full * 0.5, full - barReserve - detailsReserve))
            let height = sideBySide ? sideHeight : min(geometry.size.width / aspect, tallest)
            let width = height * aspect
            let showUpNext = !viewing && full - height - barReserve - detailsReserve > upNextReserve - 12
            VStack(spacing: Space.l) {
                HStack(alignment: .top, spacing: Space.l) {
                    stage
                        .frame(width: width, height: height)
                        // Over the frame, not in it: a bar wider than a narrow picture would otherwise push what floats off the edge.
                        .overlay(alignment: .topTrailing) { if let item = model.focusItem { topBar(item) } }
                    .overlay(alignment: .topLeading) { if let item = model.focusItem { judgement(item) } }
                        .overlay(alignment: .bottom) {
                            if model.focusItem?.kind == .video { TransportBar(player: player, lutName: player.lutName).padding(12) }
                        }
                        // The picture is dark whatever the Mac is set to, so what floats over it is dark glass with white text.
                        .environment(\.colorScheme, .dark)
                        .clipShape(RoundedRectangle(cornerRadius: Metrics.card, style: .continuous))
                        .frame(maxWidth: sideBySide ? nil : .infinity)
                    if sideBySide, let item = model.focusItem {
                        DetailsCard(model: model, item: item)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
                VerdictBar(model: model, onKeep: { perform(.keep, fromButton: true) }, onSkip: { perform(.skip, fromButton: true) })
                if showDetails, !sideBySide, !viewing, let item = model.focusItem {
                    DetailsCard(model: model, item: item)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                // What is left of the height goes to a look ahead, so the next clip is never a surprise.
                if showUpNext {
                    UpNextStrip(model: model)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(.rushes, value: showDetails)
            .animation(.rushes, value: showUpNext)
            .animation(.rushes, value: sideBySide)
        }
        .task(id: model.focusID) { await load() }
        .onDisappear { player.unload() }
        .background(KeyHandler(model: model, player: player, zoom: zoom, perform: { perform($0) }))
        .onChange(of: zoom.isZoomed) { _, zoomed in
            guard zoomed, fullPhoto == nil, let item = model.focusItem, item.kind == .photo else { return }
            Task {
                let full = await FullPhoto.load(item, root: model.root)
                if model.focusID == item.id { fullPhoto = full }
            }
        }
    }

    /// A verdict from a button or a key: the sign pops up over the picture, then the next one is chosen. A click on the button
    /// that is already lit takes the choice back, so a choice is never stuck.
    private func perform(_ verdict: Verdict, fromButton: Bool = false) {
        if fromButton, model.targets.count <= 1, let item = model.focusItem, model.verdict(of: item) == verdict {
            model.set(.undecided, advance: false)
            return
        }
        if model.mode == .library, verdict == .skip {
            if let onRequestDelete { onRequestDelete() } else { model.set(.skip) }
            return
        }
        withAnimation(.rushesBouncy) { flash = verdict }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { withAnimation(.rushesFade) { flash = nil } }
        model.set(verdict)
    }

    // MARK: Stage

    /// Width over height of the picture being shown.
    private var aspect: CGFloat {
        guard let item = model.focusItem else { return 16 / 9 }
        switch item.kind {
        case .photo:
            if let photo, photo.height > 0 { return CGFloat(photo.width) / CGFloat(photo.height) }
        case .video:
            if let known = player.videoAspect { return known }
        case .audio:
            break
        }
        if let meta = model.metadata[item.id], let width = meta.width, let height = meta.height, height > 0 { return CGFloat(width) / CGFloat(height) }
        return 16 / 9
    }

    private var stage: some View {
        ZStack {
            Color.black
            if let item = model.focusItem {
                switch item.kind {
                case .video:
                    PlayerSurface(player: player.player)
                    // A click on the picture plays or pauses it, like in any player, and not only the button in the bar.
                    Color.clear.contentShape(Rectangle()).onTapGesture { player.togglePlay() }
                    if let failed = player.failed {
                        Text(failed).font(.callout).foregroundStyle(.white.opacity(0.7)).padding()
                    }
                case .photo:
                    if let shown = fullPhoto ?? photo {
                        ZoomablePhoto(image: shown, zoom: zoom)
                    } else {
                        PillSpinner(size: 26, tint: .white.opacity(0.6))
                    }
                case .audio:
                    Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.white.opacity(0.4))
                }
                if let flash {
                    Image(systemName: VerdictStyle.symbol(flash, mode: model.mode))
                        .font(.system(size: 54, weight: .heavy))
                        .foregroundStyle(.white)
                        .frame(width: 110, height: 110)
                        .background(VerdictStyle.color(flash).gradient, in: .circle)
                        .shadow(radius: 20)
                        .transition(.scale(scale: 0.5).combined(with: .opacity))
                }
            } else {
                Text(model.visible.isEmpty ? LocalizedStringKey("Nothing to show") : LocalizedStringKey("Choose a clip"))
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .animation(.rushesBouncy, value: flash)
    }

    /// What stands over the picture: what the app suggests and whether a project uses the clip. The name and the details of the file are
    /// not drawn over the picture (they covered it), they stand at the top of the card under it.
    /// What has been decided about the picture in view, in its corner: keep or leave out, and the stars, so a second look
    /// shows it without looking down at the buttons.
    @ViewBuilder
    private func judgement(_ item: MediaItem) -> some View {
        let verdict = model.verdict(of: item)
        let stars = model.ratings[item.id] ?? 0
        if verdict != .undecided || stars > 0 {
            HStack(spacing: 8) {
                if verdict != .undecided {
                    HStack(spacing: 5) {
                        Image(systemName: VerdictStyle.symbol(verdict, mode: model.mode))
                            .font(.system(size: 10, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 20, height: 20)
                            .background(VerdictStyle.color(verdict).gradient, in: .circle)
                        Text(verdictText(verdict)).font(.caption.weight(.semibold)).foregroundStyle(.white)
                    }
                }
                if stars > 0 {
                    Text(String(repeating: "\u{2605}", count: stars))
                        .font(.system(size: 12))
                        .foregroundStyle(VerdictStyle.hint)
                }
            }
            .padding(.leading, verdict != .undecided ? 5 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .rushesVideoGlass(.capsule)
            .padding(12)
            .transition(.scale(scale: 0.8).combined(with: .opacity))
            .animation(.rushesBouncy, value: verdict)
            .animation(.rushesBouncy, value: stars)
        }
    }

    private func verdictText(_ verdict: Verdict) -> LocalizedStringKey {
        switch verdict {
        case .keep: model.mode == .library ? "Protected" : "Kept"
        case .skip: "Left out"
        case .undecided: ""
        }
    }

    private func topBar(_ item: MediaItem) -> some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let suggestion = model.suggestions[item.id] {
                Chip(text: suggestion.text, symbol: suggestion.symbol, tint: VerdictStyle.hint, plain: true)
                    .padding(.horizontal, 4).padding(.vertical, 3).rushesVideoGlass(.capsule)
            }
            if model.mode == .library, let usage = model.usage[item.id] {
                let badge = usage.badge
                Chip(text: badge.text, symbol: badge.symbol, tint: badge.color, plain: true)
                    .padding(.horizontal, 4).padding(.vertical, 3).rushesVideoGlass(.capsule)
            }
            if model.mode == .library, model.leftOutOnCard.contains(item.id), model.verdict(of: item) == .undecided {
                Chip(text: String(localized: "Left out on the card"), symbol: "xmark.circle.fill", tint: VerdictStyle.skip, plain: true)
                    .padding(.horizontal, 4).padding(.vertical, 3).rushesVideoGlass(.capsule)
            }
            if model.isOnDisk(item) {
                Chip(text: String(localized: "On disk"), symbol: "externaldrive.fill.badge.checkmark", tint: .white, plain: true)
                    .padding(.horizontal, 4).padding(.vertical, 3).rushesVideoGlass(.capsule)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
    }

    // MARK: Loading

    private func load() async {
        guard let item = model.focusItem else {
            player.unload()
            photo = nil
            return
        }
        switch item.kind {
        case .video:
            photo = nil
            let proxy = Prefs.bool(PrefKey.useProxies) ? await Thumbnailer.shared.playbackSource(of: item, root: model.root) : nil
            let source = proxy ?? model.url(of: item)
            // A proxy already has the camera's look baked in. The LUT is for the original, which is flat.
            let isProxy = source != model.url(of: item)
            let meta = model.metadata[item.id]
            await player.load(
                url: source, lutURL: model.lutURL(for: item), useLUT: !isProxy, isLog: meta?.isLog ?? false,
                autoplay: Prefs.bool(PrefKey.autoplay), loop: Prefs.bool(PrefKey.loopClips)
            )
        case .photo:
            player.unload()
            photo = nil
            fullPhoto = nil
            zoom.reset()
            photo = await Thumbnailer.shared.image(for: item, root: model.root, maxPixel: 2400)
        case .audio:
            player.unload()
            photo = nil
        }
    }
}

// MARK: Transport

private struct TransportBar: View {
    var player: PlayerController
    var lutName: String?

    var body: some View {
        // The whole bar when the picture is wide enough, a short one when it is narrow, so nothing falls off the end.
        ViewThatFits(in: .horizontal) {
            bar(full: true)
            bar(full: false)
            bar(full: false, time: false)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .rushesVideoGlass(.capsule)
    }

    private func bar(full: Bool, time: Bool = true) -> some View {
        HStack(spacing: 12) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.bouncy)
            if time {
                Text(Format.timecode(player.currentTime))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.9))
                    .fixedSize()
            }
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0 ... max(player.duration, 0.1)
            )
            .controlSize(.small)
            .frame(minWidth: 60)
            if full {
                Text(Format.timecode(player.duration))
                    .font(.system(size: 12, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
                    .fixedSize()
            }
            if player.rate != 0 && abs(player.rate) != 1 {
                Text("\(player.rate > 0 ? "" : "-")\(Int(abs(player.rate)))x")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .fixedSize()
            }
            if let lutName {
                // Flat on the glass of the bar: a chip with a pill of its own would be a pill in a pill.
                Button { player.toggleLook() } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "camera.filters").font(.system(size: 12, weight: .bold))
                        if full {
                            (player.lookOn ? Text(verbatim: lutName) : Text("As shot")).font(.caption.weight(.semibold)).lineLimit(1)
                        }
                    }
                    .foregroundStyle(player.lookOn ? Palette.indigoLight : Color.white.opacity(0.55))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bouncy)
                .help(player.lookOn ? LocalizedStringKey("LUT off (C)") : LocalizedStringKey("LUT on (C)"))
            }
            Button { player.muted.toggle() } label: {
                Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.bouncy)
            .help(player.muted ? LocalizedStringKey("Sound on (M)") : LocalizedStringKey("Sound off (M)"))
        }
    }
}

// MARK: Verdict bar

/// Keep and Leave out, with the stars between them and Undo beside. System glass buttons in one container, the words and
/// keys when the width allows, the symbols when it does not. A label is never cut off.
struct VerdictBar: View {
    var model: ReviewModel
    let onKeep: () -> Void
    let onSkip: () -> Void

    /// What every button in the row holds at least, so Undo is as tall as the keys with a key cap in them.
    private static let contentHeight: CGFloat = 26

    var body: some View {
        ViewThatFits(in: .horizontal) {
            bar(words: true, keys: true)
            bar(words: true, keys: false)
            bar(words: false, keys: false)
        }
    }

    private func bar(words: Bool, keys: Bool) -> some View {
        let library = model.mode == .library
        let verdict = model.focusItem.map { model.verdict(of: $0) } ?? .undecided
        return GlassEffectContainer(spacing: Space.m) {
            HStack(spacing: Space.m) {
                Button { model.undo() } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly).frame(width: 18, height: Self.contentHeight)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
                .hoverSwell(1.06)
                .disabled(!model.canUndo)
                .help("Undo (Z)")

                verdictButton(
                    symbol: library ? "trash" : "xmark", title: library ? "Move to Trash" : "Leave out", key: "X",
                    tint: VerdictStyle.skip, selected: verdict == .skip, words: words, keys: keys, action: onSkip
                )
                StarRating(model: model)
                verdictButton(
                    symbol: library ? "lock" : "checkmark", title: library ? "Protect" : "Keep", key: "\u{23CE}",
                    tint: VerdictStyle.keep, selected: verdict == .keep, words: words, keys: keys, action: onKeep
                )
            }
        }
    }

    private func verdictButton(symbol: String, title: LocalizedStringKey, key: String, tint: Color, selected: Bool, words: Bool, keys: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Image(systemName: symbol)
                if words {
                    Text(title).lineLimit(1)
                    if keys { KeyCap(key) }
                }
            }
            .font(.callout.weight(.semibold))
            .fixedSize()
            .frame(maxWidth: words ? .infinity : nil, minHeight: Self.contentHeight)
            .padding(.horizontal, words ? Space.xs : Space.s)
        }
        .buttonStyle(.glassProminent)
        .tint(selected ? tint : tint.opacity(0.85))
        .controlSize(.large)
        // The choice that is made has a ring, so it can be seen, and a click on it takes it back.
        .overlay { Capsule().strokeBorder(Color.white.opacity(selected ? 0.85 : 0), lineWidth: 2).padding(3).allowsHitTesting(false) }
        .animation(.rushesFade, value: selected)
        .hoverSwell(1.025)
        .help(selected ? LocalizedStringKey("Click again to take it back (R)") : title)
    }
}

struct StarRating: View {
    var model: ReviewModel

    var body: some View {
        let current = model.focusID.flatMap { model.ratings[$0] } ?? 0
        HStack(spacing: 0) {
            ForEach(1 ... 5, id: \.self) { star in
                Button { model.rate(star == current ? 0 : star) } label: {
                    Image(systemName: star <= current ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(star <= current ? VerdictStyle.hint : Color.secondary)
                        .frame(width: 22, height: 28)
                }
                .buttonStyle(.bouncy)
            }
        }
    }
}

struct UsageList: View {
    let usage: ResolveIndex.Usage

    var body: some View {
        let badge = usage.badge
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: badge.symbol).foregroundStyle(badge.color)
                Text(headline).font(.callout.weight(.semibold))
            }
            ForEach(usage.projects) { project in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "film.stack").font(.caption).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.project).font(.caption.weight(.semibold))
                        if !project.timelines.isEmpty {
                            Text(project.timelines.joined(separator: ", ") + (project.clipCount > 1 ? "  ·  \(project.clipCount)x" : ""))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        } else if project.inPool {
                            Text("In the media pool, on no timeline").font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("Same file name, other location").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
    }

    private var headline: String {
        switch usage.status {
        case .used: String(localized: "Used in \(usage.projects.count) project(s)")
        case .poolOnly: String(localized: "In the media pool of \(usage.projects.count) project(s), on no timeline")
        case .possible: String(localized: "A clip with this name is used elsewhere")
        case .unused: String(localized: "Not in any DaVinci Resolve project")
        }
    }
}

/// The next few clips, small, under the details. A click goes straight to one.
private struct UpNextStrip: View {
    var model: ReviewModel

    var body: some View {
        let upcoming = model.upcoming(5)
        if !upcoming.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Up next").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    if let position = model.focusPosition {
                        Text("\(position) of \(model.visible.count)").font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                    }
                }
                HStack(spacing: 8) {
                    ForEach(upcoming) { item in MiniThumb(model: model, item: item) }
                    if upcoming.count < 5 {
                        ForEach(0 ..< (5 - upcoming.count), id: \.self) { _ in Color.clear.aspectRatio(16 / 9, contentMode: .fit).frame(maxWidth: .infinity) }
                    }
                }
            }
            .padding(.top, 2)
        }
    }
}

private struct MiniThumb: View {
    var model: ReviewModel
    let item: MediaItem
    @LocalState private var image: CGImage?

    var body: some View {
        let verdict = model.verdict(of: item)
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        Button { model.focus(item.id) } label: {
            Color.black.opacity(0.9)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    ZStack(alignment: .topLeading) {
                        if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill) }
                        if verdict != .undecided {
                            Image(systemName: VerdictStyle.symbol(verdict, mode: model.mode))
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 16, height: 16)
                                .background(VerdictStyle.color(verdict).gradient, in: .circle)
                                .padding(4)
                        }
                    }
                }
                .clipShape(shape)
                .overlay { shape.strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
        }
        .buttonStyle(.thumb)
        .frame(maxWidth: .infinity)
        .task(id: item.id) { image = await Thumbnailer.shared.image(for: item, root: model.root, maxPixel: 240, look: Prefs.lutMode.look) }
        .help(item.name)
    }
}
