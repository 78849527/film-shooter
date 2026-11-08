import SwiftUI

// MARK: - Carousel

/// The horizontal positions of carousel cards in iOS 16's scroll view.
private struct LegacyFilmCenterPreference: PreferenceKey {
    static var defaultValue: [String: CGFloat] { [:] }
    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}


/// A snapping, horizontally scrolling row of film canisters. The centred roll
/// is full size; the others shrink and fade with their distance from the
/// centre (pure transforms: no layout, no offscreen passes, so it holds
/// 60/120 fps). A small amber notch marks the centre.
struct FilmCarousel: View {
    enum Style: Equatable {
        case hero, compact

        var cardHeight: CGFloat { self == .hero ? 60 : 44 }
        var gap: CGFloat { 6 }
        var shrink: CGFloat { self == .hero ? 0.24 : 0.2 }
        var height: CGFloat { cardHeight + 14 }
    }

    let style: Style
    /// Editor: only show the film stocks belonging to the applied category.
    /// Camera: pass the full catalog to preserve existing capture UI.
    let films: [FilmStock]
    @Binding var centeredID: String?
    let onTap: (String) -> Void
    /// The scroll came to rest. Pass the exact selected film ID rather than
    /// waiting for SwiftUI's @State centeredID to be applied next frame.
    let onSettle: (String) -> Void
    /// In the darkroom, calculate a swipe from its gesture translation,
    /// independently of delayed iOS 16 ScrollView geometry Preferences.
    var deterministicSwipe: Bool = false
    /// Prevent stale iOS 16 geometry from overwriting a category selection
    /// while ScrollViewReader moves to the requested film.
    var programmaticTarget: String?
    var programmaticUntil: Date = .distantPast
    var onUserDrag: () -> Void = {}
    @State private var legacyDragging = false
    @State private var gestureOriginID: String?

    var body: some View {
        GeometryReader { geo in
            if #available(iOS 18.0, *) {
            let viewport = geo.size.width
            let cardWidth = FilmCanister.width(forHeight: style.cardHeight)
            let step = cardWidth + style.gap
            let shrink = style.shrink
            ScrollViewReader { proxy in
                ScrollView(.horizontal) {
                    LazyHStack(spacing: style.gap) {
                        ForEach(films) { film in
                            card(film, width: cardWidth)
                                .id(film.id)
                                .visualEffect { content, proxy in
                                    // Distance from the visible centre, measured in the
                                    // card's own space against the scroll view's visible
                                    // bounds: independent of content margins.
                                    let visible = proxy.bounds(of: .scrollView(axis: .horizontal))
                                        ?? CGRect(x: 0, y: 0, width: viewport, height: 0)
                                    let d = (proxy.size.width / 2 - visible.midX) / step
                                    let t = abs(d)
                                    let k = min(t, 1)
                                    let scale = 1 - shrink * k
                                    // Pull scaled cards in so the gaps stay even.
                                    let h = t < 1 ? t * t / 2 : t - 0.5
                                    let dx: CGFloat = (d < 0 ? 1 : -1) * cardWidth * shrink * h
                                    let fade = 1 - 0.25 * k - 0.35 * min(max(t - 1, 0), 1)
                                    return content
                                        .scaleEffect(scale)
                                        .offset(x: dx)
                                        .opacity(Double(fade))
                                }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .contentMargins(.horizontal, max(0, (viewport - cardWidth) / 2), for: .scrollContent)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .never))
                .scrollPosition(id: $centeredID, anchor: .center)
                .onScrollPhaseChange { _, phase in
                    if phase == .idle, let id = centeredID { onSettle(id) }
                }
                .onAppear {
                    if let id = centeredID { proxy.scrollTo(id, anchor: .center) }
                }
                .task {
                    // Once more after the first layout pass, in case the
                    // initial position was resolved against estimated sizes.
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    if let id = centeredID { proxy.scrollTo(id, anchor: .center) }
                }
            }
            } else {
                legacyCarousel(viewport: geo.size.width)
            }
        }
        .frame(height: style.height)
        .overlay(alignment: .bottom) {
            Capsule()
                .fill(Theme.accent)
                .frame(width: 14, height: 2)
                .allowsHitTesting(false)
        }
    }


    /// iOS 16 fallback: use geometry preferences and ScrollViewReader instead
    /// of iOS 17/18 scroll-position APIs. It still centers the chosen roll.
    private func legacyCarousel(viewport: CGFloat) -> some View {
        let width = FilmCanister.width(forHeight: style.cardHeight)
        return ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: style.gap) {
                    ForEach(films) { film in
                        card(film, width: width)
                            .id(film.id)
                            .background {
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: LegacyFilmCenterPreference.self,
                                        value: [film.id: geo.frame(in: .named("LegacyFilmCarousel")).midX])
                                }
                            }
                    }
                }
                .padding(.horizontal, max(0, (viewport - width) / 2))
            }
            .coordinateSpace(name: "LegacyFilmCarousel")
            .onPreferenceChange(LegacyFilmCenterPreference.self) { positions in
                // Only the user's drag may choose a film from geometry.
                // Programmatic scrollTo reports old/intermediate coordinates
                // on iOS 16 and must never overwrite the actual selection.
                guard legacyDragging, !deterministicSwipe else { return }
                guard let closest = positions.min(by: {
                    abs($0.value - viewport / 2) < abs($1.value - viewport / 2)
                })?.key else { return }
                if centeredID != closest { centeredID = closest }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in
                        if !legacyDragging {
                            gestureOriginID = centeredID
                            onUserDrag()
                        }
                        legacyDragging = true
                    }
                    .onEnded { drag in
                        let selected: String?
                        if deterministicSwipe,
                           let origin = gestureOriginID ?? centeredID,
                           let index = films.firstIndex(where: { $0.id == origin }) {
                            // SwiftUI's preference value is often from the
                            // previous layout pass on iOS 16. Use the actual
                            // finished gesture, snapped to a roll step.
                            let travel = drag.translation.width
                            let threshold = width * 0.20
                            let steps = abs(travel) < threshold ? 0
                                : max(1, Int((abs(travel) / (width + style.gap)).rounded()))
                            let direction = travel < 0 ? 1 : -1
                            let next = min(max(index + direction * steps, 0), films.count - 1)
                            selected = films[next].id
                        } else {
                            selected = centeredID
                        }
                        legacyDragging = false
                        gestureOriginID = nil
                        guard let id = selected else { return }
                        centeredID = id
                        withAnimation(.easeOut(duration: 0.16)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                        // Crucially: do not read centeredID back through a
                        // separate @State owner; deliver this gesture's ID.
                        onSettle(id)
                    }
            )
            .onAppear {
                if let id = centeredID { proxy.scrollTo(id, anchor: .center) }
            }
            .compatibleOnChange(of: programmaticTarget) { _, target in
                if target != nil {
                    legacyDragging = false
                }
            }
            .compatibleOnChange(of: centeredID) { _, selected in
                guard !legacyDragging, let selected else { return }
                withAnimation(Motion.standard) {
                    proxy.scrollTo(selected, anchor: .center)
                }
            }
        }
    }

    private func card(_ film: FilmStock, width: CGFloat) -> some View {
        VStack(spacing: 2) {
            FilmCanister(film: film, height: style.cardHeight)
            CanisterShadow(width: width * 0.86)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture { onTap(film.id) }
    }
}

// MARK: - Picker (title + carousel + kind chips)

/// The film chooser: the centred film's name cross-fading above the carousel,
/// and kind chips below that jump to a group (flanked by `leading` and, on
/// the hero, `trailing`). The selection is committed (`onCommit`) only when
/// the scroll comes to rest; outside changes to `committedID` (viewfinder
/// swipe, film library) scroll the carousel along.
struct FilmPicker<Leading: View, Trailing: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let style: FilmCarousel.Style
    /// Limit the list to the committed film's kind in the photo editor only.
    let groupedByKind: Bool
    let committedID: String
    let onCommit: (String) -> Void
    var onTapCentered: (() -> Void)?
    @ViewBuilder var leading: () -> Leading
    @ViewBuilder var trailing: () -> Trailing

    @State private var centeredID: String?
    @State private var settleTask: Task<Void, Never>?
    @State private var jumpTask: Task<Void, Never>?
    @State private var jumpTarget: String?
    @State private var jumpUntil = Date.distantPast
    @State private var armed = false
    @State private var dimmed = false
    /// The last id this picker committed itself (its echo through
    /// `committedID` must not scroll the carousel).
    @State private var ownCommit: String?

    init(style: FilmCarousel.Style, groupedByKind: Bool = false, committedID: String,
         onCommit: @escaping (String) -> Void, onTapCentered: (() -> Void)? = nil,
         @ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.style = style
        self.groupedByKind = groupedByKind
        self.committedID = committedID
        self.onCommit = onCommit
        self.onTapCentered = onTapCentered
        self.leading = leading
        self.trailing = trailing
        _centeredID = State(initialValue: committedID)
    }

    /// The applied recipe is the single authority for labels and category.
    /// centeredID is a scroll candidate, never the developed film.
    private var appliedFilm: FilmStock { FilmCatalog.film(committedID) }

    var body: some View {
        VStack(spacing: 6) {
            if style == .hero {
                FilmTitleBlock(film: appliedFilm, style: style)
                    .padding(.horizontal, 20)
            } else {
                HStack(spacing: 12) {
                    FilmTitleBlock(film: appliedFilm, style: style)
                    Spacer(minLength: 4)
                    trailing()
                }
                .padding(.horizontal, 20)
            }

            FilmCarousel(style: style,
                         films: groupedByKind ? FilmCatalog.films(of: appliedFilm.kind) : FilmCatalog.films,
                         centeredID: $centeredID, onTap: tapCard,
                         onSettle: { selected in settled(selected) },
                         deterministicSwipe: groupedByKind, programmaticTarget: jumpTarget,
                         programmaticUntil: jumpUntil, onUserDrag: cancelProgrammaticJump)
                // Tear down old iOS 16 geometry when the darkroom switches
                // category. A new category gets an independent scroll list.
                .id(groupedByKind ? appliedFilm.kind.rawValue : "all")
                .opacity(dimmed ? 0 : 1)

            HStack(spacing: 10) {
                leading()
                KindChips(current: appliedFilm.kind, compact: style == .compact) { kind in
                    // The browsing scroll position can already be in this
                    // category while the applied recipe is still the old kind.
                    guard let first = FilmCatalog.films(of: kind).first else { return }
                    if committedID != first.id {
                        jump(to: first.id, haptic: true, commit: true)
                    }
                }
                .frame(maxWidth: .infinity)
                if style == .hero {
                    trailing()
                }
            }
            .padding(.horizontal, 16)
        }
        .compatibleOnChange(of: centeredID) { _, new in centeredChanged(new) }
        .compatibleOnChange(of: committedID) { _, new in
            if new == ownCommit {
                ownCommit = nil
                return
            }
            guard new != centeredID else { return }
            jump(to: new, haptic: false, commit: false)
        }
        .task {
            // Don't apply an initial-film value captured 350ms before a
            // category press. The first carousel onAppear handles alignment.
            armed = true
        }
        .onDisappear {
            settleTask?.cancel()
            jumpTask?.cancel()
        }
    }

    private func tapCard(_ id: String) {
        if id == committedID {
            onTapCentered?()
        } else {
            // Centered-but-not-applied is still a selectable film.
            jump(to: id, haptic: true, commit: true)
        }
    }

    /// Scroll and apply one film + paper selection in the same event.
    private func jump(to id: String, haptic: Bool, commit: Bool) {
        settleTask?.cancel()
        jumpTask?.cancel()
        jumpTarget = id
        jumpUntil = Date().addingTimeInterval(0.85)
        if haptic { Haptics.selection() }

        let films = FilmCatalog.films
        let from = films.firstIndex { $0.id == centeredID } ?? 0
        let to = films.firstIndex { $0.id == id } ?? 0
        let crossingKind = FilmCatalog.film(id).kind != appliedFilm.kind
        if crossingKind || abs(to - from) > 4 {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) { centeredID = id }
        } else {
            withAnimation(Motion.pick(Motion.standard, reduceMotion: reduceMotion)) {
                centeredID = id
            }
        }

        if commit, id != committedID {
            ownCommit = id
            onCommit(id)
        }
    }

    private func cancelProgrammaticJump() {
        jumpTask?.cancel()
        jumpTarget = nil
        jumpUntil = .distantPast
        settleTask?.cancel()
    }

    /// A detent passed under the notch: tick like a dial (no commit yet).
    private func centeredChanged(_ new: String?) {
        guard armed, let new else { return }
        if Date() < jumpUntil {
            // The selected ID was committed at the moment of button tap.
            // Do not re-commit intermediate carousel geometry.
            return
        }
        Haptics.selection()
    }

    /// A user release commits the reel currently under the notch in the same
    /// event. Programmatic movements remain excluded by jumpUntil.
    private func settled(_ id: String) {
        guard armed, Date() >= jumpUntil, id != committedID else { return }
        // Validate against the visible category before applying a new recipe.
        // No cross-category finger-up can pick a hidden/old stock.
        if groupedByKind && FilmCatalog.film(id).kind != appliedFilm.kind { return }
        settleTask?.cancel()
        ownCommit = id
        onCommit(id)
    }

}

// MARK: - Title

/// The centred film's name. Hero: two centred lines (brand · process, then
/// name + ISO). Compact: the same, left-aligned.
struct FilmTitleBlock: View {
    let film: FilmStock
    let style: FilmCarousel.Style

    var body: some View {
        let hero = style == .hero
        ZStack {
            VStack(alignment: hero ? .center : .leading, spacing: 3) {
                Text("\(film.brand.uppercased())  ·  \(film.kind.shortTitle)")
                    .font(AppFont.ui(10, .semibold))
                    .tracking(2)
                    .foregroundStyle(Theme.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(film.name)
                        .font(AppFont.ui(hero ? 20 : 17, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("ISO \(film.iso)")
                        .font(AppFont.mono(11, .medium))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .id(film.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 4)),
                                    removal: .opacity))
        }
        .frame(maxWidth: .infinity, minHeight: 40, alignment: hero ? .center : .leading)
        .animation(.easeOut(duration: 0.22), value: film.id)
    }
}

// MARK: - Kind chips

/// 负片 / 电影 / 反转 / 黑白: short labels, always semibold (only the colour
/// changes, so nothing shifts when the selection moves).
struct KindChips: View {
    let current: FilmKind
    var compact: Bool = false
    let onSelect: (FilmKind) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: compact ? 6 : 4) {
            ForEach(FilmKind.allCases) { kind in
                let selected = kind == current
                Button {
                    onSelect(kind)
                } label: {
                    Text(kind.chipTitle)
                        .font(AppFont.ui(13, .semibold))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        .padding(.horizontal, 10)
                        .frame(height: 30)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.surfaceHigher)
                                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
                                    .matchedGeometryEffect(id: "kind", in: namespace)
                            }
                        }
                        .frame(minHeight: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.94))
                .accessibilityLabel(Text(kind.title))
            }
        }
        .animation(Motion.snappy, value: current)
    }
}

// MARK: - Camera film section

/// The camera screen's film chooser, bound to `model.filmID` (which changes
/// only with the film, not with print-slider ticks).
struct CameraFilmSection: View {
    @EnvironmentObject private var model: AppModel
    let openPrint: () -> Void
    let openLibrary: () -> Void

    var body: some View {
        let model = self.model
        FilmPicker(style: .hero, committedID: model.filmID,
                   onCommit: { model.selectFilm($0) },
                   onTapCentered: openLibrary) {
            Button(action: openLibrary) {
                RoundIcon(systemName: "square.grid.2x2", size: 34, iconSize: 13)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("胶片库"))
        } trailing: {
            Button(action: openPrint) {
                HStack(spacing: 5) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12, weight: .semibold))
                    Text("冲印")
                        .font(AppFont.ui(13, .semibold))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 12)
                .frame(height: 34)
                .background(Capsule().fill(Theme.surface))
                .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                .contentShape(Capsule())
            }
            .buttonStyle(.pressable)
        }
    }
}
