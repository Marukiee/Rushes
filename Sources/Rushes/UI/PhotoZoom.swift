import AppKit
import ImageIO
import RushesKit
import SwiftUI

/// How far a photo in the viewer is zoomed in and where it is moved to. Shared by the picture, which is pinched, scrolled and
/// dragged, and by the keys, so both move the same thing.
@MainActor
@Observable
final class PhotoZoom {
    static let most: CGFloat = 8

    private(set) var scale: CGFloat = 1
    private(set) var offset: CGSize = .zero
    /// The size of the picture on screen, to zoom from the middle when a key is used.
    var viewSize: CGSize = .zero {
        // The next photo can have another shape: the spot that was zoomed into stays the same part of the picture.
        didSet {
            guard oldValue.width > 0, oldValue.height > 0, viewSize != oldValue else { return }
            offset = CGSize(width: offset.width * viewSize.width / oldValue.width, height: offset.height * viewSize.height / oldValue.height)
            clamp()
        }
    }

    var isZoomed: Bool { scale > 1.01 }

    /// The zoom of the photo in view, for the scripted runs of the debug build.
    nonisolated(unsafe) static weak var current: PhotoZoom?

    func reset() {
        scale = 1
        offset = .zero
    }

    /// Zooms by a factor, keeping the point under the pointer where it is, the way every photo viewer does.
    func zoom(by factor: CGFloat, at point: CGPoint? = nil) {
        let anchor = point ?? CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let next = min(Self.most, max(1, scale * factor))
        let center = CGPoint(x: viewSize.width / 2, y: viewSize.height / 2)
        let ratio = next / scale
        let dx = anchor.x - center.x, dy = anchor.y - center.y
        offset = CGSize(width: dx - (dx - offset.width) * ratio, height: dy - (dy - offset.height) * ratio)
        scale = next
        clamp()
    }

    /// From fitting to a closer look at the clicked spot, and back.
    func toggle(at point: CGPoint) {
        if isZoomed { reset() } else { zoom(by: 2.5, at: point) }
    }

    func pan(by delta: CGSize) {
        offset = CGSize(width: offset.width + delta.width, height: offset.height + delta.height)
        clamp()
    }

    func setPan(_ value: CGSize) {
        offset = value
        clamp()
    }

    /// The picture fills its frame, so it can move until its edge reaches the edge of the frame and no further.
    private func clamp() {
        let maxX = viewSize.width * (scale - 1) / 2, maxY = viewSize.height * (scale - 1) / 2
        offset = CGSize(width: min(maxX, max(-maxX, offset.width)), height: min(maxY, max(-maxY, offset.height)))
        if scale <= 1.001 { scale = 1; offset = .zero }
    }
}

/// A photo that can be zoomed: pinch, scroll with a mouse (or with Command on a trackpad), double click, and drag to move.
struct ZoomablePhoto: View {
    let image: CGImage
    var zoom: PhotoZoom

    @LocalState private var pinchStart: CGFloat?
    @LocalState private var dragStart: CGSize?
    @LocalState private var pointer: CGPoint?
    @LocalState private var monitor: Any?

    var body: some View {
        GeometryReader { geometry in
            Image(decorative: image, scale: 1)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .scaleEffect(zoom.scale)
                .offset(zoom.offset)
                .frame(width: geometry.size.width, height: geometry.size.height)
                .clipped()
                .contentShape(Rectangle())
                .onAppear { zoom.viewSize = geometry.size; PhotoZoom.current = zoom }
                .onChange(of: geometry.size) { _, size in zoom.viewSize = size }
                .onContinuousHover { phase in
                    if case let .active(point) = phase { pointer = point } else { pointer = nil }
                }
                .gesture(
                    MagnifyGesture()
                        .onChanged { value in
                            let start = pinchStart ?? zoom.scale
                            if pinchStart == nil { pinchStart = start }
                            zoom.zoom(by: start * value.magnification / zoom.scale, at: value.startLocation)
                        }
                        .onEnded { _ in pinchStart = nil }
                )
                .simultaneousGesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            guard zoom.isZoomed else { return }
                            let start = dragStart ?? zoom.offset
                            if dragStart == nil { dragStart = start }
                            zoom.setPan(CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height))
                        }
                        .onEnded { _ in dragStart = nil }
                )
                .simultaneousGesture(
                    SpatialTapGesture(count: 2).onEnded { value in
                        withAnimation(.rushes) { zoom.toggle(at: value.location) }
                    }
                )
                .overlay(alignment: .bottom) {
                    if zoom.isZoomed {
                        Button { withAnimation(.rushes) { zoom.reset() } } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "arrow.down.right.and.arrow.up.left").font(.system(size: 10, weight: .bold))
                                Text(verbatim: "\(Int((zoom.scale * 100).rounded()))%").font(.caption.weight(.semibold).monospacedDigit())
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .rushesVideoGlass(.capsule)
                        }
                        .buttonStyle(.bouncy)
                        .help("Fit the photo (Z)")
                        .padding(12)
                        .transition(.opacity)
                    }
                }
                .animation(.rushesFade, value: zoom.isZoomed)
        }
        .onAppear(perform: installScroll)
        .onDisappear(perform: removeScroll)
    }

    /// SwiftUI has no scroll wheel gesture, so the scroll events over the photo are read here: a mouse wheel or Command with a
    /// trackpad zooms, a plain trackpad scroll moves a zoomed photo and otherwise is left alone.
    private func installScroll() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { event in
            guard let point = pointer else { return event }
            let command = event.modifierFlags.contains(.command)
            if event.hasPreciseScrollingDeltas && !command {
                guard zoom.isZoomed else { return event }
                zoom.pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
                return nil
            }
            let step = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY * 0.01 : event.scrollingDeltaY * 0.08
            guard step != 0 else { return nil }
            zoom.zoom(by: max(0.5, min(1.6, 1 + step)), at: point)
            return nil
        }
    }

    private func removeScroll() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }
}

enum FullPhoto {
    /// The whole photo at its own size, for looking closely. A raw file is developed by the system, its JPEG twin is quicker.
    static func load(_ item: MediaItem, root: URL) async -> CGImage? {
        let pair = item.companions.first { $0.role == .pair && !MediaTypes.raw.contains($0.entry.ext) }
        let url = root.appendingPathComponent(pair?.entry.rel ?? item.primary.rel)
        return await Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 12000,
            ]
            return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        }.value
    }
}
