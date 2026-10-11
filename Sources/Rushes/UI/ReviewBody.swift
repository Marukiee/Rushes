import RushesKit
import SwiftUI

/// The part of the review that is the same for a card and for a folder on the disk: filters on top, the grid on the left,
/// the big picture on the right.
struct ReviewBody: View {
    var model: ReviewModel
    var showUsage = false
    var onRequestDelete: (() -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            FilterBar(model: model)
            if model.mode == .card { SuggestionBanner(model: model) }
            GeometryReader { geometry in
                let gridWidth = max(330, min(geometry.size.width * 0.44, 560))
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if model.visible.isEmpty {
                            EmptyState(
                                symbol: model.allItems.isEmpty ? "tray" : "line.3.horizontal.decrease.circle",
                                title: model.allItems.isEmpty ? "Nothing here" : "Nothing matches",
                                text: model.allItems.isEmpty ? "There are no clips or photos to look at." : "Change the filter above to see more."
                            )
                        } else {
                            ClipGrid(model: model, showUsage: showUsage)
                        }
                    }
                    .frame(width: gridWidth)
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                    ViewerPanel(model: model, onRequestDelete: onRequestDelete)
                        .padding(.trailing, 20)
                }
                .padding(.leading, 6)
            }
        }
        .padding(.bottom, 14)
    }
}

private struct FilterBar: View {
    var model: ReviewModel

    var body: some View {
        HStack(spacing: 10) {
            Picker("Kind", selection: Binding(get: { model.kindFilter }, set: { model.kindFilter = $0; model.refresh() })) {
                Text("All").tag(ReviewKindFilter.all)
                Text("Video").tag(ReviewKindFilter.video)
                Text("Photos").tag(ReviewKindFilter.photo)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 210)

            Menu {
                ForEach(states, id: \.self) { state in
                    Button { model.stateFilter = state; model.refresh() } label: {
                        if model.stateFilter == state { Label(label(state), systemImage: "checkmark") } else { Text(label(state)) }
                    }
                }
                if model.mode == .card {
                    Divider()
                    Toggle("Show what was copied before", isOn: Binding(get: { model.showKnown }, set: { model.showKnown = $0; model.refresh() }))
                }
            } label: {
                Label(label(model.stateFilter), systemImage: "line.3.horizontal.decrease")
                    .font(.callout.weight(.medium))
            }
            .menuStyle(.button)
            .glassButtonStyle()

            Text("\(model.visible.count) of \(model.actionableCount)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())

            if model.enriching {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Looking at \(model.enrichDone) of \(model.allItems.count)")
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                .transition(.opacity)
            }
            Spacer(minLength: 0)
            if model.mode == .card {
                Menu {
                    Button("Leave out all suggestions", systemImage: "wand.and.stars") { model.applySuggestions() }
                        .disabled(model.counts().suggested == 0)
                    Button("Keep everything not judged", systemImage: "checkmark.circle") { model.keepAllUndecided() }
                    Divider()
                    Button("Clear all choices", systemImage: "arrow.counterclockwise") { model.clearAll() }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.button)
                .glassButtonStyle()
                .menuIndicator(.hidden)
            }
            KeyHints(mode: model.mode)
        }
        .padding(.horizontal, 20)
        .padding(.top, 4)
        .animation(.rushes, value: model.enriching)
    }

    private var states: [ReviewStateFilter] {
        model.mode == .card ? [.all, .undecided, .keep, .skip, .suggested] : [.all, .unused, .used, .protected, .duplicates, .undecided]
    }

    private func label(_ state: ReviewStateFilter) -> String {
        switch state {
        case .all: String(localized: "Everything")
        case .undecided: String(localized: "Not judged yet")
        case .keep: model.mode == .library ? String(localized: "Protected") : String(localized: "Kept")
        case .skip: String(localized: "Left out")
        case .suggested: String(localized: "Suggested to leave out")
        case .unused: String(localized: "Not used in DaVinci")
        case .used: String(localized: "Used in DaVinci")
        case .protected: String(localized: "Protected")
        case .duplicates: String(localized: "Copies of each other")
        }
    }
}

private struct KeyHints: View {
    let mode: ReviewModel.Mode
    @LocalState private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Image(systemName: "keyboard")
        }
        .glassButtonStyle()
        .popover(isPresented: $shown) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
                hint("← →  ↑ ↓", "Move through the clips")
                hint("⏎", mode == .library ? "Protect from suggestions" : "Keep")
                hint("X  ⌫", mode == .library ? "Move to the Trash" : "Leave out")
                hint("1 – 5", "Stars")
                hint("Space", "Play or pause")
                hint("J  K  L", "Back, stop, forward (again for faster)")
                hint(",  .", "One frame back or forward")
                hint("[  ]", "Five seconds back or forward")
                hint("Tab", "Next one not judged")
                hint("Z", "Undo")
                hint("U", "Clear the choice")
                hint("M", "Sound on or off")
                hint("I", "Details on or off")
                hint("⇧ click, ⌘ click", "Select several")
            }
            .padding(16)
        }
    }

    private func hint(_ keys: String, _ text: LocalizedStringKey) -> some View {
        GridRow {
            Text(keys).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }
}

private struct SuggestionBanner: View {
    var model: ReviewModel

    var body: some View {
        let suggested = model.counts().suggested
        if suggested > 0 {
            HStack(spacing: 12) {
                Image(systemName: "wand.and.stars").foregroundStyle(VerdictStyle.hint)
                Text("\(suggested) look unneeded: black, very short, out of focus or near copies")
                    .font(.callout)
                Spacer(minLength: 8)
                Button("Show") { model.stateFilter = .suggested; model.refresh() }
                    .glassButtonStyle()
                Button("Leave them out") { model.applySuggestions() }
                    .prominentButtonStyle()
                    .tint(VerdictStyle.hint)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .rushesGlass(.capsule)
            .padding(.horizontal, 20)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
