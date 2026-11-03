import SwiftUI
import AVFoundation

// MARK: - Shutter effect

/// The shutter blackout and film-advance haptic. `CameraService.onShutter`
/// calls `fire()`; only `BlackoutLayer` reads `blackout`.
@Observable @MainActor
final class ShutterFX {
    var blackout: Double = 0
    @ObservationIgnored private var task: Task<Void, Never>?

    func fire() {
        Haptics.filmAdvance()
        task?.cancel()
        withAnimation(.easeIn(duration: 0.07)) { blackout = 1 }
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard let self, !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.blackout = 0 }
        }
    }
}

// MARK: - Panel

/// The viewfinder: a 3:4 Metal view that is created once and never resized,
/// masked to the chosen frame (the mask morphs with a spring when the aspect
/// changes), with focus/exposure, pinch zoom, lens chips, film swipe, grid,
/// the date-back LCD and the shutter blackout layered on top. Fast-changing
/// state (zoom, exposure, blackout, film title) lives in small subviews.
struct ViewfinderPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let fx: ShutterFX

    private enum DragMode { case undecided, film, exposure, ignored }

    @State private var focusPoint: CGPoint?
    @State private var focusID = 0
    @State private var reticleVisible = false
    @State private var reticleDim = false
    @State private var reticleTask: Task<Void, Never>?
    @State private var dragMode: DragMode = .undecided
    @State private var evStart: Float?
    @State private var isAdjustingEV = false
    @State private var pinching = false
    @State private var pinchSeen = false

    private let corner: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let container = LayoutMath.fit(aspect: ViewfinderGeometry.sensorAspect, in: geo.size)
            let mask = LayoutMath.fit(aspect: CGFloat(model.settings.frameAspect.portraitAspect), in: container)
            ZStack {
                layers(container: container, mask: mask)
                    .frame(width: mask.width, height: mask.height)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(Motion.pick(Motion.gentle, reduceMotion: reduceMotion), value: model.settings.frameAspect)
        .onChange(of: model.settings.frameAspect) { _, _ in hideReticle(animated: false) }
    }

    @ViewBuilder
    private func layers(container: CGSize, mask: CGSize) -> some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            // The live picture: always 3:4, centred, cut by the frame mask.
            ViewfinderLayer()
                .frame(width: container.width, height: container.height)
                .frame(width: mask.width, height: mask.height)
                .clipShape(shape)

            if model.settings.showGrid {
                ThirdsGrid()
                    .stroke(Color.white.opacity(0.26), lineWidth: 0.5)
                    .transition(.opacity)
                    .allowsHitTesting(false)
            }

            CameraStateOverlay()
                .clipShape(shape)
            BlackoutLayer(fx: fx)
                .clipShape(shape)
            SwitchingOverlay()
                .clipShape(shape)

            gestureSurface(container: container, mask: mask)

            focusLayer(mask: mask)

            FilmSwitchTitle()

            ViewfinderLCD()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(9)
                .allowsHitTesting(false)

            LensControl(isPinching: pinching)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 12)

            shape
                .strokeBorder(Theme.hairlineStrong, lineWidth: 1)
                .allowsHitTesting(false)
        }
        .animation(Motion.fade, value: model.settings.showGrid)
    }

    // MARK: gestures

    private func gestureSurface(container: CGSize, mask: CGSize) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                focus(at: location, container: container, mask: mask)
            }
            .gesture(dragGesture)
            .simultaneousGesture(magnifyGesture)
            .accessibilityElement()
            .accessibilityLabel(Text("取景器"))
            .accessibilityHint(Text("轻点对焦，左右滑动切换胶片，双指缩放"))
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { g in
                if dragMode == .undecided {
                    let dx = abs(g.translation.width), dy = abs(g.translation.height)
                    if dx > dy * 1.2 {
                        dragMode = .film
                    } else if reticleVisible {
                        dragMode = .exposure
                        evStart = model.camera.exposureBias
                        reticleTask?.cancel()
                        reticleDim = false
                        isAdjustingEV = true
                    } else {
                        dragMode = .ignored
                    }
                }
                guard dragMode == .exposure, let start = evStart else { return }
                let camera = model.camera
                let range = camera.exposureBiasRange
                var v = start + Float(-g.translation.height / 55)
                v = (v * 10).rounded() / 10
                v = min(max(v, range.lowerBound), range.upperBound)
                if v != camera.exposureBias {
                    if v == 0 { Haptics.selection() }
                    camera.exposureBias = v
                }
            }
            .onEnded { g in
                let mode = dragMode
                dragMode = .undecided
                evStart = nil
                switch mode {
                case .film:
                    guard !pinchSeen, !pinching else { break }
                    let dx = g.translation.width
                    let predicted = g.predictedEndTranslation.width
                    let decisive = abs(dx) > 44 ? dx : predicted
                    if abs(dx) > 44 || abs(predicted) > 110 {
                        Haptics.selection()
                        model.selectAdjacentFilm(decisive < 0 ? 1 : -1)
                    }
                case .exposure:
                    isAdjustingEV = false
                    scheduleReticleFade()
                default:
                    break
                }
                if !pinching { pinchSeen = false }
            }
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                let camera = model.camera
                if !pinching {
                    pinching = true
                    pinchSeen = true
                    camera.beginPinch()
                }
                camera.updatePinch(scale: value.magnification)
            }
            .onEnded { _ in
                pinching = false
            }
    }

    private func focus(at location: CGPoint, container: CGSize, mask: CGSize) {
        guard container.width > 0, container.height > 0 else { return }
        // Normalise in the full 3:4 picture the mask is cut from.
        let nx = (location.x + (container.width - mask.width) / 2) / container.width
        let ny = (location.y + (container.height - mask.height) / 2) / container.height
        model.camera.focusAndExpose(at: CGPoint(x: nx, y: ny))
        Haptics.softTap(0.5)
        let inset: CGFloat = 38
        focusPoint = CGPoint(x: LayoutMath.clamp(location.x, inset, max(inset, mask.width - inset)),
                             y: LayoutMath.clamp(location.y, inset, max(inset, mask.height - inset)))
        focusID += 1
        reticleDim = false
        withAnimation(.easeOut(duration: 0.12)) { reticleVisible = true }
        scheduleReticleFade()
    }

    private func scheduleReticleFade() {
        reticleTask?.cancel()
        reticleTask = Task {
            try? await Task.sleep(nanoseconds: 1_100_000_000)
            guard !Task.isCancelled else { return }
            reticleDim = true
            try? await Task.sleep(nanoseconds: 2_200_000_000)
            guard !Task.isCancelled else { return }
            hideReticle(animated: true)
        }
    }

    private func hideReticle(animated: Bool) {
        reticleTask?.cancel()
        if animated {
            withAnimation(.easeOut(duration: 0.4)) { reticleVisible = false }
        } else {
            reticleVisible = false
        }
    }

    @ViewBuilder
    private func focusLayer(mask: CGSize) -> some View {
        if reticleVisible, let p = focusPoint {
            let side: CGFloat = p.x > mask.width - 84 ? -54 : 54
            ZStack {
                FocusReticle(dimmed: reticleDim)
                    .id(focusID)
                    .position(p)
                ExposureScale(isAdjusting: isAdjustingEV, dimmed: reticleDim)
                    .position(x: p.x + side, y: p.y)
            }
            .allowsHitTesting(false)
            .transition(.opacity)
        }
    }
}

// MARK: - Metal layer

/// The only view that reads the LUT / grain / film kind, so recipe changes
/// re-evaluate just this (and `ViewfinderView` diffs the values).
struct ViewfinderLayer: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let camera = model.camera
        ViewfinderView(frames: camera.frames,
                       lut: model.lut,
                       frameAspect: ViewfinderGeometry.sensorAspect,
                       grain: model.viewfinderGrain,
                       isMonochrome: model.film.kind == .blackWhite,
                       mirrored: camera.position == .front)
    }
}

struct BlackoutLayer: View {
    let fx: ShutterFX

    var body: some View {
        Color.black
            .opacity(fx.blackout)
            .allowsHitTesting(false)
    }
}

/// A frosted veil while the camera switches lenses / sides (only exists while
/// switching, so there is no permanent backdrop blur over the live picture).
struct SwitchingOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let switching = model.camera.isSwitching
        ZStack {
            if switching {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(Color.black.opacity(0.28))
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.22), value: switching)
        .allowsHitTesting(false)
    }
}

/// Covers the picture while the camera is not delivering frames.
struct CameraStateOverlay: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let camera = model.camera
        let state = camera.state
        let interrupted = camera.isInterrupted
        let visible = !ScreenshotMode.isActive && (state != .running || interrupted)
        ZStack {
            if visible {
                ZStack {
                    Theme.surface
                    VStack(spacing: 10) {
                        Image(systemName: icon(state, interrupted))
                            .font(.system(size: 26, weight: .light))
                            .foregroundStyle(Theme.secondary)
                            .symbolEffect(.pulse, isActive: state == .idle)
                        Text(message(state, interrupted))
                            .font(AppFont.ui(13))
                            .foregroundStyle(Theme.secondary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                    .padding(20)
                }
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.35), value: visible)
        .allowsHitTesting(false)
    }

    private func icon(_ state: CameraService.State, _ interrupted: Bool) -> String {
        if interrupted { return "pause.circle" }
        switch state {
        case .idle, .running: return "camera.aperture"
        case .unauthorized: return "lock"
        case .failed: return "exclamationmark.triangle"
        }
    }

    private func message(_ state: CameraService.State, _ interrupted: Bool) -> String {
        if interrupted { return "相机暂时被其他应用占用" }
        switch state {
        case .idle, .running: return "正在启动相机…"
        case .unauthorized: return "没有相机权限"
        case .failed(let m): return "相机不可用\n\(m)"
        }
    }
}

struct ThirdsGrid: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        for i in 1...2 {
            let x = rect.minX + rect.width * CGFloat(i) / 3
            p.move(to: CGPoint(x: x, y: rect.minY))
            p.addLine(to: CGPoint(x: x, y: rect.maxY))
            let y = rect.minY + rect.height * CGFloat(i) / 3
            p.move(to: CGPoint(x: rect.minX, y: y))
            p.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return p
    }
}

// MARK: - Focus & exposure

struct FocusReticle: View {
    var dimmed: Bool
    @State private var appeared = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .strokeBorder(Theme.accent, lineWidth: 1.2)
            ForEach(0..<4) { i in
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: 1.2, height: 6)
                    .offset(y: -33)
                    .rotationEffect(.degrees(Double(i) * 90))
            }
        }
        .frame(width: 72, height: 72)
        .scaleEffect(appeared ? 1 : 1.45)
        .opacity(appeared ? (dimmed ? 0.45 : 1) : 0)
        .animation(.easeOut(duration: 0.35), value: dimmed)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.68)) { appeared = true }
        }
    }
}

/// The sun on a vertical scale beside the reticle; drag up/down on the
/// viewfinder to move it.
struct ExposureScale: View {
    @Environment(AppModel.self) private var model
    let isAdjusting: Bool
    let dimmed: Bool

    private let trackHeight: CGFloat = 116

    var body: some View {
        let camera = model.camera
        let bias = camera.exposureBias
        let range = camera.exposureBiasRange
        let span = max(0.1, range.upperBound - range.lowerBound)
        let fraction = CGFloat((bias - range.lowerBound) / span)
        let zeroFraction = CGFloat((0 - range.lowerBound) / span)
        let y = trackHeight * (0.5 - fraction)
        ZStack {
            Capsule()
                .fill(Theme.accent.opacity(0.55))
                .frame(width: 1, height: trackHeight)
            Capsule()
                .fill(Theme.accent)
                .frame(width: 7, height: 1)
                .offset(y: trackHeight * (0.5 - zeroFraction))
            Image(systemName: "sun.max.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .offset(y: y)
            if isAdjusting || abs(bias) >= 0.05 {
                Text(String(format: "%+.1f", bias))
                    .font(AppFont.mono(11, .semibold))
                    .foregroundStyle(Theme.accent)
                    .fixedSize()
                    .offset(x: 26, y: y)
                    .transition(.opacity)
            }
        }
        .frame(width: 24, height: trackHeight)
        .opacity(dimmed && !isAdjusting ? 0.5 : 1)
        .animation(.easeOut(duration: 0.3), value: dimmed)
        .animation(.easeOut(duration: 0.2), value: isAdjusting)
    }
}

// MARK: - Lens chips

/// Native-style lens chips: small dark discs with ".5", "1×", "2"...; the
/// active one is larger and shows the live zoom in amber. During a pinch a
/// large zoom readout floats above them. Reads the ~30 Hz zoom, so it is its
/// own small view.
struct LensControl: View {
    @Environment(AppModel.self) private var model
    let isPinching: Bool

    @State private var showReadout = false
    @State private var readoutTask: Task<Void, Never>?

    var body: some View {
        let camera = model.camera
        let zoom = camera.zoomDisplayFactor
        let active = camera.activeLens
        let readout = Self.zoomText(zoom)
        VStack(spacing: 10) {
            if showReadout {
                Text(readout)
                    .font(AppFont.ui(17, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(value: Double(zoom)))
                    .animation(.spring(response: 0.2, dampingFraction: 0.9), value: readout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
                    .allowsHitTesting(false)
            }
            if !camera.lenses.isEmpty {
                HStack(spacing: 6) {
                    ForEach(camera.lenses) { lens in
                        chip(lens, camera: camera, selected: lens.id == active?.id, zoom: zoom)
                    }
                }
                .padding(4)
                .background(Capsule().fill(Color.black.opacity(0.24)))
                .animation(Motion.snappy, value: active?.id)
            }
        }
        .animation(.easeOut(duration: 0.2), value: showReadout)
        .onChange(of: isPinching) { _, pinching in
            readoutTask?.cancel()
            if pinching {
                showReadout = true
            } else {
                readoutTask = Task {
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { return }
                    showReadout = false
                }
            }
        }
    }

    private func chip(_ lens: CameraService.Lens, camera: CameraService, selected: Bool, zoom: CGFloat) -> some View {
        let label = camera.lensChipLabel(for: lens)
        return Button {
            Haptics.tap()
            camera.setZoom(displayFactor: lens.displayFactor, animated: true)
        } label: {
            Text(label)
                .font(AppFont.ui(selected ? 12.5 : 11, .semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? Theme.accent : Theme.text.opacity(0.92))
                .contentTransition(.numericText(value: Double(selected ? zoom : lens.displayFactor)))
                .animation(.spring(response: 0.2, dampingFraction: 0.9), value: label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .uprightWithDevice()
                .frame(width: selected ? 38 : 28, height: selected ? 38 : 28)
                .background(Circle().fill(Color.black.opacity(selected ? 0.55 : 0.4)))
                .contentShape(Circle())
        }
        .buttonStyle(.pressable(scale: 0.9))
        .accessibilityLabel(Text("\(Self.zoomText(lens.displayFactor)) 镜头"))
    }

    static func zoomText(_ zoom: CGFloat) -> String {
        let r = (zoom * 10).rounded() / 10
        if r == r.rounded() { return "\(Int(r))×" }
        return String(format: "%.1f×", Double(r))
    }
}

// MARK: - LCD

/// The date-back readout in the viewfinder corner: film, ISO, exposure
/// compensation, and a pulsing dot while the film's table is baking.
struct ViewfinderLCD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let film = model.film
        let bias = model.camera.exposureBias
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 5) {
                Text("\(film.name.uppercased()) · ISO \(film.iso)")
                    .lcdText(10)
                if model.isBakingLUT {
                    Circle()
                        .fill(Theme.lcd)
                        .frame(width: 5, height: 5)
                        .phaseAnimator([0.25, 1.0]) { content, phase in
                            content.opacity(phase)
                        } animation: { _ in
                            .easeInOut(duration: 0.55)
                        }
                        .transition(.opacity)
                }
            }
            if abs(bias) >= 0.05 {
                Text(String(format: "EV %+.1f", bias))
                    .lcdText(10)
                    .transition(.opacity)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.32)))
        .animation(Motion.fade, value: model.isBakingLUT)
        .animation(Motion.fade, value: abs(bias) >= 0.05)
    }
}

// MARK: - Film switch title

/// When the film changes, its name rises over the middle of the viewfinder --
/// brand in tracked small caps, the name large, ISO and process -- and fades
/// after ~0.9 s.
struct FilmSwitchTitle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var shown: FilmStock?
    @State private var direction: CGFloat = 1
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        let id = model.recipe.filmID
        ZStack {
            if let film = shown {
                VStack(spacing: 6) {
                    Text(film.brand.uppercased())
                        .font(AppFont.ui(12, .semibold))
                        .tracking(4)
                        .foregroundStyle(Color.white.opacity(0.78))
                    Text(film.name)
                        .font(AppFont.ui(34, .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.45)
                    HStack(spacing: 8) {
                        Text("ISO \(film.iso)")
                            .font(AppFont.mono(12, .semibold))
                            .foregroundStyle(Theme.accent)
                        Text(film.kind.shortTitle)
                            .font(AppFont.mono(10, .semibold))
                            .foregroundStyle(Color.white.opacity(0.9))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.8))
                        Text(film.kind.title)
                            .font(AppFont.ui(11, .medium))
                            .foregroundStyle(Color.white.opacity(0.75))
                    }
                }
                .padding(.horizontal, 28)
                .padding(.vertical, 26)
                .background(
                    RadialGradient(colors: [Color.black.opacity(0.5), Color.black.opacity(0)],
                                   center: .center, startRadius: 0, endRadius: 170)
                )
                .id(film.id)
                .transition(transition)
            }
        }
        .allowsHitTesting(false)
        .onChange(of: id) { old, new in present(old: old, new: new) }
    }

    private var transition: AnyTransition {
        if reduceMotion { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 28 * direction)).combined(with: .scale(scale: 0.96)),
            removal: .opacity.combined(with: .offset(x: -20 * direction)))
    }

    private func present(old: String, new: String) {
        let films = FilmCatalog.films
        if let a = films.firstIndex(where: { $0.id == old }), let b = films.firstIndex(where: { $0.id == new }) {
            var diff = b - a
            if diff > films.count / 2 { diff -= films.count } else if diff < -films.count / 2 { diff += films.count }
            direction = diff >= 0 ? 1 : -1
        }
        hideTask?.cancel()
        withAnimation(Motion.standard) { shown = FilmCatalog.film(new) }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { shown = nil }
        }
    }
}
