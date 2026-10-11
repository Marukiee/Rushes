import AVFoundation
import AppKit
import RushesKit
import SwiftUI

/// The skimming of a clip under the pointer, the way DaVinci Resolve does it: the picture follows the mouse over the
/// thumbnail, and when the pointer rests the clip plays on from where it is.
///
/// A few players are kept, not one per thumbnail and not one for all: moving back to a clip you just left is instant and
/// shows the frame you left it on, and moving to a new one starts at once because its length is already known.
@MainActor
@Observable
final class HoverPreview {
    static let shared = HoverPreview()

    /// One clip that has a player: its own position, and whether a seek is on its way.
    @MainActor
    final class Slot {
        let id: String
        let player = AVPlayer()
        var duration: Double
        var fraction: Double = 0
        var isSeeking = false
        var pending: Double?

        init(id: String, duration: Double) {
            self.id = id
            self.duration = duration
            player.isMuted = true
            player.actionAtItemEnd = .none
            player.automaticallyWaitsToMinimizeStalling = false
        }
    }

    private static let capacity = 3

    private(set) var activeID: String?
    private(set) var seconds: Double = 0
    /// Where the playhead is, 0 to 1: under the pointer while skimming, moving along while the clip plays. The line in the
    /// thumbnail is drawn here, so the picture and the line are always the same moment.
    private(set) var playhead: Double = 0
    private var timeObserver: (player: AVPlayer, token: Any)?
    private var slots: [Slot] = []
    private var restTask: Task<Void, Never>?
    private var observers: [String: NSObjectProtocol] = [:]

    func player(for id: String) -> AVPlayer? { slots.first { $0.id == id }?.player }

    /// The pointer is over a clip at this fraction of its width.
    func hover(_ item: MediaItem, root: URL, at fraction: Double, knownDuration: Double?, look: CubeLUT? = nil) {
        let slot = slotFor(item, root: root, knownDuration: knownDuration, look: look)
        // The one that was active, if there was one, stops where it is.
        if let previous = activeID, previous != item.id { slots.first { $0.id == previous }?.player.pause() }
        activeID = item.id
        slot.fraction = min(1, max(0, fraction))
        stopFollowing()
        playhead = slot.fraction
        scrub(slot)
        rest(slot)
    }

    func end(_ id: String) {
        guard activeID == id else { return }
        restTask?.cancel()
        stopFollowing()
        slots.first { $0.id == id }?.player.pause()
        activeID = nil
    }

    private func slotFor(_ item: MediaItem, root: URL, knownDuration: Double?, look: CubeLUT?) -> Slot {
        if let at = slots.firstIndex(where: { $0.id == item.id }) {
            // Most recently used goes last.
            let slot = slots.remove(at: at)
            slots.append(slot)
            return slot
        }
        let slot = Slot(id: item.id, duration: knownDuration ?? 0)
        let source = (item.companion(.proxy).map { root.appendingPathComponent($0.rel) }) ?? root.appendingPathComponent(item.primary.rel)
        let asset = AVURLAsset(url: source)
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 2
        // The original of a log clip plays with the look on it, like in the viewer. A proxy has it already.
        if let look, item.companion(.proxy) == nil {
            Task { if let composition = try? await Look.composition(for: asset, lut: look) { playerItem.videoComposition = composition } }
        }
        slot.player.replaceCurrentItem(with: playerItem)
        observers[item.id] = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: playerItem, queue: .main) { _ in
            MainActor.assumeIsolated { slot.player.seek(to: .zero) { _ in slot.player.play() } }
        }
        slots.append(slot)
        while slots.count > Self.capacity {
            let old = slots.removeFirst()
            old.player.pause()
            old.player.replaceCurrentItem(with: nil)
            if let observer = observers.removeValue(forKey: old.id) { NotificationCenter.default.removeObserver(observer) }
        }
        Task {
            // What the file itself says wins over what the notes of the camera said, or the pointer and the picture drift apart.
            if let loaded = try? await asset.load(.duration).seconds, loaded.isFinite, loaded > 0 {
                slot.duration = loaded
                if activeID == slot.id { scrub(slot) }
            }
        }
        return slot
    }

    /// Moves the picture to the pointer. A seek is only started when the last one is done, so fast mouse movements do not
    /// pile up, and the newest position is always the one that is arrived at.
    private func scrub(_ slot: Slot) {
        guard slot.duration > 0 else { return }
        seconds = slot.fraction * slot.duration
        if slot.isSeeking { slot.pending = slot.fraction; return }
        slot.isSeeking = true
        slot.player.pause()
        // Frame accurate: the picture is the one at the pointer, not the nearest keyframe.
        let time = CMTime(seconds: min(slot.fraction * slot.duration, max(0, slot.duration - 0.04)), preferredTimescale: 600)
        slot.player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            Task { @MainActor in
                slot.isSeeking = false
                if let next = slot.pending {
                    slot.pending = nil
                    slot.fraction = next
                    self?.scrub(slot)
                }
            }
        }
    }

    /// When the pointer has been still for a moment the clip plays on from there.
    private func rest(_ slot: Slot) {
        restTask?.cancel()
        guard !DebugFlags.holdHoverFrame else { return }
        restTask = Task {
            try? await Task.sleep(for: .milliseconds(650))
            guard !Task.isCancelled, activeID == slot.id, !slot.isSeeking else { return }
            slot.player.play()
            follow(slot)
        }
    }

    /// While a clip plays, the playhead is read from the player, so the line moves with the picture.
    private func follow(_ slot: Slot) {
        stopFollowing()
        let player = slot.player
        let token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.activeID == slot.id, slot.duration > 0, time.isNumeric else { return }
                self.playhead = min(1, max(0, time.seconds / slot.duration))
                self.seconds = time.seconds
            }
        }
        timeObserver = (player, token)
    }

    private func stopFollowing() {
        if let timeObserver { timeObserver.player.removeTimeObserver(timeObserver.token) }
        timeObserver = nil
    }
}

/// The picture of a hover preview. It has no background of its own and says when the first frame is on screen, so the
/// thumbnail stays visible until then and the cell never flashes black.
struct HoverSurface: NSViewRepresentable {
    let player: AVPlayer
    let onReady: (Bool) -> Void

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.onReady = onReady
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        view.onReady = onReady
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()
        var onReady: ((Bool) -> Void)?
        private var observation: NSKeyValueObservation?

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            playerLayer.videoGravity = .resizeAspectFill
            layer?.addSublayer(playerLayer)
            observation = playerLayer.observe(\.isReadyForDisplay, options: [.initial, .new]) { [weak self] layer, _ in
                let ready = layer.isReadyForDisplay
                Task { @MainActor in self?.onReady?(ready) }
            }
        }

        required init?(coder: NSCoder) { fatalError() }

        override func layout() {
            super.layout()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            playerLayer.frame = bounds
            CATransaction.commit()
        }
    }
}
