import RushesKit
import SwiftUI

/// The part of the review that is the same for a card and for a folder on the disk: the clips on the left, the picture on
/// the right, the details in the inspector pane of the window. What the person can do is in the toolbar above.
struct ReviewBody<Banner: View>: View {
    var model: ReviewModel
    var showUsage = false
    var onRequestDelete: (() -> Void)?
    @ViewBuilder var banner: Banner

    var body: some View {
        VStack(spacing: Space.m) {
            banner
            GeometryReader { geometry in
                // Two columns, and a third when the window is wide enough for three thumbnails that are still a good size.
                let gridWidth = geometry.size.width >= 1240 ? min(geometry.size.width * 0.38, 640) : max(340, min(geometry.size.width * 0.34, 460))
                HStack(alignment: .top, spacing: Space.xl) {
                    // The choice of what to show floats right over what it filters, in glass, and the list scrolls under it.
                    ZStack(alignment: .top) {
                        if model.visible.isEmpty {
                            EmptyState(
                                symbol: model.allItems.isEmpty ? "tray" : "line.3.horizontal.decrease.circle",
                                title: model.allItems.isEmpty ? "Nothing here" : "Nothing matches",
                                text: model.allItems.isEmpty ? "There are no clips or photos to look at." : "Change the filter above to see more."
                            )
                            .padding(.top, 52)
                        } else {
                            ClipGrid(model: model, showUsage: showUsage, topInset: 52)
                        }
                        GlassSegmented(
                            options: [(.all, "All"), (.video, "Video"), (.photo, "Photos")],
                            selection: Binding(get: { model.kindFilter }, set: { model.kindFilter = $0; model.refresh() })
                        )
                    }
                    .frame(width: gridWidth)
                    ViewerPanel(model: model, onRequestDelete: onRequestDelete)
                }
            }
        }
        .padding(.horizontal, Space.page)
        .padding(.top, Space.s)
        .padding(.bottom, Space.l)
        .confirmationDialog(
            model.pendingReset?.title ?? "",
            isPresented: Binding(get: { model.pendingReset != nil }, set: { if !$0 { model.pendingReset = nil } }),
            titleVisibility: .visible, presenting: model.pendingReset
        ) { request in
            Button("Reset \(request.items.count)", role: .destructive) { model.reset(request.items) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Keep, Leave out and the stars go back to nothing. Undo (Z) brings them back.")
        }
    }
}

extension ReviewBody where Banner == EmptyView {
    init(model: ReviewModel, showUsage: Bool = false, onRequestDelete: (() -> Void)? = nil) {
        self.init(model: model, showUsage: showUsage, onRequestDelete: onRequestDelete) { EmptyView() }
    }
}

// MARK: Toolbar

/// What goes in the toolbar of a review: the tools of the view, in one pill at the right. The system draws the glass.
struct ReviewToolbar: ToolbarContent {
    var model: ReviewModel

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            StateFilterMenu(model: model)
            if model.mode == .card { CardMoreMenu(model: model) }
            KeyHints(mode: model.mode)
            DetailsToggle()
        }
    }
}

extension ReviewModel {
    /// What goes under the title: how many the filter shows, and how far the looking has got.
    var progressText: String {
        var parts: [String] = []
        if visible.count != actionableCount { parts.append(String(localized: "\(visible.count) of \(actionableCount)")) }
        if enriching { parts.append(String(localized: "Looking at \(enrichDone) of \(allItems.count)")) }
        return parts.joined(separator: "  ·  ")
    }
}

private struct StateFilterMenu: View {
    var model: ReviewModel

    var body: some View {
        Menu {
            ForEach(states, id: \.self) { state in
                Button { model.stateFilter = state; model.refresh() } label: {
                    if model.stateFilter == state { Label(label(state), systemImage: "checkmark") } else { Text(label(state)) }
                }
            }
            Divider()
            Menu("Rating") {
                ratingButton(.any, title: "Any rating")
                ratingButton(.unrated, title: "Not rated")
                Divider()
                ForEach(1 ... 5, id: \.self) { stars in
                    ratingButton(.atLeast(stars), title: "\(String(repeating: "\u{2605}", count: stars)) or more")
                }
            }
            if model.mode == .card {
                Divider()
                Toggle("Show what was copied or left out before", isOn: Binding(get: { model.showKnown }, set: { model.showKnown = $0; model.refresh() }))
            }
        } label: {
            let active = model.stateFilter != .all || model.ratingFilter != .any
            Label("Filter", systemImage: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .help("Filter")
    }

    private func ratingButton(_ filter: ReviewRatingFilter, title: LocalizedStringKey) -> some View {
        Button { model.ratingFilter = filter; model.refresh() } label: {
            if model.ratingFilter == filter { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var states: [ReviewStateFilter] {
        model.mode == .card ? [.all, .undecided, .keep, .skip, .suggested, .notOnDisk, .onDisk]
            : [.all, .unused, .used, .protected, .leftOut, .duplicates, .undecided]
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
        case .notOnDisk: String(localized: "Not on the disk yet")
        case .onDisk: String(localized: "Already on the disk")
        case .leftOut: String(localized: "Left out on the card")
        }
    }
}

/// The actions that go with a card's review, one menu: leave out the suggestions, keep the rest, start over.
struct CardMoreMenu: View {
    var model: ReviewModel

    var body: some View {
        Menu {
            Button("Leave out all suggestions", systemImage: "wand.and.stars") { model.applySuggestions() }
                .disabled(model.counts().suggested == 0)
            Button("Keep everything not judged", systemImage: "checkmark.circle") { model.keepAllUndecided() }
            Divider()
            Button("Reset the selected (R)", systemImage: "arrow.uturn.backward.circle") { model.reset() }
                .disabled(model.targets.isEmpty)
            Button("Reset all choices...", systemImage: "arrow.counterclockwise") {
                let items = model.allItems.filter { model.isActionable($0) && (model.verdicts[$0.id] != nil || model.ratings[$0.id] != nil) }
                model.pendingReset = .init(title: String(localized: "Reset every choice and star on this card?"), items: items)
            }
        } label: {
            Label("More", systemImage: "ellipsis")
        }
        .help("More")
    }
}

/// Shows or hides the card of details under the picture. It is a toggle, so it can be seen whether it is on.
struct DetailsToggle: View {
    @AppStorage(PrefKey.showInspector) private var showDetails = true

    var body: some View {
        Toggle(isOn: $showDetails) {
            Label("Details", systemImage: showDetails ? "info.circle.fill" : "info.circle")
        }
        .toggleStyle(.button)
        .help("Details (I)")
    }
}

struct KeyHints: View {
    let mode: ReviewModel.Mode
    @LocalState private var shown = false

    var body: some View {
        Button { shown.toggle() } label: { Label("Keys", systemImage: "keyboard") }
            .help("Keys")
            .popover(isPresented: $shown) {
                Grid(alignment: .leading, horizontalSpacing: Space.l, verticalSpacing: Space.s) {
                    hint("← →  ↑ ↓", "Move through the clips")
                    hint("⏎", mode == .library ? "Protect from suggestions" : "Keep")
                    hint("X  ⌫", mode == .library ? "Move to the Trash" : "Leave out")
                    hint("1-5", "Stars")
                    hint("Space", "Play or pause")
                    hint("J  K  L", "Back, stop, forward (again for faster)")
                    hint(",  .", "One frame back or forward")
                    hint("[  ]", "Five seconds back or forward")
                    hint("Tab", "Next one not judged")
                    hint("Z", "Undo")
                    hint("R", "Reset the choice and the stars")
                    hint("U", "Clear the choice, keep the stars")
                    hint("M", "Sound on or off")
                    hint("C", "LUT on or off")
                    hint("=  -  \u{2318}0", "Zoom in or out")
                    hint("I", "Details on or off")
                    hint("⇧ click, ⌘ click", "Select several")
                    hint("Click a day", "Select the whole day")
                }
                .padding(Space.l)
            }
    }

    private func hint(_ keys: String, _ text: LocalizedStringKey) -> some View {
        GridRow {
            Text(keys).font(.system(size: 12, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
            Text(text).font(.callout)
        }
    }
}

// MARK: Banner

/// One line above the clips that says something about all of them, with the one thing to do about it.
struct InfoBanner<Actions: View>: View {
    let symbol: String
    var tint: Color = Palette.accent
    let text: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: symbol).foregroundStyle(tint).font(.system(size: 15, weight: .semibold))
            Text(text).font(.callout).lineLimit(2)
            Spacer(minLength: Space.m)
            actions
        }
        .padding(.horizontal, Space.l)
        .padding(.vertical, Space.m)
        .surface(radius: Metrics.card)
    }
}

struct SuggestionBanner: View {
    var model: ReviewModel

    var body: some View {
        let suggested = model.counts().suggested
        if suggested > 0 {
            InfoBanner(
                symbol: "wand.and.stars", tint: VerdictStyle.hint,
                text: String(localized: "\(suggested) look unneeded: black, very short, out of focus or near copies")
            ) {
                Button("Show") { model.stateFilter = .suggested; model.refresh() }
                    .buttonStyle(.bordered)
                Button("Leave them out") { model.applySuggestions() }
                    .buttonStyle(.borderedProminent)
                    .tint(VerdictStyle.hint)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

// MARK: Details

/// What is known about the clip in view: the usage in DaVinci Resolve first, then the camera, in two columns so it stays short.
struct DetailsCard: View {
    var model: ReviewModel
    let item: MediaItem

    var body: some View {
        let meta = model.metadata[item.id]
        VStack(alignment: .leading, spacing: Space.m) {
            // Which clip it is and when it was shot: this stood over the picture and covered it.
            VStack(alignment: .leading, spacing: 2) {
                Text(item.name).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                Text(model.date(of: item).formatted(date: .complete, time: .shortened)).font(.callout).foregroundStyle(.secondary)
            }
            Divider()
            if model.mode == .library, let usage = model.usage[item.id] {
                UsageList(usage: usage)
                Divider()
            }
            LazyVGrid(
                // Three across when the card is wide, so it takes two rows instead of three and the picture keeps its height.
                columns: [GridItem(.adaptive(minimum: 160), alignment: .topLeading)],
                alignment: .leading, spacing: Space.m
            ) {
                cell("Camera", meta?.camera)
                cell("Lens", meta?.lens)
                cell("Format", [meta?.codec, meta?.resolution, meta?.frameRateText].compactMap { $0 }.joined(separator: " · "))
                if item.kind == .photo {
                    cell("Exposure", [meta?.shutter, meta?.aperture.map { "f/\(String(format: "%g", $0))" }, meta?.iso.map { "ISO \($0)" }]
                        .compactMap { $0 }.joined(separator: " · "))
                } else {
                    cell("Picture profile", meta?.gamma)
                }
                cell("Size", Format.bytes(item.totalBytes) + (item.kind == .video && meta?.duration != nil ? " · " + Format.duration(meta?.duration) : ""))
                cell("File", item.primary.rel)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(radius: Metrics.card)
    }

    @ViewBuilder
    private func cell(_ title: LocalizedStringKey, _ value: String?) -> some View {
        if let value, !value.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
            }
        }
    }
}
