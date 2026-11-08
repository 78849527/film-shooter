import AVFoundation
import Foundation
import Combine

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
    DispatchQueue.main.async { Task { @MainActor in body() } }
}

/// The camera: session lifecycle, lenses and zoom, focus/exposure, capture.
///
/// All AVFoundation work happens on a private serial queue; this object only
/// publishes state for the UI and is used from the main actor.
@MainActor
final class CameraService: NSObject, ObservableObject {
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

    @Published private(set) var state: State = .idle
    @Published private(set) var position: AVCaptureDevice.Position = .back
    /// Used for the next capture (ignored when `hasFlash` is false).
    @Published var flashMode: AVCaptureDevice.FlashMode = .off
    @Published private(set) var hasFlash = false
    @Published private(set) var lenses: [Lens] = []
    /// The live display zoom (follows ramps and pinches, ~30 Hz).
    @Published private(set) var zoomDisplayFactor: CGFloat = 1
    /// Allowed display zoom range for the active camera.
    @Published private(set) var zoomRange: ClosedRange<CGFloat> = 1...1
    /// Allowed exposure bias range for the active camera (within -3...3).
    @Published private(set) var exposureBiasRange: ClosedRange<Float> = -3...3
    @Published private(set) var isRAWSupported = false
    @Published private(set) var isCapturing = false
    @Published private(set) var isSwitching = false
    /// The session is interrupted (e.g. another app took the camera).
    @Published private(set) var isInterrupted = false
    /// The angle set on the photo connection at capture (90 = portrait).
    @Published private(set) var captureRotationAngle: CGFloat = 90
    /// Same as `iconRotationDegrees` but continuous (never jumps by 360),
    /// so `withAnimation` rotates icons the short way.
    @Published private(set) var uiRotationAngle: Double = 0
    /// Rotation for icons to stay upright: 0 portrait, 90 / -90 landscape,
    /// 180 upside down. Apply with `.rotationEffect(.degrees(...))`.
    @Published private(set) var iconRotationDegrees: Double = 0

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
    var onShutter: (() -> Void)?

    @Published private var storedExposureBias: Float = 0
    @Published private var storedCaptureRAW = false

    private let controller = CaptureController()
    private var baseZoom: CGFloat = 1
    private var pinchStartFactor: CGFloat = 1
    private var wantsRunning = false
    private var lifecycleGeneration = 0
    private var deviceGeneration = -1
    private var switchGeneration = 0
    private var eventsInstalled = false
    private weak var activeDevice: AVCaptureDevice?
    private var captureCoordinator: AnyObject?
    private var iconCoordinator: AnyObject?
    private var captureAngleObservation: NSKeyValueObservation?
    private var iconAngleObservation: NSKeyValueObservation?

    // MARK: Lifecycle

    /// Asks for camera access if needed, configures the session (once) and
    /// starts it. Safe to call repeatedly (e.g. on every return to foreground).
    func start() async {
        if ScreenshotMode.isActive { startSimulatedFeed(); return }
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
            runOnMain { self?.finishSwitch(result, generation: generation) }
        }
    }

    private func finishSwitch(_ result: CaptureController.ConfigResult, generation: Int) {
        switch result {
        case .success(let snapshot):
            apply(snapshot)
            frames.notifyOnNextFrame { [weak self] in
                runOnMain { self?.endSwitch(generation) }
            }
            // Fallback in case no frame arrives (e.g. interrupted).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                runOnMain { self?.endSwitch(generation) }
            }
        case .failure:
            endSwitch(generation)
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
        if ScreenshotMode.isActive { zoomDisplayFactor = clamped; return }
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
        if ScreenshotMode.isActive, let data = ScreenshotMode.sampleData() {
            onShutter?()
            return CapturedPhoto(processedData: data, rawData: nil, captureDate: Date(), isFrontCamera: false)
        }
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

    // MARK: Screenshot mode

    private var simulatedFeed: DispatchSourceTimer?

    /// No camera (Simulator / CI screenshots): feed the sample picture as a
    /// 30 fps "camera" and present a typical triple-camera lens set.
    private func startSimulatedFeed() {
        state = .running
        if lenses.isEmpty {
            lenses = [Lens(id: 0, displayFactor: 0.5, label: ".5"), Lens(id: 1, displayFactor: 1, label: "1×"),
                      Lens(id: 2, displayFactor: 2, label: "2"), Lens(id: 3, displayFactor: 3, label: "3")]
            zoomRange = 0.5...15
            zoomDisplayFactor = 1
            hasFlash = true
            isRAWSupported = true
        }
        guard simulatedFeed == nil else { return }
        let frames = self.frames
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.github.filmshooter.simfeed"))
        simulatedFeed = timer
        DispatchQueue.global(qos: .userInitiated).async {
            guard let buffer = ScreenshotMode.samplePixelBuffer() else { return }
            timer.schedule(deadline: .now(), repeating: 1.0 / 30.0)
            timer.setEventHandler { frames.inject(buffer) }
            timer.resume()
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
        guard #available(iOS 17.0, *) else {
            captureCoordinator = nil
            setCaptureAngle(90)
            return
        }
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
        guard #available(iOS 17.0, *) else {
            iconCoordinator = nil
            setIconAngle(from: 90)
            return
        }
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

    @available(iOS 17.0, *)
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

// MARK: - Capture controller

/// Owns the `AVCaptureSession`. Every AVFoundation call runs on `queue`;
/// the few members used from other threads are lock-protected.
private final class CaptureController: @unchecked Sendable {
    enum Event: Sendable {
        case interrupted(Bool)
        case recovered
        case failed(String)
        /// Display zoom of the device with this generation.
        case zoom(CGFloat, Int)
    }

    struct StartRequest: @unchecked Sendable {
        let position: AVCaptureDevice.Position
        let frames: CameraFrameSource
        let wantsRAW: Bool
        let exposureBias: Float
    }

    struct CaptureRequest: @unchecked Sendable {
        let flashMode: AVCaptureDevice.FlashMode
        let wantsRAW: Bool
        let rotationAngle: CGFloat
        let isFrontCamera: Bool
        let date: Date
    }

    struct DeviceSnapshot: @unchecked Sendable {
        let device: AVCaptureDevice
        let generation: Int
        let position: AVCaptureDevice.Position
        /// `videoZoomFactor` at display 1 (the main camera).
        let baseZoom: CGFloat
        let lensFactors: [CGFloat]
        let minDisplayZoom: CGFloat
        let maxDisplayZoom: CGFloat
        let currentDisplayZoom: CGFloat
        let hasFlash: Bool
        let isRAWSupported: Bool
        let biasRange: ClosedRange<Float>
    }

    enum ConfigResult: @unchecked Sendable {
        case success(DeviceSnapshot)
        case failure(String)
    }

    /// Set once before the first `start`; called from any thread.
    var onEvent: (@Sendable (Event) -> Void)?

    private static let rampDuration: Double = 0.28
    private static let maxDisplayZoom: CGFloat = 15
    private static let subjectAreaChangedName = AVCaptureDevice.subjectAreaDidChangeNotification

    private let queue = DispatchQueue(label: "io.github.filmshooter.camera.session", qos: .userInitiated)
    private let videoQueue = DispatchQueue(label: "io.github.filmshooter.camera.video", qos: .userInteractive)
    private let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()

    // Session-queue state.
    private var videoInput: AVCaptureDeviceInput?
    private var isConfigured = false
    private var wantsRunning = false
    private var wantsRAW = false
    private var exposureBias: Float = 0
    private var generation = 0
    private var currentBase: CGFloat = 1
    private var inFlight: [Int64: PhotoCaptureProcessor] = [:]
    private var subjectAreaObserver: NSObjectProtocol?
    private var sessionObservations: [NSKeyValueObservation] = []
    private var zoomObservation: NSKeyValueObservation?
    private var rampPollActive = false

    // Cross-thread state, guarded by `stateLock`.
    private let stateLock = NSLock()
    private var pendingZoom: (factor: CGFloat, animated: Bool)?
    private var pendingBias: Float?
    private var observedDisplayZoom: CGFloat?
    private var observedGeneration = 0
    private var zoomPublishScheduled = false

    // MARK: Lifecycle

    func start(_ request: StartRequest, completion: @escaping @Sendable (ConfigResult) -> Void) {
        queue.async { [self] in
            wantsRunning = true
            if !isConfigured {
                wantsRAW = request.wantsRAW
                exposureBias = request.exposureBias
                if let message = configureSession(position: request.position, frames: request.frames) {
                    completion(.failure(message))
                    return
                }
                isConfigured = true
            }
            if !session.isRunning { session.startRunning() }
            guard let device = videoInput?.device else {
                completion(.failure("无法连接相机"))
                return
            }
            completion(.success(snapshot(for: device)))
        }
    }

    func stop() {
        queue.async { [self] in
            wantsRunning = false
            if session.isRunning { session.stopRunning() }
        }
    }

    func switchCamera(to position: AVCaptureDevice.Position, completion: @escaping @Sendable (ConfigResult) -> Void) {
        queue.async { [self] in
            guard isConfigured, let currentInput = videoInput else {
                completion(.failure("相机未启动"))
                return
            }
            guard let device = Self.findDevice(position: position),
                  let newInput = try? AVCaptureDeviceInput(device: device) else {
                completion(.failure("无法切换相机"))
                return
            }
            session.beginConfiguration()
            session.removeInput(currentInput)
            let switched: Bool
            if session.canAddInput(newInput) {
                session.addInput(newInput)
                videoInput = newInput
                switched = true
            } else {
                if session.canAddInput(currentInput) { session.addInput(currentInput) }
                switched = false
            }
            let active = videoInput?.device ?? device
            configureConnections(position: active.position)
            session.commitConfiguration()

            guard switched else {
                completion(.failure("无法切换相机"))
                return
            }
            postConfigure(device: active, resetZoom: true)
            completion(.success(snapshot(for: active)))
        }
    }

    // MARK: Controls (any thread)

    /// Coalesced: rapid calls (pinch) collapse into the latest value.
    func setZoom(factor: CGFloat, animated: Bool) {
        stateLock.lock()
        let schedule = pendingZoom == nil
        pendingZoom = (factor, animated)
        stateLock.unlock()
        if schedule { queue.async { [self] in applyPendingZoom() } }
    }

    func setExposureBias(_ bias: Float) {
        stateLock.lock()
        let schedule = pendingBias == nil
        pendingBias = bias
        stateLock.unlock()
        if schedule { queue.async { [self] in applyPendingBias() } }
    }

    func setRAWEnabled(_ enabled: Bool) {
        queue.async { [self] in
            wantsRAW = enabled
            guard isConfigured else { return }
            if photoOutput.isAppleProRAWSupported, photoOutput.isAppleProRAWEnabled != enabled {
                photoOutput.isAppleProRAWEnabled = enabled
            }
        }
    }

    /// `devicePoint` is in the device's point-of-interest space.
    func focus(at devicePoint: CGPoint) {
        queue.async { [self] in
            guard let device = videoInput?.device else { return }
            setPointOfInterest(devicePoint, on: device)
        }
    }

    /// The latest known display zoom (unthrottled).
    func latestDisplayZoom() -> CGFloat? {
        stateLock.lock(); defer { stateLock.unlock() }
        return observedDisplayZoom
    }

    func capture(_ request: CaptureRequest,
                 onShutter: @escaping @Sendable () -> Void,
                 completion: @escaping @Sendable (Result<CapturedPhoto, Error>) -> Void) {
        queue.async { [self] in
            guard session.isRunning, videoInput != nil else {
                completion(.failure(CameraServiceError.notRunning))
                return
            }
            let settings = makeSettings(for: request)
            if let connection = photoOutput.connection(with: .video) {
                if #available(iOS 17.0, *) {
                    if connection.isVideoRotationAngleSupported(request.rotationAngle) {
                        connection.videoRotationAngle = request.rotationAngle
                    }
                } else if connection.isVideoOrientationSupported {
                    connection.videoOrientation = .portrait
                }
            }
            let id = settings.uniqueID
            let processor = PhotoCaptureProcessor(request: request, onShutter: onShutter) { [weak self] result in
                completion(result)
                guard let self else { return }
                self.queue.async { self.inFlight[id] = nil }
            }
            inFlight[id] = processor
            photoOutput.capturePhoto(with: settings, delegate: processor)
        }
    }

    // MARK: Configuration (session queue)

    /// Returns an error message, or nil on success.
    private func configureSession(position: AVCaptureDevice.Position, frames: CameraFrameSource) -> String? {
        session.beginConfiguration()
        // sRGB preview and photos: the film LUT's domain.
        session.automaticallyConfiguresCaptureDeviceForWideColor = false
        if session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }

        guard let device = Self.findDevice(position: position) else {
            return abandonConfiguration("未找到可用的相机")
        }
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else {
            return abandonConfiguration("无法连接相机")
        }
        session.addInput(input)
        videoInput = input

        photoOutput.maxPhotoQualityPrioritization = .quality
        guard session.canAddOutput(photoOutput) else { return abandonConfiguration("无法配置拍照输出") }
        session.addOutput(photoOutput)

        videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(frames, queue: videoQueue)
        guard session.canAddOutput(videoOutput) else { return abandonConfiguration("无法配置取景器") }
        session.addOutput(videoOutput)

        configureConnections(position: position)
        session.commitConfiguration()

        postConfigure(device: device, resetZoom: true)
        observeSessionIfNeeded()
        return nil
    }

    private func abandonConfiguration(_ message: String) -> String {
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        videoInput = nil
        session.commitConfiguration()
        return message
    }

    /// Preview frames upright in portrait (mirrored for the front camera);
    /// photos mirrored like the preview. No stabilisation on the preview.
    private func configureConnections(position: AVCaptureDevice.Position) {
        let mirrored = position == .front
        if let connection = videoOutput.connection(with: .video) {
            if #available(iOS 17.0, *) {
                if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
            } else if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = mirrored
            }
            if connection.isVideoStabilizationSupported {
                connection.preferredVideoStabilizationMode = .off
            }
        }
        if let connection = photoOutput.connection(with: .video), connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = mirrored
        }
    }

    private func postConfigure(device: AVCaptureDevice, resetZoom: Bool) {
        generation += 1
        currentBase = Self.lensLayout(for: device).base
        configurePhotoOutput(for: device)
        configureDevice(device, resetZoom: resetZoom)
        observeZoom(of: device)
        observeSubjectArea(of: device)
    }

    private func configurePhotoOutput(for device: AVCaptureDevice) {
        if let dims = Self.preferredPhotoDimensions(device.activeFormat.supportedMaxPhotoDimensions) {
            let current = photoOutput.maxPhotoDimensions
            if current.width != dims.width || current.height != dims.height {
                photoOutput.maxPhotoDimensions = dims
            }
        }
        if photoOutput.maxPhotoQualityPrioritization != .quality {
            photoOutput.maxPhotoQualityPrioritization = .quality
        }
        if photoOutput.isAppleProRAWSupported, photoOutput.isAppleProRAWEnabled != wantsRAW {
            photoOutput.isAppleProRAWEnabled = wantsRAW
        }
        if photoOutput.isZeroShutterLagSupported, !photoOutput.isZeroShutterLagEnabled {
            photoOutput.isZeroShutterLagEnabled = true
        }
        if photoOutput.isResponsiveCaptureSupported, !photoOutput.isResponsiveCaptureEnabled {
            photoOutput.isResponsiveCaptureEnabled = true
        }
        if photoOutput.isFastCapturePrioritizationSupported, !photoOutput.isFastCapturePrioritizationEnabled {
            photoOutput.isFastCapturePrioritizationEnabled = true
        }
        if photoOutput.isContentAwareDistortionCorrectionSupported, !photoOutput.isContentAwareDistortionCorrectionEnabled {
            photoOutput.isContentAwareDistortionCorrectionEnabled = true
        }
    }

    private func configureDevice(_ device: AVCaptureDevice, resetZoom: Bool) {
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }

        if device.activeFormat.supportedColorSpaces.contains(.sRGB), device.activeColorSpace != .sRGB {
            device.activeColorSpace = .sRGB
        }
        if resetZoom {
            device.videoZoomFactor = Self.clamp(currentBase, device.minAvailableVideoZoomFactor, device.maxAvailableVideoZoomFactor)
        }
        let centre = CGPoint(x: 0.5, y: 0.5)
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = centre }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = centre }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        if device.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            device.whiteBalanceMode = .continuousAutoWhiteBalance
        }
        device.isSubjectAreaChangeMonitoringEnabled = true
        if device.isLowLightBoostSupported { device.automaticallyEnablesLowLightBoostWhenAvailable = true }
        device.setExposureTargetBias(clampedBias(exposureBias, for: device), completionHandler: nil)
        // 60 fps preview when the preset's format offers it (AE may still slow it in low light).
        if device.activeFormat.videoSupportedFrameRateRanges.contains(where: { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }) {
            device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
        }
    }

    private func observeSessionIfNeeded() {
        guard sessionObservations.isEmpty else { return }
        sessionObservations.append(session.observe(\.isInterrupted, options: [.new]) { [weak self] observed, _ in
            self?.onEvent?(.interrupted(observed.isInterrupted))
        })
        // Stopped without being asked (runtime error, media services reset): restart.
        sessionObservations.append(session.observe(\.isRunning, options: [.new]) { [weak self] observed, _ in
            guard let self, !observed.isRunning else { return }
            self.queue.asyncAfter(deadline: .now() + 0.5) { self.recoverIfNeeded() }
        })
    }

    private func recoverIfNeeded() {
        guard wantsRunning, isConfigured, !session.isRunning, !session.isInterrupted else { return }
        session.startRunning()
        onEvent?(session.isRunning ? .recovered : .failed("相机出现错误，请重试"))
    }

    private func observeSubjectArea(of device: AVCaptureDevice) {
        if let token = subjectAreaObserver { NotificationCenter.default.removeObserver(token) }
        subjectAreaObserver = NotificationCenter.default.addObserver(
            forName: Self.subjectAreaChangedName, object: device, queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                guard let current = self.videoInput?.device, current === device else { return }
                self.setPointOfInterest(CGPoint(x: 0.5, y: 0.5), on: current)
            }
        }
    }

    private func setPointOfInterest(_ point: CGPoint, on device: AVCaptureDevice) {
        do { try device.lockForConfiguration() } catch { return }
        defer { device.unlockForConfiguration() }
        // Setting the mode again applies the new point of interest.
        if device.isFocusPointOfInterestSupported { device.focusPointOfInterest = point }
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isExposurePointOfInterestSupported { device.exposurePointOfInterest = point }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.isSubjectAreaChangeMonitoringEnabled = true
    }

    // MARK: Zoom (session queue)

    private func applyPendingZoom() {
        stateLock.lock()
        let request = pendingZoom
        pendingZoom = nil
        stateLock.unlock()
        guard let request, let device = videoInput?.device else { return }
        do { try device.lockForConfiguration() } catch { return }
        let target = Self.clamp(request.factor, device.minAvailableVideoZoomFactor, device.maxAvailableVideoZoomFactor)
        if device.isRampingVideoZoom { device.cancelVideoZoomRamp() }
        if request.animated {
            // Rate is in doublings per second: every lens jump takes ~rampDuration.
            let current = max(device.videoZoomFactor, 0.01)
            let octaves = abs(log2(Double(target / current)))
            let rate = Float(min(16, max(2, octaves / Self.rampDuration)))
            device.ramp(toVideoZoomFactor: target, withRate: rate)
        } else {
            device.videoZoomFactor = target
        }
        device.unlockForConfiguration()
        if request.animated {
            startRampPoll(device)
        } else {
            noteZoom(target, base: currentBase, generation: generation)
        }
    }

    /// Belt and braces for KVO during ramps: sample the zoom at 30 Hz.
    private func startRampPoll(_ device: AVCaptureDevice) {
        guard !rampPollActive else { return }
        rampPollActive = true
        pollRamp(device, remaining: 60)
    }

    private func pollRamp(_ device: AVCaptureDevice, remaining: Int) {
        queue.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
            guard let self else { return }
            guard device === self.videoInput?.device else {
                self.rampPollActive = false
                return
            }
            self.noteZoom(device.videoZoomFactor, base: self.currentBase, generation: self.generation)
            if device.isRampingVideoZoom, remaining > 0 {
                self.pollRamp(device, remaining: remaining - 1)
            } else {
                self.rampPollActive = false
            }
        }
    }

    private func observeZoom(of device: AVCaptureDevice) {
        zoomObservation?.invalidate()
        let base = currentBase
        let generation = self.generation
        zoomObservation = device.observe(\.videoZoomFactor, options: [.new]) { [weak self] observed, _ in
            self?.noteZoom(observed.videoZoomFactor, base: base, generation: generation)
        }
        noteZoom(device.videoZoomFactor, base: base, generation: generation)
    }

    /// Records the zoom and publishes it to the main thread at most ~30 Hz
    /// (the latest value always gets through).
    private func noteZoom(_ factor: CGFloat, base: CGFloat, generation: Int) {
        stateLock.lock()
        observedDisplayZoom = factor / max(base, 0.01)
        observedGeneration = generation
        let schedule = !zoomPublishScheduled
        zoomPublishScheduled = true
        stateLock.unlock()
        if schedule {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 30.0) { [weak self] in
                self?.publishZoom()
            }
        }
    }

    private func publishZoom() {
        stateLock.lock()
        let value = observedDisplayZoom
        let generation = observedGeneration
        zoomPublishScheduled = false
        stateLock.unlock()
        if let value { onEvent?(.zoom(value, generation)) }
    }

    private func applyPendingBias() {
        stateLock.lock()
        let bias = pendingBias
        pendingBias = nil
        stateLock.unlock()
        guard let bias else { return }
        exposureBias = bias
        guard let device = videoInput?.device else { return }
        do { try device.lockForConfiguration() } catch { return }
        device.setExposureTargetBias(clampedBias(bias, for: device), completionHandler: nil)
        device.unlockForConfiguration()
    }

    private func clampedBias(_ bias: Float, for device: AVCaptureDevice) -> Float {
        let lower = max(-3, device.minExposureTargetBias)
        let upper = max(lower, min(3, device.maxExposureTargetBias))
        return min(max(bias, lower), upper)
    }

    // MARK: Capture settings

    private func makeSettings(for request: CaptureRequest) -> AVCapturePhotoSettings {
        let codec: AVVideoCodecType = photoOutput.availablePhotoCodecTypes.contains(.hevc) ? .hevc : .jpeg
        let format: [String: Any] = [AVVideoCodecKey: codec]
        let settings: AVCapturePhotoSettings
        var isBayerRAW = false
        if request.wantsRAW, let rawType = preferredRAWPixelFormat() {
            // Delivers both the DNG and the processed photo.
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType, processedFormat: format)
            isBayerRAW = AVCapturePhotoOutput.isBayerRAWPixelFormat(rawType)
        } else {
            settings = AVCapturePhotoSettings(format: format)
        }
        let dims = photoOutput.maxPhotoDimensions
        if dims.width > 0, dims.height > 0 { settings.maxPhotoDimensions = dims }
        // Deep Fusion / Smart HDR; Bayer RAW is a single unfused frame.
        settings.photoQualityPrioritization = isBayerRAW ? .speed : .quality
        if photoOutput.supportedFlashModes.contains(request.flashMode) {
            settings.flashMode = request.flashMode
        }
        if settings.rawPhotoPixelFormatType == 0, photoOutput.isContentAwareDistortionCorrectionEnabled {
            settings.isAutoContentAwareDistortionCorrectionEnabled = true
        }
        return settings
    }

    private func preferredRAWPixelFormat() -> OSType? {
        let types = photoOutput.availableRawPhotoPixelFormatTypes
        if photoOutput.isAppleProRAWEnabled,
           let proRAW = types.first(where: { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }) {
            return proRAW
        }
        return types.first(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
    }

    // MARK: Device info

    private func snapshot(for device: AVCaptureDevice) -> DeviceSnapshot {
        let layout = Self.lensLayout(for: device)
        let base = layout.base
        let minDisplay = device.minAvailableVideoZoomFactor / base
        let maxDisplay = max(minDisplay, min(device.maxAvailableVideoZoomFactor, base * Self.maxDisplayZoom) / base)
        let lensFactors = layout.factors.filter { $0 >= minDisplay - 0.01 && $0 <= maxDisplay + 0.01 }
        let lower = max(-3, device.minExposureTargetBias)
        let upper = max(lower, min(3, device.maxExposureTargetBias))
        let rawSupported = photoOutput.isAppleProRAWSupported
            || photoOutput.availableRawPhotoPixelFormatTypes.contains(where: { AVCapturePhotoOutput.isBayerRAWPixelFormat($0) })
        return DeviceSnapshot(
            device: device,
            generation: generation,
            position: device.position,
            baseZoom: base,
            lensFactors: lensFactors.isEmpty ? [1] : lensFactors,
            minDisplayZoom: minDisplay,
            maxDisplayZoom: maxDisplay,
            currentDisplayZoom: device.videoZoomFactor / base,
            hasFlash: photoOutput.supportedFlashModes.contains(.on),
            isRAWSupported: rawSupported,
            biasRange: lower...upper)
    }

    private static func findDevice(position: AVCaptureDevice.Position) -> AVCaptureDevice? {
        if position == .front {
            return AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front)
        }
        // Virtual devices switch lenses seamlessly (and do auto macro).
        let types: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera,
        ]
        for type in types {
            if let device = AVCaptureDevice.default(type, for: .video, position: .back) { return device }
        }
        return nil
    }

    /// `base` is the `videoZoomFactor` of the main (1×) camera; `factors` are
    /// the native lens chips in display units, e.g. [0.5, 1, 2, 3].
    private static func lensLayout(for device: AVCaptureDevice) -> (base: CGFloat, factors: [CGFloat]) {
        guard device.position == .back else { return (1, [1]) }
        let switchOvers = device.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat($0.doubleValue) }
        var base: CGFloat = 1
        var factors: [CGFloat] = [1]
        if device.isVirtualDevice, let first = switchOvers.first, first > 1 {
            if device.constituentDevices.first?.deviceType == .builtInUltraWideCamera {
                base = first
                factors = [1 / first] + switchOvers.map { $0 / first }
            } else {
                factors = [1] + switchOvers
            }
        }
        factors = factors.map { ($0 * 10).rounded() / 10 }
        let hasTwo = factors.contains(where: { abs($0 - 2) < 0.15 })
        let hasTele = factors.contains(where: { $0 > 1.05 })
        // "2" is a crop of the main camera: always without a tele, and next to
        // the tele on 48 MP mains (iPhone 14 Pro and later), like the Camera app.
        if !hasTwo, !hasTele || hasHighResolutionMain(device), device.maxAvailableVideoZoomFactor >= base * 2 {
            factors.append(2)
        }
        return (base, factors.sorted())
    }

    private static func hasHighResolutionMain(_ device: AVCaptureDevice) -> Bool {
        let main = device.constituentDevices.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? device
        return main.formats.contains { format in
            format.supportedMaxPhotoDimensions.contains(where: { $0.width >= 8000 })
        }
    }

    /// The largest photo size with width <= 4032 (12 MP class).
    private static func preferredPhotoDimensions(_ all: [CMVideoDimensions]) -> CMVideoDimensions? {
        let area: (CMVideoDimensions) -> Int = { Int($0.width) * Int($0.height) }
        let fitting = all.filter { $0.width <= 4032 }
        return fitting.max(by: { area($0) < area($1) }) ?? all.min(by: { area($0) < area($1) })
    }

    private static func clamp(_ value: CGFloat, _ lower: CGFloat, _ upper: CGFloat) -> CGFloat {
        min(max(value, lower), upper)
    }
}

// MARK: - Photo capture delegate

/// Collects the processed photo (and the DNG, if any) of one capture.
private final class PhotoCaptureProcessor: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    private let request: CaptureController.CaptureRequest
    private let onShutter: @Sendable () -> Void
    private let completion: (Result<CapturedPhoto, Error>) -> Void
    private var processedData: Data?
    private var rawData: Data?
    private var processingError: Error?
    private var finished = false

    init(request: CaptureController.CaptureRequest,
         onShutter: @escaping @Sendable () -> Void,
         completion: @escaping (Result<CapturedPhoto, Error>) -> Void) {
        self.request = request
        self.onShutter = onShutter
        self.completion = completion
        super.init()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
        onShutter()
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        if let error {
            processingError = error
            return
        }
        guard let data = photo.fileDataRepresentation() else { return }
        if photo.isRawPhoto {
            rawData = data
        } else {
            processedData = data
        }
    }

    func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
        guard !finished else { return }
        finished = true
        if let processedData {
            completion(.success(CapturedPhoto(
                processedData: processedData,
                rawData: rawData,
                captureDate: request.date,
                isFrontCamera: request.isFrontCamera)))
        } else {
            completion(.failure(error ?? processingError ?? CameraServiceError.captureFailed))
        }
    }
}
