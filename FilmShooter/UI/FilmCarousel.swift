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
    @Binding var centeredID: String?
    let onTap: (String) -> Void
    /// The scroll came to rest.
    let onSettle: () -> Void
    @State private var legacyDragging = false

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
                        ForEach(FilmCatalog.films) { film in
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
                    if phase == .idle { onSettle() }
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
                    ForEach(FilmCatalog.films) { film in
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
                guard let closest = positions.min(by: {
                    abs($0.value - viewport / 2) < abs($1.value - viewport / 2)
                })?.key else { return }
                if centeredID != closest { centeredID = closest }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { _ in legacyDragging = true }
                    .onEnded { _ in
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 240_000_000)
                            legacyDragging = false
                            if let id = centeredID {
                                withAnimation(.easeOut(duration: 0.22)) {
                                    proxy.scrollTo(id, anchor: .center)
                                }
                            }
                            onSettle()
                        }
                    }
            )
            .onAppear {
                if let id = centeredID { proxy.scrollTo(id, anchor: .center) }
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

    init(style: FilmCarousel.Style, committedID: String, onCommit: @escaping (String) -> Void,
         onTapCentered: (() -> Void)? = nil,
         @ViewBuilder leading: @escaping () -> Leading,
         @ViewBuilder trailing: @escaping () -> Trailing) {
        self.style = style
        self.committedID = committedID
        self.onCommit = onCommit
        self.onTapCentered = onTapCentered
        self.leading = leading
        self.trailing = trailing
        _centeredID = State(initialValue: committedID)
    }

    private var centeredFilm: FilmStock { FilmCatalog.film(centeredID ?? committedID) }

    var body: some View {
        VStack(spacing: 6) {
            if style == .hero {
                FilmTitleBlock(film: centeredFilm, style: style)
                    .padding(.horizontal, 20)
            } else {
                HStack(spacing: 12) {
                    FilmTitleBlock(film: centeredFilm, style: style)
                    Spacer(minLength: 4)
                    trailing()
                }
                .padding(.horizontal, 20)
            }

            FilmCarousel(style: style, centeredID: $centeredID, onTap: tapCard, onSettle: settled)
                .opacity(dimmed ? 0 : 1)

            HStack(spacing: 10) {
                leading()
                KindChips(current: centeredFilm.kind, compact: style == .compact) { kind in
                    if let first = FilmCatalog.films(of: kind).first, first.kind != centeredFilm.kind {
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
            // Ignore the scroll view's own settling on first layout.
            try? await Task.sleep(nanoseconds: 350_000_000)
            armed = true
            if centeredID != committedID { jump(to: committedID, haptic: false, commit: false) }
        }
        .onDisappear {
            settleTask?.cancel()
            jumpTask?.cancel()
        }
    }

    private func tapCard(_ id: String) {
        if id == centeredID {
            onTapCentered?()
        } else {
            jump(to: id, haptic: true, commit: true)
        }
    }

    /// Scroll to a film. Long jumps (more than four rolls) don't whip through
    /// the row: the carousel dips out, moves, and fades back in.
    private func jump(to id: String, haptic: Bool, commit: Bool) {
        jumpTarget = id
        jumpUntil = Date().addingTimeInterval(0.7)
        if haptic { Haptics.selection() }
        let films = FilmCatalog.films
        let from = films.firstIndex { $0.id == centeredID } ?? 0
        let to = films.firstIndex { $0.id == id } ?? 0
        jumpTask?.cancel()
        if abs(to - from) > 4 {
            jumpTask = Task {
                withAnimation(.easeOut(duration: 0.12)) { dimmed = true }
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else {
                    dimmed = false
                    return
                }
                var still = Transaction()
                still.disablesAnimations = true
                withTransaction(still) { centeredID = id }
                try? await Task.sleep(nanoseconds: 30_000_000)
                withAnimation(.easeIn(duration: 0.18)) { dimmed = false }
            }
        } else {
            withAnimation(Motion.pick(Motion.standard, reduceMotion: reduceMotion)) { centeredID = id }
        }
        if commit { scheduleCommit(id) }
    }

    /// A detent passed under the notch: tick like a dial (no commit yet).
    private func centeredChanged(_ new: String?) {
        guard armed, let new else { return }
        if Date() < jumpUntil {
            // A programmatic scroll passing other cards: only its target counts.
            if new == jumpTarget { scheduleCommit(new) }
            return
        }
        Haptics.selection()
    }

    /// The scroll came to rest: commit whatever is under the notch.
    private func settled() {
        guard armed, Date() >= jumpUntil else { return }
        settleTask?.cancel()
        let commit = onCommit
        let current = committedID
        settleTask = Task {
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard !Task.isCancelled, let id = centeredID, id != current else { return }
            ownCommit = id
            commit(id)
        }
    }

    private func scheduleCommit(_ id: String) {
        settleTask?.cancel()
        let commit = onCommit
        let current = committedID
        settleTask = Task {
            try? await Task.sleep(nanoseconds: 80_000_000)
            guard !Task.isCancelled, id != current else { return }
            ownCommit = id
            commit(id)
        }
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
    @Environment(AppModel.self) private var model
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
