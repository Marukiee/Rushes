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
    @LocalState private var showDetails = true

    var body: some View {
        VStack(spacing: 12) {
            stage
            VerdictBar(model: model, onKeep: { perform(.keep) }, onSkip: { perform(.skip) })
            if showDetails, let item = model.focusItem {
                DetailsView(model: model, item: item)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.rushes, value: showDetails)
        .task(id: model.focusID) { await load() }
        .onDisappear { player.unload() }
        .background(KeyHandler(model: model, player: player, showDetails: $showDetails, perform: { perform($0) }))
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .frame(minHeight: 260)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.08), lineWidth: 1) }
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
            .rushesGlass(RoundedRectangle(cornerRadius: 16, style: .continuous))
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                if let suggestion = model.suggestions[item.id] {
                    Chip(text: suggestion.text, symbol: suggestion.symbol, tint: VerdictStyle.hint)
                        .padding(4).rushesGlass(.capsule)
                }
                if model.mode == .library, let usage = model.usage[item.id] {
                    let badge = usage.badge
                    Chip(text: badge.text, symbol: badge.symbol, tint: badge.color)
                        .padding(4).rushesGlass(.capsule)
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
        .rushesGlass(.capsule)
    }
}

// MARK: Verdict bar

struct VerdictBar: View {
    var model: ReviewModel
    let onKeep: () -> Void
    let onSkip: () -> Void

    var body: some View {
        let library = model.mode == .library
        let verdict = model.focusItem.map { model.verdict(of: $0) } ?? .undecided
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                Button { model.undo() } label: {
                    Image(systemName: "arrow.uturn.backward").frame(width: 20)
                }
                .glassButtonStyle()
                .controlSize(.large)
                .disabled(!model.canUndo)
                .help("Undo (Z)")

                Button(action: onSkip) {
                    HStack {
                        Image(systemName: library ? "trash" : "xmark")
                        Text(library ? LocalizedStringKey("Move to Trash") : LocalizedStringKey("Leave out"))
                        Spacer(minLength: 0)
                        KeyCap("X")
                    }
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .prominentButtonStyle()
                .tint(VerdictStyle.skip.opacity(verdict == .skip ? 1 : 0.78))
                .controlSize(.large)

                StarRating(model: model)

                Button(action: onKeep) {
                    HStack {
                        Image(systemName: library ? "lock" : "checkmark")
                        Text(library ? LocalizedStringKey("Protect") : LocalizedStringKey("Keep"))
                        Spacer(minLength: 0)
                        KeyCap("⏎")
                    }
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity)
                }
                .prominentButtonStyle()
                .tint(VerdictStyle.keep.opacity(verdict == .keep ? 1 : 0.78))
                .controlSize(.large)
            }
        }
    }
}

struct StarRating: View {
    var model: ReviewModel

    var body: some View {
        let current = model.focusID.flatMap { model.ratings[$0] } ?? 0
        HStack(spacing: 2) {
            ForEach(1 ... 5, id: \.self) { star in
                Button { model.rate(star == current ? 0 : star) } label: {
                    Image(systemName: star <= current ? "star.fill" : "star")
                        .font(.system(size: 13))
                        .foregroundStyle(star <= current ? VerdictStyle.hint : .secondary)
                        .frame(width: 20, height: 28)
                }
                .buttonStyle(.bouncy)
            }
        }
        .padding(.horizontal, 6)
        .rushesGlass(.capsule)
    }
}

// MARK: Details

private struct DetailsView: View {
    var model: ReviewModel
    let item: MediaItem

    var body: some View {
        let meta = model.metadata[item.id]
        VStack(alignment: .leading, spacing: 10) {
            if model.mode == .library, let usage = model.usage[item.id] {
                UsageList(usage: usage)
            }
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                row("Camera", meta?.camera)
                row("Lens", meta?.lens)
                row("Format", [meta?.codec, meta?.resolution, meta?.frameRateText].compactMap { $0 }.joined(separator: "  ·  "))
                row("Picture profile", meta?.gamma)
                if item.kind == .photo {
                    row("Exposure", [meta?.shutter, meta?.aperture.map { "f/\(String(format: "%g", $0))" }, meta?.iso.map { "ISO \($0)" }]
                        .compactMap { $0 }.joined(separator: "  ·  "))
                }
                row("File", item.primary.rel)
            }
            .font(.caption)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: 20)
    }

    @ViewBuilder
    private func row(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            GridRow {
                Text(title).foregroundStyle(.secondary)
                Text(value).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
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
