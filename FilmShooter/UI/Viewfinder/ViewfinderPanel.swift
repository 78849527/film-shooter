import SwiftUI
import AVFoundation

// MARK: - Shutter effect

/// The shutter blackout and film-advance haptic. `CameraService.onShutter`
/// calls `fire()`; only `BlackoutLayer` reads `blackout`.
@MainActor
final class ShutterFX: ObservableObject {
    @Published var blackout: Double = 0
    private var task: Task<Void, Never>?

    func fire() {
        Haptics.filmAdvance()
        task?.cancel()
        withAnimation(.easeIn(duration: 0.07)) { blackout = 0.85 }
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
/// changes), with focus/exposure, pinch zoom, lens chips and zoom dial, film
/// swipe, grid, the date-back LCD and the shutter blackout layered on top.
/// Fast-changing state (zoom, exposure, blackout, film title) lives in small
/// subviews.
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
    @State private var swipeAnnounce = 0
    @State private var swipeDirection: CGFloat = 1
    /// The native-style 3D turn when the camera flips (degrees about y).
    @State private var turn: Double = 0
    @State private var turnTask: Task<Void, Never>?

    private let corner: CGFloat = 10

    var body: some View {
        GeometryReader { geo in
            let container = LayoutMath.fit(aspect: ViewfinderGeometry.sensorAspect, in: geo.size)
            let mask = LayoutMath.fit(aspect: CGFloat(model.settings.frameAspect.portraitAspect), in: container)
            ZStack {
                layers(container: container, mask: mask)
                    .frame(width: mask.width, height: mask.height)
                    .rotation3DEffect(.degrees(turn), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .animation(Motion.pick(Motion.gentle, reduceMotion: reduceMotion), value: model.settings.frameAspect)
        .onChange(of: model.settings.frameAspect) { _, _ in hideReticle(animated: false) }
        .onChange(of: model.camera.isSwitching) { _, switching in switchingChanged(switching) }
        .onChange(of: model.camera.position) { _, _ in positionChanged() }
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

            FilmSwitchTitle(trigger: swipeAnnounce, direction: swipeDirection)

            ViewfinderLCD()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .padding(10)
                .allowsHitTesting(false)

            DateBackPreview()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 12)
                .padding(.bottom, 60)
                .allowsHitTesting(false)

            LensControl(isPinching: pinching)
                .frame(maxHeight: .infinity, alignment: .bottom)
                .padding(.bottom, 6)
        }
        .animation(Motion.fade, value: model.settings.showGrid)
    }

    // MARK: flip turn

    private func switchingChanged(_ switching: Bool) {
        guard !reduceMotion else { return }
        if switching {
            turnTask?.cancel()
            withAnimation(.easeIn(duration: 0.16)) { turn = 90 }
        } else {
            // Finished without the camera changing sides (e.g. a failure):
            // turn back the way we came.
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                if turn == 90 {
                    withAnimation(.easeOut(duration: 0.22)) { turn = 0 }
                }
            }
        }
    }

    private func positionChanged() {
        guard !reduceMotion, turn != 0 else { return }
        turnTask?.cancel()
        turnTask = Task {
            // Let the first half finish (edge-on, hidden under the veil).
            try? await Task.sleep(nanoseconds: 160_000_000)
            guard !Task.isCancelled else { return }
            var still = Transaction()
            still.disablesAnimations = true
            withTransaction(still) { turn = -90 }
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.22)) { turn = 0 }
        }
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
                        let step = decisive < 0 ? 1 : -1
                        Haptics.selection()
                        model.selectAdjacentFilm(step)
                        swipeDirection = step > 0 ? 1 : -1
                        swipeAnnounce += 1
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
    @ObservedObject var fx: ShutterFX

    var body: some View {
        Color.black
            .opacity(fx.blackout)
            .allowsHitTesting(false)
    }
}

/// A frosted veil while the camera switches sides (only exists while
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
        .animation(.easeInOut(duration: 0.18), value: switching)
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

// MARK: - Lens chips & zoom dial

/// Native-style lens chips in a small frosted capsule: dark discs with ".5",
/// "1×", "2"…; the active one is larger and shows the live zoom in amber.
/// Each chip has a 44 pt hit area. Dragging sideways on the row turns it into
/// a zoom dial (log scale, sticking at each lens with a haptic). During a
/// pinch or a dial drag a "2.0× · 48 mm" readout floats above. Reads the
/// ~30 Hz zoom, so it is its own small view.
struct LensControl: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isPinching: Bool

    @State private var showReadout = false
    @State private var readoutTask: Task<Void, Never>?
    @State private var dialStart: CGFloat?
    @State private var showDial = false
    @State private var detent: CGFloat?
    @State private var dialTask: Task<Void, Never>?

    /// Points per stop (doubling of the zoom) on the dial.
    static let pointsPerStop: CGFloat = 110

    var body: some View {
        let camera = model.camera
        let zoom = camera.zoomDisplayFactor
        let active = camera.activeLens
        let readout = Self.readoutText(zoom: zoom, front: camera.position == .front)
        VStack(spacing: 8) {
            if showReadout || showDial {
                Text(readout)
                    .font(AppFont.mono(15, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(Theme.accent)
                    .contentTransition(.numericText(value: Double(zoom)))
                    .animation(.spring(response: 0.2, dampingFraction: 0.9), value: readout)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                    .allowsHitTesting(false)
            }
            if !camera.lenses.isEmpty {
                ZStack {
                    HStack(spacing: 0) {
                        ForEach(camera.lenses) { lens in
                            chip(lens, camera: camera, selected: lens.id == active?.id, zoom: zoom)
                        }
                    }
                    .opacity(showDial ? 0 : 1)
                    if showDial {
                        ZoomDial(zoom: zoom,
                                 lensFactors: camera.lenses.map(\.displayFactor),
                                 range: camera.zoomRange)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, 2)
                .frame(height: 46)
                .background(Capsule().fill(.ultraThinMaterial))
                .contentShape(Capsule())
                .highPriorityGesture(dialGesture)
                .animation(Motion.snappy, value: active?.id)
            }
        }
        .animation(Motion.pick(Motion.snappy, reduceMotion: reduceMotion), value: showDial)
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
        return Text(label)
            .font(AppFont.ui(selected ? 13 : 11, .semibold))
            .monospacedDigit()
            .foregroundStyle(selected ? Theme.accent : Theme.text.opacity(0.92))
            .contentTransition(.numericText(value: Double(selected ? zoom : lens.displayFactor)))
            .animation(.spring(response: 0.2, dampingFraction: 0.9), value: label)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .uprightWithDevice()
            .frame(width: selected ? 38 : 28, height: selected ? 38 : 28)
            .background(Circle().fill(Color.black.opacity(selected ? 0.5 : 0.35)))
            .frame(width: 44, height: 44)
            .contentShape(Circle())
            .onTapGesture {
                Haptics.tap()
                camera.setZoom(displayFactor: lens.displayFactor, animated: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("\(Self.zoomText(lens.displayFactor)) 镜头"))
            .accessibilityAddTraits(.isButton)
    }

    private var dialGesture: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { g in
                let camera = model.camera
                if dialStart == nil {
                    dialStart = camera.zoomDisplayFactor
                    dialTask?.cancel()
                    withAnimation(Motion.snappy) { showDial = true }
                    Haptics.softTap(0.5)
                }
                let start = dialStart ?? 1
                let range = camera.zoomRange
                var raw = start * pow(2, -g.translation.width / Self.pointsPerStop)
                raw = min(max(raw, range.lowerBound), range.upperBound)
                let hit = camera.lenses.map(\.displayFactor).first { abs(log2($0) - log2(raw)) < 0.03 }
                camera.setZoom(displayFactor: hit ?? raw, animated: false)
                if hit != detent {
                    detent = hit
                    if hit != nil { Haptics.selection() }
                }
            }
            .onEnded { _ in
                dialStart = nil
                detent = nil
                dialTask?.cancel()
                dialTask = Task {
                    try? await Task.sleep(nanoseconds: 1_400_000_000)
                    guard !Task.isCancelled else { return }
                    withAnimation(Motion.standard) { showDial = false }
                }
            }
    }

    /// "2×", "2.4×", "0.5×".
    nonisolated static func zoomText(_ zoom: CGFloat) -> String {
        let r = (zoom * 10).rounded() / 10
        if r == r.rounded() { return "\(Int(r))×" }
        return String(format: "%.1f×", Double(r))
    }

    /// "2.0× · 48 mm" (back camera: 24 mm main lens × zoom); front: "1.0×".
    nonisolated static func readoutText(zoom: CGFloat, front: Bool) -> String {
        let z = String(format: "%.1f×", Double(zoom))
        if front { return z }
        return "\(z) · \(Int((24 * zoom).rounded())) mm"
    }
}

/// A tick ruler on a log scale: minor ticks every 0.1 stop, a labelled major
/// tick at each lens, an amber needle at the current zoom; both ends fade.
struct ZoomDial: View {
    let zoom: CGFloat
    let lensFactors: [CGFloat]
    let range: ClosedRange<CGFloat>

    var body: some View {
        let zoom = self.zoom
        let factors = lensFactors
        let labels = lensFactors.map { LensControl.zoomText($0) }
        let pps = LensControl.pointsPerStop
        let lo = log2(max(range.lowerBound, 0.01))
        let hi = log2(max(range.upperBound, 0.01))
        Canvas { context, size in
            let cx = size.width / 2
            let current = log2(max(zoom, 0.01))
            let tickTop = size.height * 0.6
            var s = (lo * 10).rounded(.down) / 10
            while s <= hi + 0.001 {
                let x = cx + (s - current) * pps
                if x >= -2 && x <= size.width + 2 {
                    var p = Path()
                    p.move(to: CGPoint(x: x, y: tickTop))
                    p.addLine(to: CGPoint(x: x, y: tickTop + 6))
                    context.stroke(p, with: .color(Color.white.opacity(0.4)), lineWidth: 1)
                }
                s += 0.1
            }
            for (i, f) in factors.enumerated() {
                let x = cx + (log2(max(f, 0.01)) - current) * pps
                guard x >= -24 && x <= size.width + 24 else { continue }
                var p = Path()
                p.move(to: CGPoint(x: x, y: tickTop - 3))
                p.addLine(to: CGPoint(x: x, y: tickTop + 9))
                context.stroke(p, with: .color(Color.white.opacity(0.9)), lineWidth: 1.5)
                context.draw(Text(labels[i])
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.white.opacity(0.9)),
                             at: CGPoint(x: x, y: size.height * 0.3))
            }
            var needle = Path()
            needle.move(to: CGPoint(x: cx, y: size.height * 0.48))
            needle.addLine(to: CGPoint(x: cx, y: size.height - 5))
            context.stroke(needle, with: .color(Theme.accent), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        }
        .frame(width: 236, height: 46)
        .mask {
            LinearGradient(stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.18),
                .init(color: .black, location: 0.82),
                .init(color: .clear, location: 1),
            ], startPoint: .leading, endPoint: .trailing)
        }
        .allowsHitTesting(false)
    }
}

// MARK: - LCD

/// The date-back readout in the viewfinder corner: a pulsing dot while the
/// film's table is baking, and the exposure compensation when it isn't zero.
/// Nothing at all otherwise.
struct ViewfinderLCD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let bias = model.camera.exposureBias
        let baking = model.isBakingLUT
        let showsEV = abs(bias) >= 0.05
        ZStack(alignment: .topLeading) {
            if baking || showsEV {
                HStack(spacing: 6) {
                    if baking {
                        Circle()
                            .fill(Theme.lcd)
                            .frame(width: 5, height: 5)
                            .phaseAnimator([0.25, 1.0]) { content, phase in
                                content.opacity(phase)
                            } animation: { _ in
                                .easeInOut(duration: 0.55)
                            }
                    }
                    if showsEV {
                        Text(String(format: "EV %+.1f", bias))
                            .lcdText(11)
                    }
                }
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(Color.black.opacity(0.32)))
                .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: baking)
        .animation(Motion.fade, value: showsEV)
    }
}

/// A preview of the date the print will carry (only when 日期印 is on).
struct DateBackPreview: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let on = model.recipe.dateStamp
        ZStack {
            if on {
                Text(DevelopRecipe.dateText(Date()))
                    .lcdText(13)
                    .transition(.opacity)
            }
        }
        .animation(Motion.fade, value: on)
    }
}

// MARK: - Film switch title

/// After a swipe on the viewfinder, the new film's name rises in the lower
/// third -- brand in tracked small caps, the name, its tagline, ISO and
/// process -- and fades after ~0.9 s. Only for swipes: the title row above
/// the carousel already names the film otherwise.
struct FilmSwitchTitle: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let trigger: Int
    let direction: CGFloat

    @State private var shown: FilmStock?
    @State private var hideTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            if let film = shown {
                VStack(spacing: 5) {
                    Text(film.brand.uppercased())
                        .font(AppFont.ui(10, .semibold))
                        .tracking(4)
                        .foregroundStyle(Color.white.opacity(0.8))
                    Text(film.name)
                        .font(AppFont.ui(28, .semibold))
                        .foregroundStyle(Color.white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                    Text(film.tagline)
                        .font(AppFont.ui(13))
                        .foregroundStyle(Color.white.opacity(0.85))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    HStack(spacing: 8) {
                        Text("ISO \(film.iso)")
                            .font(AppFont.mono(11, .semibold))
                        Text(film.kind.shortTitle)
                            .font(AppFont.mono(10, .semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.5), lineWidth: 0.8))
                    }
                    .foregroundStyle(Color.white.opacity(0.85))
                    .padding(.top, 2)
                }
                .shadow(color: .black.opacity(0.5), radius: 10)
                .padding(.horizontal, 20)
                .id(film.id)
                .transition(transition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 70)
        .allowsHitTesting(false)
        .onChange(of: trigger) { _, _ in present() }
    }

    private var transition: AnyTransition {
        if reduceMotion { return AnyTransition.opacity }
        return AnyTransition.asymmetric(
            insertion: AnyTransition.opacity.combined(with: .offset(x: 28 * direction)).combined(with: .scale(scale: 0.96)),
            removal: AnyTransition.opacity.combined(with: .offset(x: -20 * direction)))
    }

    private func present() {
        hideTask?.cancel()
        withAnimation(Motion.standard) { shown = model.film }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 900_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.35)) { shown = nil }
        }
    }
}
