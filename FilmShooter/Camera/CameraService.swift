import AVFoundation
import Foundation
import Observation

/// One captured frame, as delivered by `AVCapturePhotoOutput`.
struct CapturedPhoto: @unchecked Sendable {
    /// HEIC (or JPEG) file bytes, from `AVCapturePhoto.fileDataRepresentation()`.
    /// Orientation is in the file's metadata (not baked into the pixels).
    let processedData: Data
    /// DNG file bytes (Bayer RAW or Apple ProRAW) when RAW was captured.
    let rawData: Data?
    let captureDate: Date
    let isFrontCamera: Bool
}

enum CameraServiceError: LocalizedError {
    case notRunning
    case busy
    case captureFailed

    var errorDescription: String? {
        switch self {
        case .notRunning: return "相机未启动"
        case .busy: return "正在拍摄，请稍候"
        case .captureFailed: return "拍摄失败，请重试"
        }
    }
}

/// Runs `body` on the main actor, asynchronously and in FIFO order.
private func runOnMain(_ body: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(body) }
}

/// The camera: session lifecycle, lenses and zoom, focus/exposure, capture.
///
/// All AVFoundation work happens on a private serial queue; this object only
/// publishes state for the UI and is used from the main actor.
@Observable @MainActor
final class CameraService: NSObject {
    enum State: Equatable {
        case idle, unauthorized, running, failed(String)
    }

    struct Lens: Identifiable, Hashable {
        let id: Int
        /// Zoom as shown to the user: 0.5, 1, 2, 3, 5 ...
        let displayFactor: CGFloat
        /// Native-style chip label: ".5", "1×", "2", "3" ...
        let label: String
    }

    private(set) var state: State = .idle
    private(set) var position: AVCaptureDevice.Position = .back
    /// Used for the next capture (ignored when `hasFlash` is false).
    var flashMode: AVCaptureDevice.FlashMode = .off
    private(set) var hasFlash = false
    private(set) var lenses: [Lens] = []
    /// The live display zoom (follows ramps and pinches, ~30 Hz).
    private(set) var zoomDisplayFactor: CGFloat = 1
    /// Allowed display zoom range for the active camera.
    private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// Allowed exposure bias range for the active camera (within -3...3).
    private(set) var exposureBiasRange: ClosedRange<Float> = -3...3
    private(set) var isRAWSupported = false
    private(set) var isCapturing = false
    private(set) var isSwitching = false
    /// The session is interrupted (e.g. another app took the camera).
    private(set) var isInterrupted = false
    /// The angle set on the photo connection at capture (90 = portrait).
    private(set) var captureRotationAngle: CGFloat = 90
    /// Same as `iconRotationDegrees` but continuous (never jumps by 360),
    /// so `withAnimation` rotates icons the short way.
    private(set) var uiRotationAngle: Double = 0
    /// Rotation for icons to stay upright: 0 portrait, 90 / -90 landscape,
    /// 180 upside down. Apply with `.rotationEffect(.degrees(...))`.
    private(set) var iconRotationDegrees: Double = 0

    /// Exposure compensation in EV, clamped to `exposureBiasRange`.
    var exposureBias: Float {
        get { storedExposureBias }
        set {
            let value = min(max(newValue, exposureBiasRange.lowerBound), exposureBiasRange.upperBound)
            guard value != storedExposureBias else { return }
            storedExposureBias = value
            controller.setExposureBias(value)
        }
    }

    /// Capture a DNG alongside the processed photo (when `isRAWSupported`).
    var captureRAW: Bool {
        get { storedCaptureRAW }
        set {
            guard newValue != storedCaptureRAW else { return }
            storedCaptureRAW = newValue
            controller.setRAWEnabled(newValue)
        }
    }

    /// The viewfinder frames.
    let frames = CameraFrameSource()

    /// Called on the main thread when the sensor exposes (shutter moment).
    @ObservationIgnored var onShutter: (() -> Void)?

    private var storedExposureBias: Float = 0
    private var storedCaptureRAW = false

    private let controller = CaptureController()
    @ObservationIgnored private var baseZoom: CGFloat = 1
    @ObservationIgnored private var pinchStartFactor: CGFloat = 1
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var lifecycleGeneration = 0
    @ObservationIgnored private var deviceGeneration = -1
    @ObservationIgnored private var switchGeneration = 0
    @ObservationIgnored private var eventsInstalled = false
    @ObservationIgnored private weak var activeDevice: AVCaptureDevice?
    @ObservationIgnored private var captureCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var iconCoordinator: AVCaptureDevice.RotationCoordinator?
    @ObservationIgnored private var captureAngleObservation: NSKeyValueObservation?
    @ObservationIgnored private var iconAngleObservation: NSKeyValueObservation?

    // MARK: Lifecycle

    /// Asks for camera access if needed, configures the session (once) and
    /// starts it. Safe to call repeatedly (e.g. on every return to foreground).
    func start() async {
        wantsRunning = true
        lifecycleGeneration += 1
        let generation = lifecycleGeneration

        let granted: Bool
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: granted = true
        case .notDetermined: granted = await AVCaptureDevice.requestAccess(for: .video)
        default: granted = false
        }
        guard generation == lifecycleGeneration else { return }
        guard granted else {
            state = .unauthorized
            return
        }

        installEventHandlerIfNeeded()
        let controller = self.controller
        let request = CaptureController.StartRequest(
            position: position, frames: frames, wantsRAW: storedCaptureRAW, exposureBias: storedExposureBias)
        let result = await withCheckedContinuation { (continuation: CheckedContinuation<CaptureController.ConfigResult, Never>) in
            controller.start(request) { continuation.resume(returning: $0) }
        }
        switch result {
        case .success(let snapshot):
            apply(snapshot)
            if generation == lifecycleGeneration { state = .running }
        case .failure(let message):
            if generation == lifecycleGeneration { state = .failed(message) }
        }
    }

    /// Stops the session (on the session queue). Call when leaving the camera
    /// or going to the background.
    func stop() {
        wantsRunning = false
        lifecycleGeneration += 1
        controller.stop()
        if state == .running { state = .idle }
        isInterrupted = false
    }

    /// Switches between the back and front cameras without stopping the
    /// session; `isSwitching` is true until the new camera's first frame.
    func flipCamera() {
        guard state == .running, !isSwitching, !isCapturing else { return }
        isSwitching = true
        switchGeneration += 1
        let generation = switchGeneration
        let target: AVCaptureDevice.Position = position == .front ? .back : .front
        controller.switchCamera(to: target) { [weak self] result in
            runOnMain {
                guard let self else { return }
                switch result {
                case .success(let snapshot):
                    self.apply(snapshot)
                    self.frames.notifyOnNextFrame { [weak self] in
                        runOnMain { self?.endSwitch(generation) }
                    }
                    // Fallback in case no frame arrives (e.g. interrupted).
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                        MainActor.assumeIsolated { self?.endSwitch(generation) }
                    }
                case .failure:
                    self.endSwitch(generation)
                }
            }
        }
    }

    private func endSwitch(_ generation: Int) {
        guard generation == switchGeneration, isSwitching else { return }
        isSwitching = false
    }

    // MARK: Zoom

    /// The lens chip the current zoom falls into (highlight it in the UI).
    var activeLens: Lens? {
        let zoom = zoomDisplayFactor
        return lenses.last(where: { $0.displayFactor <= zoom + 0.05 }) ?? lenses.first
    }

    /// Native-style chip text: the active chip shows the live zoom ("2.4×",
    /// "1×", ".7×"), the others their plain label (".5", "2", "3").
    func lensChipLabel(for lens: Lens) -> String {
        guard lens.id == activeLens?.id else { return lens.label }
        return Self.zoomLabel(zoomDisplayFactor)
    }

    /// Zooms to a display factor (1 = main camera). `animated` ramps smoothly
    /// (~0.28 s for any lens jump), cancelling a ramp in progress.
    func setZoom(displayFactor: CGFloat, animated: Bool) {
        let clamped = min(max(displayFactor, zoomRange.lowerBound), zoomRange.upperBound)
        controller.setZoom(factor: clamped * baseZoom, animated: animated)
    }

    func beginPinch() {
        pinchStartFactor = controller.latestDisplayZoom() ?? zoomDisplayFactor
    }

    /// `scale` is the gesture's magnification since `beginPinch()`.
    func updatePinch(scale: CGFloat) {
        let mapped = pinchStartFactor * pow(max(scale, 0.01), 1.15)
        setZoom(displayFactor: mapped, animated: false)
    }

    // MARK: Focus / exposure

    /// `point` is the tap location normalised to the viewfinder as seen on
    /// screen (0...1, x right, y down, portrait). Mirroring of the front
    /// camera is handled here.
    func focusAndExpose(at point: CGPoint) {
        let x = min(max(point.x, 0), 1)
        let y = min(max(point.y, 0), 1)
        // Device space is the landscape sensor (home button right).
        let devicePoint = position == .front ? CGPoint(x: y, y: x) : CGPoint(x: y, y: 1 - x)
        controller.focus(at: devicePoint)
    }

    // MARK: Capture

    func capturePhoto() async throws -> CapturedPhoto {
        guard state == .running else { throw CameraServiceError.notRunning }
        guard !isCapturing, !isSwitching else { throw CameraServiceError.busy }
        isCapturing = true
        defer { isCapturing = false }

        let request = CaptureController.CaptureRequest(
            flashMode: hasFlash ? flashMode : .off,
            wantsRAW: storedCaptureRAW && isRAWSupported,
            rotationAngle: captureRotationAngle,
            isFrontCamera: position == .front,
            date: Date())
        let controller = self.controller
        let shutter: @Sendable () -> Void = { [weak self] in
            runOnMain { self?.onShutter?() }
        }
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CapturedPhoto, Error>) in
            controller.capture(request, onShutter: shutter) { result in
                continuation.resume(with: result)
            }
        }
    }

    // MARK: Private

    private func installEventHandlerIfNeeded() {
        guard !eventsInstalled else { return }
        eventsInstalled = true
        controller.onEvent = { [weak self] event in
            runOnMain { self?.handle(event) }
        }
    }

    private func handle(_ event: CaptureController.Event) {
        switch event {
        case .interrupted(let interrupted):
            if isInterrupted != interrupted { isInterrupted = interrupted }
        case .recovered:
            if wantsRunning { state = .running }
        case .failed(let message):
            if wantsRunning { state = .failed(message) }
        case .zoom(let display, let generation):
            if generation == deviceGeneration, abs(display - zoomDisplayFactor) > 0.0005 {
                zoomDisplayFactor = display
            }
        }
    }

    private func apply(_ snapshot: CaptureController.DeviceSnapshot) {
        deviceGeneration = snapshot.generation
        if position != snapshot.position { position = snapshot.position }
        baseZoom = snapshot.baseZoom
        let newLenses = snapshot.lensFactors.enumerated().map {
            Lens(id: $0.offset, displayFactor: $0.element, label: Self.lensLabel($0.element))
        }
        if newLenses != lenses { lenses = newLenses }
        zoomRange = snapshot.minDisplayZoom...snapshot.maxDisplayZoom
        zoomDisplayFactor = snapshot.currentDisplayZoom
        if hasFlash != snapshot.hasFlash { hasFlash = snapshot.hasFlash }
        if isRAWSupported != snapshot.isRAWSupported { isRAWSupported = snapshot.isRAWSupported }
        exposureBiasRange = snapshot.biasRange
        let clampedBias = min(max(storedExposureBias, snapshot.biasRange.lowerBound), snapshot.biasRange.upperBound)
        if clampedBias != storedExposureBias {
            storedExposureBias = clampedBias
            controller.setExposureBias(clampedBias)
        }
        if activeDevice !== snapshot.device {
            activeDevice = snapshot.device
            installCaptureCoordinator(for: snapshot.device)
        }
        if iconCoordinator == nil, snapshot.position == .back {
            installIconCoordinator(for: snapshot.device)
        }
    }

    private func installCaptureCoordinator(for device: AVCaptureDevice) {
        captureAngleObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        captureCoordinator = coordinator
        setCaptureAngle(coordinator.videoRotationAngleForHorizonLevelCapture)
        captureAngleObservation = Self.observeCaptureAngle(of: coordinator) { [weak self] angle in
            runOnMain { self?.setCaptureAngle(angle) }
        }
    }

    /// Icons follow the back camera's angle convention whichever camera is
    /// active, so their direction never depends on the front sensor mounting.
    private func installIconCoordinator(for device: AVCaptureDevice) {
        iconAngleObservation?.invalidate()
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        iconCoordinator = coordinator
        setIconAngle(from: coordinator.videoRotationAngleForHorizonLevelCapture)
        iconAngleObservation = Self.observeCaptureAngle(of: coordinator) { [weak self] angle in
            runOnMain { self?.setIconAngle(from: angle) }
        }
    }

    private func setCaptureAngle(_ angle: CGFloat) {
        if captureRotationAngle != angle { captureRotationAngle = angle }
        if iconCoordinator == nil { setIconAngle(from: angle) }
    }

    /// 90 (portrait) -> 0, 0 -> 90, 180 -> -90, 270 -> 180.
    private func setIconAngle(from captureAngle: CGFloat) {
        var degrees = (90 - Double(captureAngle)).truncatingRemainder(dividingBy: 360)
        if degrees > 180 { degrees -= 360 } else if degrees <= -180 { degrees += 360 }
        if iconRotationDegrees != degrees { iconRotationDegrees = degrees }
        var delta = (degrees - uiRotationAngle).truncatingRemainder(dividingBy: 360)
        if delta > 180 { delta -= 360 } else if delta < -180 { delta += 360 }
        if abs(delta) > 0.01 { uiRotationAngle += delta }
    }

    nonisolated private static func observeCaptureAngle(
        of coordinator: AVCaptureDevice.RotationCoordinator,
        handler: @escaping @Sendable (CGFloat) -> Void
    ) -> NSKeyValueObservation {
        coordinator.observe(\.videoRotationAngleForHorizonLevelCapture, options: [.new]) { observed, _ in
            handler(observed.videoRotationAngleForHorizonLevelCapture)
        }
    }

    private static func lensLabel(_ factor: CGFloat) -> String {
        if abs(factor - 1) < 0.01 { return "1×" }
        return trimmedNumber(factor)
    }

    private static func zoomLabel(_ zoom: CGFloat) -> String {
        trimmedNumber(zoom) + "×"
    }

    /// One decimal at most, no trailing ".0", no leading "0": ".5", "2", "2.4".
    private static func trimmedNumber(_ value: CGFloat) -> String {
        let rounded = (value * 10).rounded() / 10
        var text = rounded == rounded.rounded()
            ? String(Int(rounded))
            : String(format: "%.1f", Double(rounded))
        if text.hasPrefix("0"), text.count > 1 { text.removeFirst() }
        return text
    }
}
