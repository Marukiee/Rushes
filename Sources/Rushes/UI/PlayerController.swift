import AVFoundation
import AppKit
import CoreImage
import RushesKit
import SwiftUI

/// Plays one clip at a time for the review: starts quickly, loops, shuttles with J K L and can show the clip through a LUT.
@MainActor
@Observable
final class PlayerController {
    let player = AVPlayer()
    private(set) var currentTime: Double = 0
    private(set) var duration: Double = 0
    private(set) var isPlaying = false
    private(set) var rate: Float = 0
    private(set) var lutName: String?
    private(set) var failed: String?
    /// Width over height of what is playing, as soon as the player knows it, so the picture can be shown without black bars.
    private(set) var videoAspect: CGFloat?
    var muted: Bool {
        didSet { player.isMuted = muted }
    }

    nonisolated(unsafe) private var timeObserver: Any?
    nonisolated(unsafe) private var endObserver: NSObjectProtocol?
    private var statusObservation: NSKeyValueObservation?
    private var sizeObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var loops = true
    private var loadID = 0
    private var lutCache: [URL: CubeLUT] = [:]
    private var builtIn: CubeLUT?

    init() {
        muted = !Prefs.bool(PrefKey.soundOn)
        player.isMuted = muted
        player.actionAtItemEnd = .pause
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1.0 / 20.0, preferredTimescale: 600), queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self, time.isNumeric else { return }
                self.currentTime = time.seconds
            }
        }
        rateObservation = player.observe(\.rate, options: [.new]) { [weak self] player, _ in
            Task { @MainActor in
                self?.rate = player.rate
                self?.isPlaying = player.rate != 0
            }
        }
    }

    deinit {
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
    }

    // MARK: Loading

    func load(url: URL, lutURL: URL?, useLUT: Bool, isLog: Bool, autoplay: Bool, loop: Bool) async {
        loadID += 1
        let current = loadID
        failed = nil
        videoAspect = nil
        currentTime = 0
        duration = 0
        loops = loop
        player.pause()

        let asset = AVURLAsset(url: url)
        let item = AVPlayerItem(asset: asset)
        item.audioTimePitchAlgorithm = .timeDomain

        var applied: String?
        if useLUT, let lut = lut(from: lutURL, isLog: isLog) {
            if let composition = try? await Self.composition(for: asset, lut: lut.lut) {
                item.videoComposition = composition
                applied = lut.name
            }
        }
        guard current == loadID else { return }
        lutName = applied

        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.loops {
                    self.player.seek(to: .zero) { _ in self.player.play() }
                } else {
                    self.isPlaying = false
                }
            }
        }
        statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            Task { @MainActor in
                guard let self, current == self.loadID else { return }
                if item.status == .failed { self.failed = item.error?.localizedDescription ?? String(localized: "This clip cannot be played") }
            }
        }
        sizeObservation = item.observe(\.presentationSize, options: [.initial, .new]) { [weak self] item, _ in
            let size = item.presentationSize
            guard size.width > 1, size.height > 1 else { return }
            Task { @MainActor in
                guard let self, current == self.loadID else { return }
                self.videoAspect = size.width / size.height
            }
        }
        player.replaceCurrentItem(with: item)
        if let seconds = try? await asset.load(.duration).seconds, seconds.isFinite, current == loadID { duration = seconds }
        if autoplay { player.play() }
    }

    private func lut(from url: URL?, isLog: Bool) -> (lut: CubeLUT, name: String)? {
        switch Prefs.lutMode {
        case .off:
            return nil
        case .auto:
            if let url {
                if let cached = lutCache[url] { return (cached, url.deletingPathExtension().lastPathComponent) }
                if let parsed = try? CubeLUT.parse(url) {
                    lutCache[url] = parsed
                    return (parsed, url.deletingPathExtension().lastPathComponent)
                }
            }
            return isLog ? (builtInLUT(), "S-Log3") : nil
        case .builtIn:
            return isLog ? (builtInLUT(), "S-Log3") : nil
        }
    }

    private func builtInLUT() -> CubeLUT {
        if let builtIn { return builtIn }
        let made = CubeLUT.sLog3Preview()
        builtIn = made
        return made
    }

    private nonisolated static func composition(for asset: AVAsset, lut: CubeLUT) async throws -> AVVideoComposition {
        guard let filter = lut.filter() else { throw CocoaError(.featureUnsupported) }
        let lock = NSLock()
        return try await AVVideoComposition.videoComposition(with: asset) { request in
            lock.lock()
            defer { lock.unlock() }
            filter.setValue(request.sourceImage.clampedToExtent(), forKey: kCIInputImageKey)
            let output = filter.outputImage?.cropped(to: request.sourceImage.extent) ?? request.sourceImage
            request.finish(with: output, context: nil)
        }
    }

    func unload() {
        loadID += 1
        videoAspect = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        currentTime = 0
        duration = 0
        lutName = nil
    }

    // MARK: Transport

    func togglePlay() {
        if isPlaying { player.pause() } else {
            if duration > 0, currentTime >= duration - 0.05 { player.seek(to: .zero) }
            player.play()
        }
    }

    func pause() { player.pause() }

    func seek(to seconds: Double) {
        let target = CMTime(seconds: min(max(0, seconds), max(duration, 0)), preferredTimescale: 600)
        currentTime = target.seconds
        player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func step(frames: Int) {
        player.pause()
        player.currentItem?.step(byCount: frames)
    }

    func skip(seconds: Double) { seek(to: currentTime + seconds) }

    /// L and J: each press goes faster in that direction, K stops.
    func shuttle(forward: Bool) {
        let speeds: [Float] = [1, 2, 4, 8]
        if forward {
            let next = rate > 0 ? (speeds.first { $0 > rate } ?? speeds.last!) : 1
            player.rate = next
        } else {
            let next: Float = rate < 0 ? (speeds.first { -$0 < rate } ?? speeds.last!) : 1
            player.rate = -next
        }
    }
}

/// The picture of the player, without controls of its own: the controls are drawn over it as glass.
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> LayerView {
        let view = LayerView()
        view.playerLayer.player = player
        return view
    }

    func updateNSView(_ view: LayerView, context: Context) {
        if view.playerLayer.player !== player { view.playerLayer.player = player }
    }

    final class LayerView: NSView {
        let playerLayer = AVPlayerLayer()

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer = CALayer()
            playerLayer.videoGravity = .resizeAspect
            playerLayer.backgroundColor = NSColor.black.cgColor
            layer?.addSublayer(playerLayer)
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
