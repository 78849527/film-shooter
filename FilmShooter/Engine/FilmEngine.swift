import Foundation
import Metal
import CoreGraphics
import CoreImage
import ImageIO
import UIKit

enum EngineError: LocalizedError {
    case resourcesMissing
    case startFailed(String)
    case notReady
    case call(String, String)
    case decode(String)
    case encode

    var errorDescription: String? {
        switch self {
        case .resourcesMissing: return "胶片引擎资源缺失"
        case .startFailed(let m): return "胶片引擎启动失败：\(m)"
        case .notReady: return "胶片引擎尚未就绪"
        case .call(let f, let m): return "\(f) 失败：\(m)"
        case .decode(let m): return "无法读取照片：\(m)"
        case .encode: return "无法写出照片"
        }
    }
}

/// A frame ready for the engine: float32 RGBA, linear ProPhoto, top row first,
/// in a shared buffer on the engine's own device.
struct EngineFrame {
    let buffer: MTLBuffer
    let width: Int
    let height: Int
    var aspect: Double { Double(width) / Double(max(height, 1)) }
}

/// A picture the engine rendered: 16-bit, encoded in the colour space the
/// recipe asked for (Display P3 for developments, sRGB for tables). The pixels
/// stay in the engine's own buffer and are released with the image.
final class EngineImage: @unchecked Sendable {
    let cgImage: CGImage
    let elapsedMS: Double
    var width: Int { cgImage.width }
    var height: Int { cgImage.height }

    init(cgImage: CGImage, elapsedMS: Double) {
        self.cgImage = cgImage
        self.elapsedMS = elapsedMS
    }
}

/// The spectral film engine (SpektraLab's C++/Metal engine) behind its C ABI.
///
/// Every call runs on one serial queue: the engine owns large GPU planes, and
/// one render at a time is both what a phone's memory allows and what keeps
/// the engine's per-thread error reporting coherent.
final class FilmEngine: @unchecked Sendable {
    static let shared = FilmEngine()

    let device: MTLDevice = MetalContext.device
    let queue = DispatchQueue(label: "filmshooter.engine", qos: .userInitiated)

    private var engine: OpaquePointer?
    private var startError: String?

    /// The Core Image context every decode shares (contexts cache kernels).
    let ciContext: CIContext

    static let displayP3 = CGColorSpace(name: CGColorSpace.displayP3)!
    static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    static let linearP3 = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!

    /// Linear ProPhoto (ROMM primaries, D50, gamma 1): the engine's input convention.
    static let linearProPhoto: CGColorSpace = {
        let d50: [CGFloat] = [0.9642, 1.0000, 0.8249]
        let black: [CGFloat] = [0, 0, 0]
        let gamma: [CGFloat] = [1, 1, 1]
        let primaries: [CGFloat] = [
            0.7976749, 0.2880402, 0.0000000,
            0.1351917, 0.7118741, 0.0000000,
            0.0313534, 0.0000857, 0.8252100,
        ]
        let space = d50.withUnsafeBufferPointer { wp in
            black.withUnsafeBufferPointer { bp in
                gamma.withUnsafeBufferPointer { gp in
                    primaries.withUnsafeBufferPointer { mp in
                        CGColorSpace(calibratedRGBWhitePoint: wp.baseAddress!, blackPoint: bp.baseAddress,
                                     gamma: gp.baseAddress!, matrix: mp.baseAddress)
                    }
                }
            }
        }
        return space ?? CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
    }()

    private init() {
        ciContext = CIContext(mtlDevice: MetalContext.device, options: [
            .workingColorSpace: FilmEngine.linearP3,
            .workingFormat: CIFormat.RGBAh,
            .cacheIntermediates: false,
            .highQualityDownsample: true,
        ])
    }

    static var resourcesURL: URL? {
        Bundle.main.url(forResource: "spektrafilm_constants", withExtension: "bin",
                        subdirectory: "EngineResources")?.deletingLastPathComponent()
    }

    // MARK: lifecycle

    /// Create the engine (loads the baked tables and compiles nothing: the
    /// kernels ship precompiled). Idempotent.
    func start() async throws {
        try await run { [self] in
            if engine != nil { return }
            guard let dir = Self.resourcesURL else { throw EngineError.resourcesMissing }
            let created = dir.path.withCString { path in
                spk_engine_create(path, Unmanaged.passUnretained(device).toOpaque())
            }
            guard let created else {
                let message = String(cString: spk_last_error(nil))
                throw EngineError.startFailed(message.isEmpty ? "unknown" : message)
            }
            engine = created
        }
    }

    var isReady: Bool { queue.sync { engine != nil } }

    /// Pay the fixed per-stock-pair setup ahead of time.
    func warmUp(film: String, paper: String) {
        queue.async { [self] in
            guard let engine else { return }
            var reply: UnsafeMutablePointer<CChar>?
            _ = film.withCString { f in paper.withCString { p in spk_warm_up(engine, f, p, &reply) } }
            if let reply { spk_string_free(reply) }
        }
    }

    // MARK: helpers

    /// Run `body` on the engine queue inside an autorelease pool (metal-cpp
    /// hands back autoreleased objects).
    func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            queue.async {
                autoreleasepool {
                    do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
                }
            }
        }
    }

    fileprivate func lastError() -> String {
        String(cString: spk_last_error(engine))
    }

    fileprivate func requireEngine() throws -> OpaquePointer {
        guard let engine else { throw EngineError.notReady }
        return engine
    }

    /// Turn a result into a CGImage that owns the engine's pixels; the result
    /// (texture and rows) is freed when Core Graphics releases the data.
    fileprivate static func image(from result: inout spk_result, space: CGColorSpace) -> CGImage? {
        guard let rows = result.rgba16, result.width > 0, result.height > 0 else {
            spk_result_free(&result)
            return nil
        }
        let width = Int(result.width), height = Int(result.height)
        let stride = Int(result.row_stride_px) * 8
        let boxed = UnsafeMutablePointer<spk_result>.allocate(capacity: 1)
        boxed.initialize(to: result)
        let release: CGDataProviderReleaseDataCallback = { info, _, _ in
            guard let info else { return }
            let r = info.assumingMemoryBound(to: spk_result.self)
            spk_result_free(r)
            r.deinitialize(count: 1)
            r.deallocate()
        }
        guard let provider = CGDataProvider(dataInfo: boxed, data: UnsafeRawPointer(rows),
                                            size: stride * height, releaseData: release) else {
            spk_result_free(boxed)
            boxed.deinitialize(count: 1)
            boxed.deallocate()
            return nil
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue
                                | CGBitmapInfo.byteOrder16Little.rawValue)
        return CGImage(width: width, height: height, bitsPerComponent: 16, bitsPerPixel: 64,
                       bytesPerRow: stride, space: space, bitmapInfo: info, provider: provider,
                       decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    // MARK: frames

    /// Render a Core Image picture into an engine frame (linear ProPhoto float32).
    func makeFrame(from image: CIImage) throws -> EngineFrame {
        guard !image.extent.isInfinite, !image.extent.isEmpty else { throw EngineError.decode("空图像") }
        let extent = image.extent.integral
        let width = Int(extent.width), height = Int(extent.height)
        let placed = image.transformed(by: .init(translationX: -extent.origin.x, y: -extent.origin.y))
        guard let buffer = device.makeBuffer(length: width * height * 16, options: .storageModeShared) else {
            throw EngineError.decode("内存不足")
        }
        autoreleasepool {
            ciContext.render(placed, toBitmap: buffer.contents(), rowBytes: width * 16,
                             bounds: CGRect(x: 0, y: 0, width: width, height: height),
                             format: .RGBAf, colorSpace: Self.linearProPhoto)
        }
        return EngineFrame(buffer: buffer, width: width, height: height)
    }

    // MARK: one-shot development

    /// Open, develop at full resolution, close. Returns the print in Display P3.
    func develop(frame: EngineFrame, params: [String: Any]) async throws -> EngineImage {
        try await run { [self] in
            let engine = try requireEngine()
            let session = try open(engine: engine, frame: frame, params: params)
            defer { spk_session_release(session) }
            return try render(session: session, tier: "full", reprint: true, space: Self.displayP3)
        }
    }

    fileprivate func open(engine: OpaquePointer, frame: EngineFrame, params: [String: Any]) throws -> OpaquePointer {
        var image = spk_device_image(buffer: Unmanaged.passUnretained(frame.buffer).toOpaque(),
                                     width: UInt32(frame.width), height: UInt32(frame.height), channels: 4)
        var reply: UnsafeMutablePointer<CChar>?
        let json = params.jsonString
        let session = json.withCString { d in
            withUnsafePointer(to: &image) { spk_open_device(engine, $0, d, &reply) }
        }
        if let reply { spk_string_free(reply) }
        guard let session else { throw EngineError.call("spk_open", lastError()) }
        return session
    }

    fileprivate func render(session: OpaquePointer, tier: String, reprint: Bool,
                            space: CGColorSpace) throws -> EngineImage {
        var result = spk_result()
        let status = tier.withCString { t in
            reprint ? spk_reprint(session, t, &result) : spk_render(session, t, &result)
        }
        guard status == 0 else {
            throw EngineError.call(reprint ? "spk_reprint" : "spk_render", lastError())
        }
        let elapsed = result.elapsed_ms
        guard let cg = Self.image(from: &result, space: space) else {
            throw EngineError.call("spk_render", "空结果")
        }
        return EngineImage(cgImage: cg, elapsedMS: elapsed)
    }

    // MARK: viewfinder tables

    /// Bake the recipe's colour response into a 3D table for the viewfinder.
    /// The grid is handed in as sRGB-encoded values and comes back sRGB-encoded.
    func bakeLUT(recipe: DevelopRecipe, size: Int = 33) async throws -> FilmLUT {
        let key = Self.lutKey(recipe, size: size)
        return try await run { [self] in
            let engine = try requireEngine()
            let n = size
            let width = n * n, height = n
            var grid = [Float](repeating: 1, count: width * height * 4)
            let d = Float(n - 1)
            for b in 0..<n {
                for g in 0..<n {
                    for r in 0..<n {
                        // pixel (x = r + g*n, y = b)
                        let i = (b * width + g * n + r) * 4
                        grid[i] = Float(r) / d
                        grid[i + 1] = Float(g) / d
                        grid[i + 2] = Float(b) / d
                    }
                }
            }
            let params = recipe.engineParams(aspect: Double(width) / Double(height), purpose: .lut)
            var reply: UnsafeMutablePointer<CChar>?
            let session: OpaquePointer? = grid.withUnsafeBufferPointer { px in
                var image = spk_image(data: px.baseAddress, width: UInt32(width), height: UInt32(height), channels: 4)
                return params.jsonString.withCString { delta in
                    withUnsafePointer(to: &image) { spk_open(engine, $0, delta, &reply) }
                }
            }
            if let reply { spk_string_free(reply) }
            guard let session else { throw EngineError.call("spk_open", lastError()) }
            defer { spk_session_release(session) }

            var result = spk_result()
            let status = "full".withCString { spk_render(session, $0, &result) }
            guard status == 0, let rows = result.rgba16 else {
                if status == 0 { spk_result_free(&result) }
                throw EngineError.call("spk_render", lastError())
            }
            defer { spk_result_free(&result) }
            let stride = Int(result.row_stride_px) * 4
            var out = [Float16](repeating: 1, count: n * n * n * 4)
            let scale = Float(1) / 65535
            for b in 0..<n {
                let row = rows + b * stride
                for g in 0..<n {
                    for r in 0..<n {
                        let src = (g * n + r) * 4
                        let dst = ((b * n + g) * n + r) * 4
                        out[dst] = Float16(Float(row[src]) * scale)
                        out[dst + 1] = Float16(Float(row[src + 1]) * scale)
                        out[dst + 2] = Float16(Float(row[src + 2]) * scale)
                        out[dst + 3] = 1
                    }
                }
            }
            return FilmLUT(size: n, rgba: out, key: key)
        }
    }

    static func lutKey(_ r: DevelopRecipe, size: Int) -> String {
        let film = r.film
        var k = "v1|\(size)|\(r.filmID)|\(r.resolvedPaperID)|\(String(format: "%.2f", r.exposureEV))"
        if film.kind.usesPrintPaper {
            k += String(format: "|%.2f|%.2f|%.2f", r.printBrightness, r.warmth, r.tint)
        }
        return k
    }

    // MARK: interactive sessions

    func openEditSession(frame: EngineFrame, recipe: DevelopRecipe, previewLongEdge: Int,
                         captureDate: Date?) async throws -> EditSession {
        var params = recipe.engineParams(aspect: frame.aspect, purpose: .develop, captureDate: captureDate)
        params["preview_long_edge"] = max(800, min(8192, previewLongEdge))
        let session = try await run { [self] in
            let engine = try requireEngine()
            return try open(engine: engine, frame: frame, params: params)
        }
        return EditSession(engine: self, session: session, params: params, aspect: frame.aspect,
                           captureDate: captureDate)
    }

    fileprivate func setParams(session: OpaquePointer, delta: [String: Any]) throws {
        var reply: UnsafeMutablePointer<CChar>?
        let status = delta.jsonString.withCString { spk_set_params(session, $0, &reply) }
        if let reply { spk_string_free(reply) }
        guard status == 0 else { throw EngineError.call("spk_set_params", lastError()) }
    }

    fileprivate func cancel(session: OpaquePointer) {
        spk_cancel(session, nil)
    }
}

/// One frame held open in the engine for interactive editing: the negative is
/// cached, so print-side changes reprint in milliseconds.
final class EditSession: @unchecked Sendable {
    private let engine: FilmEngine
    private var session: OpaquePointer?
    private var params: [String: Any]
    let aspect: Double
    let captureDate: Date?

    /// Keys that only affect the print stage (the cached negative survives).
    private static let printKeys: Set<String> = [
        "print_stock", "print_exposure", "y_filter_shift", "m_filter_shift", "filter_shift_scale",
        "c_filter_neutral", "m_filter_neutral", "y_filter_neutral", "glare_active", "scan_film",
        "output_color_space", "output_cctf_encoding", "extended_dynamic_range", "preview_long_edge",
    ]

    fileprivate init(engine: FilmEngine, session: OpaquePointer, params: [String: Any], aspect: Double,
                     captureDate: Date?) {
        self.engine = engine
        self.session = session
        self.params = params
        self.aspect = aspect
        self.captureDate = captureDate
    }

    deinit {
        if let s = session {
            engine.queue.async { spk_session_release(s) }
        }
    }

    func close() {
        guard let s = session else { return }
        session = nil
        engine.queue.async { spk_session_release(s) }
    }

    /// Ask the render in flight to stop at its next node boundary.
    func cancelInFlight() {
        if let s = session { engine.cancel(session: s) }
    }

    /// Apply `recipe` and render the screen-sized tier.
    func preview(recipe: DevelopRecipe) async throws -> EngineImage {
        try await apply(recipe: recipe, tier: "live")
    }

    /// Apply `recipe` and render at full resolution.
    func full(recipe: DevelopRecipe) async throws -> EngineImage {
        try await apply(recipe: recipe, tier: "full")
    }

    private func apply(recipe: DevelopRecipe, tier: String) async throws -> EngineImage {
        var next = recipe.engineParams(aspect: aspect, purpose: .develop, captureDate: captureDate)
        next["preview_long_edge"] = params["preview_long_edge"]
        next.removeValue(forKey: "product_defaults")
        return try await engine.run { [self] in
            guard let session else { throw EngineError.notReady }
            var delta: [String: Any] = [:]
            for (k, v) in next where !Self.same(params[k], v) { delta[k] = v }
            var shootChanged = false
            if !delta.isEmpty {
                shootChanged = delta.keys.contains { !Self.printKeys.contains($0) }
                try engine.setParams(session: session, delta: delta)
                for (k, v) in delta { params[k] = v }
            }
            // A film-side change re-runs the film for this tier; otherwise the
            // cached negative is reprinted.
            return try engine.render(session: session, tier: tier, reprint: !shootChanged,
                                     space: FilmEngine.displayP3)
        }
    }

    private static func same(_ a: Any?, _ b: Any) -> Bool {
        guard let a else { return false }
        switch (a, b) {
        case let (x as Bool, y as Bool): return x == y
        case let (x as Int, y as Int): return x == y
        case let (x as Double, y as Double): return abs(x - y) < 1e-9
        case let (x as String, y as String): return x == y
        case let (x as NSNumber, y as NSNumber): return x == y
        default: return false
        }
    }
}
