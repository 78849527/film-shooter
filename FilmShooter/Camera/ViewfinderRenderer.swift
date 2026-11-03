import CoreVideo
import Foundation
import Metal
import QuartzCore

/// Process-wide Metal objects, shared by the viewfinder and the engine bridge.
enum MetalContext {
    static let device: any MTLDevice = {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not available on this device")
        }
        return device
    }()

    static let queue: any MTLCommandQueue = {
        guard let queue = device.makeCommandQueue() else {
            fatalError("Cannot create a Metal command queue")
        }
        queue.label = "FilmShooter"
        return queue
    }()
}

/// Must match `VFUniforms` in Viewfinder.metal (64 bytes).
private struct ViewfinderUniforms {
    var uvScale: SIMD2<Float>
    var uvOffset: SIMD2<Float>
    var pixelUV: SIMD2<Float>
    var lutScaleA: Float
    var lutBiasA: Float
    var lutScaleB: Float
    var lutBiasB: Float
    var mixT: Float
    var grain: Float
    var mono: Float
    var supersample: Float
    var frame: UInt32
    var pad: UInt32 = 0
}

private enum ViewfinderPipeline {
    /// Built lazily (thread-safe) on the render queue at the first frame.
    static let state: (any MTLRenderPipelineState)? = {
        let device = MetalContext.device
        guard let library = device.makeDefaultLibrary(),
              let vertex = library.makeFunction(name: "vf_vertex"),
              let fragment = library.makeFunction(name: "vf_fragment") else { return nil }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "Viewfinder"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }()
}

private struct LUTTexture {
    let id: UUID
    let texture: any MTLTexture
    let scale: Float
    let bias: Float
}

/// Draws camera frames through the film LUT into a `CAMetalLayer`.
///
/// Frames are coalesced (only the newest is drawn) and rendered on a private
/// queue, never on the main thread; up to three frames are in flight.
final class ViewfinderRenderer: @unchecked Sendable {
    static let fadeDuration: CFTimeInterval = 0.35

    let metalLayer: CAMetalLayer

    private let renderQueue = DispatchQueue(label: "io.github.filmshooter.viewfinder", qos: .userInteractive)
    private let inflight = DispatchSemaphore(value: 3)
    private let textureCache: CVMetalTextureCache?

    // Shared state, guarded by `lock`.
    private let lock = NSLock()
    private var isActive = false
    private var renderScheduled = false
    private var redrawRequested = false
    private var pendingFrame: CVPixelBuffer?
    private var lastFrame: CVPixelBuffer?
    private var drawablePixelSize: CGSize = .zero
    private var grainAmount: Float = 1
    private var monochrome = false
    private var currentLUT: LUTTexture?
    private var previousLUT: LUTTexture?
    private var fadeStart: CFTimeInterval = 0
    private var hasRendered = false

    // Render-queue only.
    private var frameIndex: UInt32 = 0
    private var lastRenderTime: CFTimeInterval = 0
    private var fadeTickScheduled = false

    // Main-thread only.
    private var requestedLUTID: UUID?
    private weak var source: CameraFrameSource?
    private var sourceToken: UInt64 = 0

    init(layer: CAMetalLayer) {
        metalLayer = layer
        layer.device = MetalContext.device
        layer.pixelFormat = .bgra8Unorm
        layer.framebufferOnly = true
        layer.isOpaque = true
        layer.maximumDrawableCount = 3
        layer.presentsWithTransaction = false

        var cache: CVMetalTextureCache?
        _ = CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, MetalContext.device, nil, &cache)
        textureCache = cache

        let identity = FilmLUT.identity()
        requestedLUTID = identity.id
        renderQueue.async { [weak self] in self?.installLUT(identity) }
    }

    deinit {
        source?.removeOnFrame(token: sourceToken)
    }

    // MARK: Configuration (main thread)

    /// Subscribes to `frames` (replacing whichever renderer was subscribed).
    func attach(to frames: CameraFrameSource) {
        if source === frames { return }
        detach()
        source = frames
        sourceToken = frames.setOnFrame { [weak self] pixelBuffer in
            self?.submit(pixelBuffer)
        }
        if let latest = frames.latestFrame() { submit(latest) }
    }

    func detach() {
        source?.removeOnFrame(token: sourceToken)
        source = nil
    }

    /// Rendering only happens while active (the view is in a window).
    func setActive(_ active: Bool) {
        lock.lock()
        isActive = active
        if !active {
            pendingFrame = nil
            lastFrame = nil
            redrawRequested = false
        }
        lock.unlock()
        if !active, let cache = textureCache {
            renderQueue.async { CVMetalTextureCacheFlush(cache, 0) }
        }
    }

    func setDrawableSize(_ size: CGSize) {
        if metalLayer.drawableSize != size { metalLayer.drawableSize = size }
        lock.lock()
        let changed = drawablePixelSize != size
        drawablePixelSize = size
        lock.unlock()
        if changed { requestRedraw() }
    }

    /// `grain` is the film's grain strength, 0...2.
    func setLook(grain: Float, monochrome mono: Bool) {
        let amount = max(0, min(2, grain))
        lock.lock()
        let changed = amount != grainAmount || mono != monochrome
        grainAmount = amount
        monochrome = mono
        lock.unlock()
        if changed { requestRedraw() }
    }

    /// Cross-fades to `lut`. `nil` keeps the current table.
    func setLUT(_ lut: FilmLUT?) {
        guard let lut, lut.id != requestedLUTID else { return }
        requestedLUTID = lut.id
        renderQueue.async { [weak self] in self?.installLUT(lut) }
    }

    // MARK: Frame intake (any thread)

    func submit(_ pixelBuffer: CVPixelBuffer) {
        lock.lock()
        guard isActive else { lock.unlock(); return }
        pendingFrame = pixelBuffer
        let schedule = !renderScheduled
        renderScheduled = true
        lock.unlock()
        if schedule { renderQueue.async { [weak self] in self?.render() } }
    }

    /// Redraws the last frame (after a look or size change, or during a fade).
    private func requestRedraw() {
        lock.lock()
        guard isActive, lastFrame != nil || pendingFrame != nil else { lock.unlock(); return }
        redrawRequested = true
        let schedule = !renderScheduled
        renderScheduled = true
        lock.unlock()
        if schedule { renderQueue.async { [weak self] in self?.render() } }
    }

    // MARK: Render queue

    private func installLUT(_ lut: FilmLUT) {
        guard let texture = Self.makeLUTTexture(lut) else { return }
        let n = Float(lut.size)
        let entry = LUTTexture(id: lut.id, texture: texture, scale: (n - 1) / n, bias: 0.5 / n)
        let now = CACurrentMediaTime()
        lock.lock()
        if hasRendered, let current = currentLUT {
            // Mid-fade, restart from whichever end is closer to what is on screen.
            let progress = (now - fadeStart) / Self.fadeDuration
            if previousLUT == nil || progress >= 0.5 { previousLUT = current }
            fadeStart = now
        } else {
            previousLUT = nil
        }
        currentLUT = entry
        lock.unlock()
        requestRedraw()
    }

    private func render() {
        inflight.wait()
        var committed = false
        defer { if !committed { inflight.signal() } }

        lock.lock()
        renderScheduled = false
        var frame: CVPixelBuffer?
        if let pending = pendingFrame {
            frame = pending
            lastFrame = pending
            pendingFrame = nil
        } else if redrawRequested {
            frame = lastFrame
        }
        redrawRequested = false
        let active = isActive
        let size = drawablePixelSize
        let current = currentLUT
        var previous = previousLUT
        let start = fadeStart
        let grain = grainAmount
        let mono = monochrome
        lock.unlock()

        guard active, let frame, let current, size.width >= 1, size.height >= 1,
              let pipeline = ViewfinderPipeline.state, let cache = textureCache,
              CVPixelBufferGetPixelFormatType(frame) == kCVPixelFormatType_32BGRA else { return }

        // Cross-fade progress, ease-in-out.
        let now = CACurrentMediaTime()
        var mixT: Float = 1
        if previous != nil {
            let raw = min(1, max(0, (now - start) / Self.fadeDuration))
            if raw >= 1 {
                previous = nil
                lock.lock()
                if fadeStart == start { previousLUT = nil }
                lock.unlock()
            } else {
                mixT = Float(raw * raw * (3 - 2 * raw))
            }
        }

        // Wrap the camera buffer as a texture (no copy).
        let width = CVPixelBufferGetWidth(frame)
        let height = CVPixelBufferGetHeight(frame)
        var cvTextureOut: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, frame, nil, .bgra8Unorm, width, height, 0, &cvTextureOut)
        guard status == kCVReturnSuccess, let cvTexture = cvTextureOut,
              let cameraTexture = CVMetalTextureGetTexture(cvTexture) else { return }

        guard let drawable = metalLayer.nextDrawable() else { return }
        let target = drawable.texture

        // Aspect-fill the frame into the drawable, centred.
        let viewAspect = Float(target.width) / Float(max(1, target.height))
        let frameAspect = Float(width) / Float(max(1, height))
        var uvScale = SIMD2<Float>(1, 1)
        if frameAspect > viewAspect {
            uvScale.x = viewAspect / frameAspect
        } else {
            uvScale.y = frameAspect / viewAspect
        }
        let targetSize = SIMD2<Float>(Float(max(1, target.width)), Float(max(1, target.height)))
        // Source texels per drawable pixel; above ~1.4 bilinear alone would alias.
        let downscale = Float(width) * uvScale.x / targetSize.x
        let lutA = previous ?? current
        frameIndex &+= 1
        var uniforms = ViewfinderUniforms(
            uvScale: uvScale,
            uvOffset: (SIMD2<Float>(1, 1) - uvScale) * 0.5,
            pixelUV: uvScale / targetSize,
            lutScaleA: lutA.scale,
            lutBiasA: lutA.bias,
            lutScaleB: current.scale,
            lutBiasB: current.bias,
            mixT: mixT,
            grain: 0.035 * grain,
            mono: mono ? 1 : 0,
            supersample: downscale > 1.4 ? 1 : 0,
            frame: frameIndex)

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .dontCare
        pass.colorAttachments[0].storeAction = .store

        guard let commandBuffer = MetalContext.queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(cameraTexture, index: 0)
        encoder.setFragmentTexture(lutA.texture, index: 1)
        encoder.setFragmentTexture(current.texture, index: 2)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<ViewfinderUniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()

        let semaphore = inflight
        commandBuffer.addCompletedHandler { _ in
            // Keep the camera buffer mapped until the GPU is done with it.
            withExtendedLifetime(cvTexture) {}
            semaphore.signal()
        }
        commandBuffer.present(drawable)
        commandBuffer.commit()
        committed = true

        lastRenderTime = now
        lock.lock()
        hasRendered = true
        lock.unlock()

        // Keep the fade smooth even if the camera delivers slowly or is paused.
        if mixT < 1, !fadeTickScheduled {
            fadeTickScheduled = true
            renderQueue.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                self?.fadeTick()
            }
        }
    }

    private func fadeTick() {
        fadeTickScheduled = false
        if CACurrentMediaTime() - lastRenderTime > 0.012 {
            requestRedraw()
        } else {
            lock.lock()
            let fading = previousLUT != nil
            lock.unlock()
            if fading {
                fadeTickScheduled = true
                renderQueue.asyncAfter(deadline: .now() + 1.0 / 120.0) { [weak self] in
                    self?.fadeTick()
                }
            }
        }
    }

    private static func makeLUTTexture(_ lut: FilmLUT) -> (any MTLTexture)? {
        let size = lut.size
        guard size >= 2, lut.rgba.count == size * size * size * 4 else { return nil }
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = size
        descriptor.height = size
        descriptor.depth = size
        descriptor.mipmapLevelCount = 1
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = MetalContext.device.makeTexture(descriptor: descriptor) else { return nil }
        texture.label = "FilmLUT \(lut.key)"
        lut.rgba.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size),
                            mipmapLevel: 0,
                            slice: 0,
                            withBytes: base,
                            bytesPerRow: lut.bytesPerRow,
                            bytesPerImage: lut.bytesPerImage)
        }
        return texture
    }
}
