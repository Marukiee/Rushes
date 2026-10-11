import SwiftUI

// MARK: Surfaces

/// A card of content on a plain surface. Glass is for what floats above the content
/// (the toolbar, controls, the toast), never for the content itself.
struct Card<Content: View>: View {
    var radius: CGFloat = Metrics.card
    var padding: CGFloat = 20
    var tint: Color?
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .surface(radius: radius, tint: tint)
    }
}

struct SectionTitle: View {
    let text: LocalizedStringKey
    var detail: String?

    init(_ text: LocalizedStringKey, detail: String? = nil) {
        self.text = text
        self.detail = detail
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(text).font(.title3.weight(.semibold))
            if let detail {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

/// A button with a symbol, in the system's own styles: filled for the main action of a card, plain bordered for the others.
private struct FloatingPanelKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// True inside the little card in the corner of the screen. A panel that is not the key window draws the system's
    /// filled buttons in grey, as if they were off, so there the buttons draw themselves.
    var inFloatingPanel: Bool {
        get { self[FloatingPanelKey.self] }
        set { self[FloatingPanelKey.self] = newValue }
    }
}

/// A capsule button that looks the same whether or not its window is the key one.
struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    var tint: Color = Palette.indigo

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .padding(.horizontal, Space.l)
            .frame(height: 38)
            .background(prominent ? AnyShapeStyle(tint) : AnyShapeStyle(Color.primary.opacity(0.10)), in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? pressedScale : 1)
            .animation(.rushesBouncy, value: configuration.isPressed)
    }
}

struct ActionButton: View {
    @Environment(\.inFloatingPanel) private var floating
    let title: LocalizedStringKey
    let symbol: String
    var prominent = false
    var tint: Color = Palette.indigo
    /// Takes the width it is given, so buttons side by side come out the same size.
    var wide = false
    let action: () -> Void

    var body: some View {
        let button = Button(action: action) {
            Label(title, systemImage: symbol)
                .lineLimit(1)
                .minimumScaleFactor(wide ? 0.8 : 1)
                // A button is as wide as its words. A row that does not fit wraps or stacks (see ButtonRow), it never cuts one off.
                .fixedSize(horizontal: !wide, vertical: false)
                .frame(maxWidth: wide ? .infinity : nil)
        }
        if floating {
            button.buttonStyle(CapsuleButtonStyle(prominent: prominent, tint: tint))
        } else if prominent {
            button.buttonStyle(.borderedProminent).tint(tint).buttonBorderShape(.capsule).controlSize(.large)
        } else {
            button.buttonStyle(.bordered).buttonBorderShape(.capsule).controlSize(.large)
        }
    }
}

/// The disc under an icon: one round glass button shape for every small icon action, so none looks different from its neighbours.
struct RoundIconDisc: View {
    let symbol: String
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: size, height: size)
            .rushesGlass(Circle(), interactive: true)
            .contentShape(Circle())
    }
}

struct RoundIconButton: View {
    let symbol: String
    let help: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) { RoundIconDisc(symbol: symbol) }
            .buttonStyle(.bouncy)
            .help(help)
    }
}

struct RoundIconMenu<Content: View>: View {
    let symbol: String
    let help: LocalizedStringKey
    @ViewBuilder var content: Content

    var body: some View {
        Menu { content } label: { RoundIconDisc(symbol: symbol) }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .buttonStyle(.bouncy)
            .help(help)
    }
}

/// A choice between a few things, in Liquid Glass: a glass track with one lens of glass that slides to the chosen part, and
/// can be dragged. Track and lens are in one glass container, so they melt into each other like the system's own controls.
struct GlassSegmented<Value: Hashable>: View {
    let options: [(value: Value, title: LocalizedStringKey)]
    @Binding var selection: Value
    var height: CGFloat = 40

    private let inset: CGFloat = 4

    private var selectedIndex: Int { options.firstIndex { $0.value == selection } ?? 0 }

    var body: some View {
        GeometryReader { geometry in
            let segment = (geometry.size.width - inset * 2) / CGFloat(max(options.count, 1))
            ZStack(alignment: .leading) {
                track
                // One lens, moved, not drawn again somewhere else: that is what makes it slide.
                lens(width: segment, height: geometry.size.height - inset * 2)
                    .offset(x: inset + segment * CGFloat(selectedIndex))
                HStack(spacing: 0) {
                    ForEach(options.indices, id: \.self) { index in
                        Text(options[index].title)
                            .font(.callout.weight(index == selectedIndex ? .semibold : .medium))
                            .foregroundStyle(index == selectedIndex ? Color.primary : Color.secondary)
                            .lineLimit(1)
                            .frame(width: segment, height: geometry.size.height)
                    }
                }
                .padding(.horizontal, inset)
            }
            .contentShape(Capsule())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { value in
                    let index = min(options.count - 1, max(0, Int((value.location.x - inset) / segment)))
                    guard options[index].value != selection else { return }
                    withAnimation(.spring(response: 0.38, dampingFraction: 0.8)) { selection = options[index].value }
                }
            )
        }
        .frame(height: height)
        .accessibilityRepresentation {
            Picker("", selection: $selection) {
                ForEach(options.indices, id: \.self) { Text(options[$0].title).tag(options[$0].value) }
            }
            .pickerStyle(.segmented)
        }
    }

    @ViewBuilder
    private var track: some View {
        if DebugFlags.flatGlass {
            Capsule().fill(Color.primary.opacity(0.06))
        } else {
            Color.clear.glassEffect(.regular, in: Capsule())
        }
    }

    @ViewBuilder
    private func lens(width: CGFloat, height: CGFloat) -> some View {
        if DebugFlags.flatGlass {
            Capsule().fill(Color.primary.opacity(0.14)).frame(width: width, height: height)
        } else {
            // A little of the text colour under the glass, so the chosen part reads in a light window as well as a dark one.
            Capsule().fill(Color.primary.opacity(0.08))
                .frame(width: width, height: height)
                .glassEffect(.regular.interactive(), in: Capsule())
        }
    }
}

/// Buttons in a row when they fit, one under the other when they do not. Never a label cut off.
struct ButtonRow<Content: View>: View {
    var spacing: CGFloat = 10
    @ViewBuilder var content: Content

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: spacing) { content }
            VStack(spacing: spacing) { content }
        }
    }
}

// MARK: Small pieces

struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 10, weight: .bold)) }
            Text(text).font(.caption.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

/// A key as drawn on a keyboard, for the hints next to buttons.
struct KeyCap: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(minWidth: 20)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(Color.primary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(Color.primary.opacity(0.10), lineWidth: 1) }
    }
}

struct ProgressCapsule: View {
    let fraction: Double
    var tint: Color = Palette.indigo

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule()
                    .fill(tint.gradient)
                    .frame(width: max(6, proxy.size.width * min(1, max(0, fraction))))
                    .animation(.rushes, value: fraction)
            }
        }
    }
}

/// A turning pill for anything that is loading, the same shape as the one in the icon.
struct PillSpinner: View {
    var size: CGFloat = 28
    var tint: Color = Palette.indigo

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let cycle = 2.6
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycle) / cycle
            let turn: Double = t < 0.42 ? ease(t / 0.42) : (t < 0.5 ? 1 : (t < 0.92 ? 1 + ease((t - 0.5) / 0.42) : 2))
            Capsule()
                .fill(tint.gradient)
                .frame(width: size * 0.42, height: size)
                .rotationEffect(.degrees(turn * 180 - 32))
        }
        .frame(width: size, height: size)
    }

    private func ease(_ x: Double) -> Double {
        x < 0.5 ? 4 * x * x * x : 1 - pow(-2 * x + 2, 3) / 2
    }
}

/// The toast floats over the content, so it is glass.
struct ToastView: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout.weight(.medium))
            .padding(.horizontal, 18)
            .padding(.vertical, 11)
            .rushesGlass(.capsule)
            .shadow(color: .black.opacity(0.12), radius: 14, y: 6)
    }
}

struct HelpTip: View {
    let text: LocalizedStringKey
    @LocalState private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "questionmark.circle").foregroundStyle(.secondary)
        }
        .buttonStyle(.bouncy)
        .popover(isPresented: $shown) {
            Text(text).font(.callout).padding(14).frame(width: 280, alignment: .leading)
        }
    }
}

struct EmptyState: View {
    let symbol: String
    let title: LocalizedStringKey
    let text: LocalizedStringKey
    var tint: Color = Palette.indigo

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 76, height: 76)
                .background(tint.opacity(0.12), in: .circle)
            Text(title).font(.title3.weight(.semibold))
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(30)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A big number with a name and a line under it.
struct StatTile: View {
    let title: LocalizedStringKey
    let value: String
    var detail: String?
    var symbol: String
    var tint: Color = Palette.indigo

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 42, height: 42)
                .background(tint.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.title2.weight(.bold).monospacedDigit()).contentTransition(.numericText())
                if let detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Metrics.card)
    }
}

/// How full a disk is, with the part that could be freed marked.
struct StorageBar: View {
    let capacity: UInt64
    let used: UInt64
    var reclaimable: UInt64 = 0

    var body: some View {
        GeometryReader { proxy in
            let total = Double(max(capacity, 1))
            let usedWidth = proxy.size.width * min(1, Double(used) / total)
            let reclaimWidth = proxy.size.width * min(1, Double(min(reclaimable, used)) / total)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Palette.indigo.gradient).frame(width: max(6, usedWidth))
                if reclaimWidth > 3 {
                    Capsule().fill(Palette.rose.gradient).frame(width: reclaimWidth)
                        .offset(x: max(0, usedWidth - reclaimWidth))
                }
            }
        }
        .frame(height: 10)
        .animation(.rushes, value: used)
    }
}

extension View {
    /// A pointer cursor over something that can be clicked.
    func clickable() -> some View {
        onHover { inside in
            if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
        }
    }
}

/// Views side by side, each as wide as it needs to be, on to the next line when the row is full.
struct WrapRow: Layout {
    var spacing: CGFloat = 10

    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func lines(_ subviews: Subviews, fitting width: CGFloat) -> [Line] {
        var result: [Line] = [Line()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = (result[result.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if !result[result.count - 1].indices.isEmpty, result[result.count - 1].width + needed > width {
                result.append(Line())
            }
            let first = result[result.count - 1].indices.isEmpty
            result[result.count - 1].width += (first ? 0 : spacing) + size.width
            result[result.count - 1].height = max(result[result.count - 1].height, size.height)
            result[result.count - 1].indices.append(index)
        }
        return result
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let rows = lines(subviews, fitting: width)
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width.isFinite ? width : (rows.map(\.width).max() ?? 0), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(subviews, fitting: bounds.width) {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (line.height - size.height) / 2), anchor: .topLeading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }
}

enum Format {
    /// "1 clip" and "2 clips": the app speaks two languages and neither has a rule the system fills in.
    static func count(_ number: Int, one: String, other: String) -> String {
        "\(number) " + (number == 1 ? one : other)
    }

    static func duration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    static func timecode(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00.0" }
        let total = Int(seconds)
        let tenth = Int((seconds - Double(total)) * 10)
        return String(format: "%d:%02d.%d", total / 60, total % 60, tenth)
    }

    static func bytes(_ count: UInt64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: Int64(count))
    }

    static func day(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.wide).day().month(.wide).year())
    }

    static func shortDay(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year())
    }

    static func shortDate(_ date: Date) -> String {
        date.formatted(.dateTime.day().month(.abbreviated).year())
    }

    static func remaining(_ seconds: TimeInterval?) -> String {
        guard let seconds, seconds.isFinite else { return "" }
        if seconds < 60 { return String(localized: "less than a minute left") }
        let minutes = Int((seconds / 60).rounded())
        return String(localized: "about \(minutes) min left")
    }
}
