import AVFoundation
import RushesKit
import SwiftUI

/// The big picture: the clip or photo that is selected, controls to move through it, and the two buttons that matter.
struct ViewerPanel: View {
    var model: ReviewModel
    var onRequestDelete: (() -> Void)?

    @LocalState private var player = PlayerController()
    @LocalState private var photo: CGImage?
    @LocalState private var flash: Verdict?
    @AppStorage(PrefKey.showInspector) private var showDetails = true

    var body: some View {
        GeometryReader { geometry in
            // The picture is as wide as the column and never taller than about two thirds of it, so a tall photo leaves room for
            // the buttons. The frame is exactly the shape of the picture: no bars, and the clip goes round that.
            let tallest = max(220, geometry.size.height * 0.55)
            let height = min(geometry.size.width / aspect, tallest)
            let width = height * aspect
            VStack(spacing: Space.l) {
                stage
                    // The picture is dark whatever the Mac is set to, so what floats over it is dark glass with white text.
                    .environment(\.colorScheme, .dark)
                    .frame(width: width, height: height)
                    .clipShape(RoundedRectangle(cornerRadius: Metrics.card, style: .continuous))
                    .frame(maxWidth: .infinity)
                VerdictBar(model: model, onKeep: { perform(.keep) }, onSkip: { perform(.skip) })
                if showDetails, let item = model.focusItem {
                    DetailsCard(model: model, item: item)
                }
                // What is left of the height goes to a look ahead, so the next clip is never a surprise.
                if geometry.size.height - height - (showDetails ? 290 : 100) > 90 { UpNextStrip(model: model) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task(id: model.focusID) { await load() }
        .onDisappear { player.unload() }
        .background(KeyHandler(model: model, player: player, perform: { perform($0) }))
    }

    /// A verdict from a button or a key: the sign pops up over the picture, then the next one is chosen.
    private func perform(_ verdict: Verdict) {
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
                    if let failed = player.failed {
                        Text(failed).font(.callout).foregroundStyle(.white.opacity(0.7)).padding()
                    }
                case .photo:
                    if let photo {
                        Image(decorative: photo, scale: 1).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        PillSpinner(size: 26, tint: .white.opacity(0.6))
                    }
                case .audio:
                    Image(systemName: "waveform").font(.system(size: 44)).foregroundStyle(.white.opacity(0.4))
                }
                topBar(item)
                if item.kind == .video { TransportBar(player: player, lutName: player.lutName).padding(12).frame(maxHeight: .infinity, alignment: .bottom) }
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

    private func topBar(_ item: MediaItem) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name).font(.callout.weight(.semibold)).foregroundStyle(.white)
                Text(subtitle(for: item)).font(.caption).foregroundStyle(.white.opacity(0.7))
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .rushesVideoGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let suggestion = model.suggestions[item.id] {
                    Chip(text: suggestion.text, symbol: suggestion.symbol, tint: VerdictStyle.hint)
                        .padding(4).rushesVideoGlass(.capsule)
                }
                if model.mode == .library, let usage = model.usage[item.id] {
                    let badge = usage.badge
                    Chip(text: badge.text, symbol: badge.symbol, tint: badge.color)
                        .padding(4).rushesVideoGlass(.capsule)
                }
            }
        }
        .padding(12)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func subtitle(for item: MediaItem) -> String {
        var parts: [String] = []
        let meta = model.metadata[item.id]
        parts.append(model.date(of: item).formatted(date: .abbreviated, time: .shortened))
        if let resolution = meta?.resolution { parts.append(resolution) }
        if let fps = meta?.frameRateText, item.kind == .video { parts.append(fps) }
        parts.append(Format.bytes(item.totalBytes))
        return parts.joined(separator: "  ·  ")
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
        HStack(spacing: 12) {
            Button { player.togglePlay() } label: {
                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 15, weight: .bold))
                    .frame(width: 30, height: 30)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            Text(Format.timecode(player.currentTime))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
                .frame(width: 52, alignment: .trailing)
            Slider(
                value: Binding(get: { player.currentTime }, set: { player.seek(to: $0) }),
                in: 0 ... max(player.duration, 0.1)
            )
            .controlSize(.small)
            Text(Format.timecode(player.duration))
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
                .frame(width: 52, alignment: .leading)
            if player.rate != 0 && abs(player.rate) != 1 {
                Text("\(player.rate > 0 ? "" : "-")\(Int(abs(player.rate)))x")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
            }
            if let lutName {
                Chip(text: lutName, symbol: "camera.filters", tint: Palette.indigoLight)
            }
            Button { player.muted.toggle() } label: {
                Image(systemName: player.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 13))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .help(player.muted ? LocalizedStringKey("Sound on (M)") : LocalizedStringKey("Sound off (M)"))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .rushesVideoGlass(.capsule)
    }
}

// MARK: Verdict bar

/// Keep and Leave out, with the stars between them and Undo beside. System glass buttons in one container, the words and
/// keys when the width allows, the symbols when it does not. A label is never cut off.
struct VerdictBar: View {
    var model: ReviewModel
    let onKeep: () -> Void
    let onSkip: () -> Void

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
                    Label("Undo", systemImage: "arrow.uturn.backward").labelStyle(.iconOnly).frame(width: 18)
                }
                .buttonStyle(.glass)
                .controlSize(.large)
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
            .frame(maxWidth: words ? .infinity : nil)
            .padding(.horizontal, words ? Space.xs : Space.s)
        }
        .buttonStyle(.glassProminent)
        .tint(selected ? tint : tint.opacity(0.85))
        .controlSize(.large)
        .help(title)
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
        .buttonStyle(.bouncy)
        .frame(maxWidth: .infinity)
        .task(id: item.id) { image = await Thumbnailer.shared.image(for: item, root: model.root, maxPixel: 240) }
        .help(item.name)
    }
}
