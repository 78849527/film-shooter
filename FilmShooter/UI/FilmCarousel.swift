import SwiftUI

// MARK: - Carousel

/// A snapping, horizontally scrolling row of film canisters. The centred card
/// is full size; the others shrink, fade and turn slightly away, computed per
/// frame from each card's distance to the centre (pure transforms: no layout,
/// no offscreen passes, so it holds 60/120 fps).
struct FilmCarousel: View {
    enum Style: Equatable {
        case hero, compact

        var cardHeight: CGFloat { self == .hero ? 72 : 46 }
        var gap: CGFloat { self == .hero ? 12 : 8 }
        var shrink: CGFloat { self == .hero ? 0.27 : 0.2 }
        var height: CGFloat { cardHeight + (self == .hero ? 16 : 12) }
    }

    let style: Style
    @Binding var centeredID: String?
    let onTap: (String) -> Void

    var body: some View {
        GeometryReader { geo in
            let viewport = geo.size.width
            let cardWidth = FilmCanister.width(forHeight: style.cardHeight)
            let step = cardWidth + style.gap
            let shrink = style.shrink
            ScrollView(.horizontal) {
                LazyHStack(spacing: style.gap) {
                    ForEach(FilmCatalog.films) { film in
                        card(film, width: cardWidth)
                            .visualEffect { content, proxy in
                                let mid = proxy.frame(in: .scrollView(axis: .horizontal)).midX
                                let d = (mid - viewport / 2) / step
                                let t = abs(d)
                                let k = min(t, 1)
                                let scale = 1 - shrink * k
                                // Pull scaled cards in so the gaps stay even.
                                let h = t < 1 ? t * t / 2 : t - 0.5
                                let dx: CGFloat = (d < 0 ? 1 : -1) * cardWidth * shrink * h
                                let fade = 1 - 0.3 * k - 0.32 * min(max(t - 1, 0), 1)
                                let tilt = Double(max(-1, min(1, d))) * -16
                                return content
                                    .scaleEffect(scale)
                                    .offset(x: dx)
                                    .rotation3DEffect(.degrees(tilt), axis: (x: 0, y: 1, z: 0))
                                    .opacity(Double(fade))
                            }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollIndicators(.hidden)
            .contentMargins(.horizontal, max(0, (viewport - cardWidth) / 2), for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollPosition(id: $centeredID, anchor: .center)
        }
        .frame(height: style.height)
    }

    private func card(_ film: FilmStock, width: CGFloat) -> some View {
        VStack(spacing: style == .hero ? 4 : 2) {
            FilmCanister(film: film, height: style.cardHeight)
            CanisterShadow(width: width * 0.86)
        }
        .frame(width: width)
        .contentShape(Rectangle())
        .onTapGesture { onTap(film.id) }
    }
}

// MARK: - Picker (title + carousel + kind chips)

/// The film chooser: the centred film's name and tagline cross-fading above
/// the carousel, and kind chips below that jump to a group. The selection is
/// committed (`onCommit`) once the scroll settles; outside changes to
/// `committedID` (viewfinder swipe, film library) scroll the carousel along.
struct FilmPicker<Accessory: View>: View {
    let style: FilmCarousel.Style
    let committedID: String
    let onCommit: (String) -> Void
    var onTapCentered: (() -> Void)?
    @ViewBuilder var accessory: () -> Accessory

    @State private var centeredID: String?
    @State private var settleTask: Task<Void, Never>?
    @State private var jumpTarget: String?
    @State private var jumpUntil = Date.distantPast
    @State private var armed = false
    /// The last id this picker committed itself (its echo through
    /// `committedID` must not scroll the carousel).
    @State private var ownCommit: String?

    init(style: FilmCarousel.Style, committedID: String, onCommit: @escaping (String) -> Void,
         onTapCentered: (() -> Void)? = nil, @ViewBuilder accessory: @escaping () -> Accessory) {
        self.style = style
        self.committedID = committedID
        self.onCommit = onCommit
        self.onTapCentered = onTapCentered
        self.accessory = accessory
        _centeredID = State(initialValue: committedID)
    }

    private var centeredFilm: FilmStock { FilmCatalog.film(centeredID ?? committedID) }

    var body: some View {
        VStack(spacing: style == .hero ? 8 : 6) {
            HStack(alignment: .center, spacing: 12) {
                FilmTitleBlock(film: centeredFilm, style: style)
                Spacer(minLength: 4)
                accessory()
            }
            .padding(.horizontal, 20)

            FilmCarousel(style: style, centeredID: $centeredID, onTap: tapCard)

            KindChips(current: centeredFilm.kind, compact: style == .compact) { kind in
                if let first = FilmCatalog.films(of: kind).first, first.kind != centeredFilm.kind {
                    jump(to: first.id, haptic: true, commit: true)
                }
            }
        }
        .onChange(of: centeredID) { _, new in centeredChanged(new) }
        .onChange(of: committedID) { _, new in
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
        .onDisappear { settleTask?.cancel() }
    }

    private func tapCard(_ id: String) {
        if id == centeredID {
            Haptics.tap()
            onTapCentered?()
        } else {
            jump(to: id, haptic: true, commit: true)
        }
    }

    private func jump(to id: String, haptic: Bool, commit: Bool) {
        jumpTarget = id
        jumpUntil = Date().addingTimeInterval(0.7)
        if haptic { Haptics.selection() }
        withAnimation(Motion.standard) { centeredID = id }
        if commit { scheduleCommit(id) }
    }

    private func centeredChanged(_ new: String?) {
        guard armed, let new else { return }
        if Date() < jumpUntil {
            // A programmatic scroll passing other cards: only its target counts.
            if new == jumpTarget { scheduleCommit(new) }
            return
        }
        Haptics.selection()
        scheduleCommit(new)
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

/// Brand in tracked small caps, name, ISO and tagline; cross-fades per film.
struct FilmTitleBlock: View {
    let film: FilmStock
    let style: FilmCarousel.Style

    var body: some View {
        ZStack(alignment: .leading) {
            VStack(alignment: .leading, spacing: style == .hero ? 3 : 2) {
                HStack(spacing: 6) {
                    Text(film.brand.uppercased())
                        .font(AppFont.ui(10, .semibold))
                        .tracking(1.8)
                        .foregroundStyle(Theme.secondary)
                    Text(film.kind.shortTitle)
                        .font(AppFont.mono(9, .semibold))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 0.8))
                }
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(film.name)
                        .font(AppFont.ui(style == .hero ? 20 : 16, .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("ISO \(film.iso)")
                        .font(AppFont.mono(11, .medium))
                        .foregroundStyle(Theme.accent.opacity(0.9))
                }
                if style == .hero {
                    Text(film.tagline)
                        .font(AppFont.ui(12))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
            }
            .id(film.id)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 5)),
                                    removal: .opacity))
        }
        .frame(maxWidth: .infinity, minHeight: style == .hero ? 58 : 38, alignment: .leading)
        .animation(.easeOut(duration: 0.24), value: film.id)
    }
}

// MARK: - Kind chips

struct KindChips: View {
    let current: FilmKind
    var compact: Bool = false
    let onSelect: (FilmKind) -> Void

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 6) {
            ForEach(FilmKind.allCases) { kind in
                let selected = kind == current
                Button {
                    onSelect(kind)
                } label: {
                    Text(kind.title)
                        .font(AppFont.ui(compact ? 11.5 : 12.5, selected ? .semibold : .medium))
                        .foregroundStyle(selected ? Theme.text : Theme.secondary)
                        .padding(.horizontal, compact ? 10 : 12)
                        .padding(.vertical, compact ? 5 : 6)
                        .background {
                            if selected {
                                Capsule()
                                    .fill(Theme.surfaceHigher)
                                    .overlay(Capsule().strokeBorder(Theme.accent.opacity(0.45), lineWidth: 1))
                                    .matchedGeometryEffect(id: "kind", in: namespace)
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.pressable(scale: 0.94))
            }
        }
        .animation(Motion.snappy, value: current)
    }
}

// MARK: - Camera film section

/// The camera screen's film chooser, bound to `model.recipe.filmID`.
struct CameraFilmSection: View {
    @Environment(AppModel.self) private var model
    let openPrint: () -> Void
    let openLibrary: () -> Void

    var body: some View {
        let model = self.model
        FilmPicker(style: .hero, committedID: model.recipe.filmID,
                   onCommit: { model.selectFilm($0) },
                   onTapCentered: openLibrary) {
            HStack(spacing: 8) {
                Button(action: { Haptics.tap(); openLibrary() }) {
                    RoundIcon(systemName: "square.grid.2x2", size: 38, iconSize: 14)
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(Text("胶片库"))

                Button(action: { Haptics.tap(); openPrint() }) {
                    HStack(spacing: 5) {
                        Image(systemName: "slider.horizontal.3")
                            .font(.system(size: 13, weight: .semibold))
                        Text("冲印")
                            .font(AppFont.ui(14, .semibold))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .frame(height: 38)
                    .background(Capsule().fill(Theme.surface))
                    .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                    .contentShape(Capsule())
                }
                .buttonStyle(.pressable)
            }
        }
    }
}
