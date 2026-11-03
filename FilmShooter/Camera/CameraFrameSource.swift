import AVFoundation
import CoreVideo

/// Receives the viewfinder video frames from `AVCaptureVideoDataOutput`.
///
/// Frames arrive upright for portrait and, for the front camera, already
/// mirrored (the capture connection does both), as 32BGRA sRGB pixel buffers.
/// Only the latest frame is kept. All members are thread-safe.
final class CameraFrameSource: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var latest: CVPixelBuffer?
    private var handler: ((CVPixelBuffer) -> Void)?
    private var handlerToken: UInt64 = 0
    private var nextFrameCallback: (@Sendable () -> Void)?

    /// The single frame subscriber, called on the capture queue for every
    /// frame. Setting it replaces the previous subscriber.
    var onFrame: ((CVPixelBuffer) -> Void)? {
        get {
            lock.lock(); defer { lock.unlock() }
            return handler
        }
        set { setOnFrame(newValue) }
    }

    /// Installs `handler` as the subscriber and returns a token that
    /// `removeOnFrame(token:)` uses to remove it only if it is still current.
    @discardableResult
    func setOnFrame(_ newHandler: ((CVPixelBuffer) -> Void)?) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        handlerToken &+= 1
        handler = newHandler
        return handlerToken
    }

    /// Removes the subscriber installed with `token` (no-op if replaced since).
    func removeOnFrame(token: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if token == handlerToken { handler = nil }
    }

    /// The most recent frame (upright, mirrored for the front camera).
    func latestFrame() -> CVPixelBuffer? {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    /// Drops the retained frame (returns its buffer to the capture pool).
    func clearLatestFrame() {
        lock.lock(); defer { lock.unlock() }
        latest = nil
    }

    /// Calls `block` once, on the capture queue, when the next frame arrives.
    func notifyOnNextFrame(_ block: @escaping @Sendable () -> Void) {
        lock.lock(); defer { lock.unlock() }
        nextFrameCallback = block
    }

    /// Deliver a frame as if the camera had (screenshot mode, no camera).
    func inject(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        latest = pixelBuffer
        let subscriber = handler
        let once = nextFrameCallback
        nextFrameCallback = nil
        lock.unlock()
        subscriber?(pixelBuffer)
        once?()
    }

    // MARK: AVCaptureVideoDataOutputSampleBufferDelegate

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        lock.lock()
        latest = pixelBuffer
        let subscriber = handler
        let once = nextFrameCallback
        nextFrameCallback = nil
        lock.unlock()
        subscriber?(pixelBuffer)
        once?()
    }
}
