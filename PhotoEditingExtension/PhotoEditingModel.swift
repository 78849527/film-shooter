import Combine
import CoreImage
import Foundation
import Photos
import UIKit

/// Standalone extension editor: no AppModel, camera or photo-library permissions.
/// The host Photos app owns all input/output files and undo history.
@MainActor
final class PhotoEditingModel: ObservableObject {
    struct Rendered {
        let image: UIImage
        let recipe: DevelopRecipe
        let revision: UInt64
        let milliseconds: Double
    }

    static let formatIdentifier = "io.github.filmshooter.photoedit"
    static let formatVersion = "1"
    /// Keep the first iOS 16 photo-extension export within its process memory
    /// budget. The former 4096px RGBAf input alone could exceed 190 MB on a
    /// 4:3 photo, while the open preview session still owned GPU allocations.
    static let maximumOutputLongEdge = 2048

    @Published var recipe: DevelopRecipe = {
        var r = DevelopRecipe()
        r.autoExposure = true
        return r
    }() {
        didSet {
            guard oldValue != recipe else { return }
            revision &+= 1
            hasChanges = true
            scheduleRender()
        }
    }

    @Published private(set) var rendered: Rendered?
    @Published private(set) var original: UIImage?
    @Published private(set) var isLoading = true
    @Published private(set) var isRendering = false
    @Published private(set) var isFinishing = false
    @Published private(set) var exportStage = ""
    @Published private(set) var hasChanges = false
    @Published var error: String?

    var previewMatchesSelection: Bool {
        guard let rendered else { return false }
        return rendered.revision == revision && rendered.recipe == recipe
    }

    private var input: PHContentEditingInput?
    private var session: EditSession?
    private var revision: UInt64 = 0
    private var pending = false
    private var closed = false
    private var debounceTask: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?
    private var captureDate: Date?

    static func savedRecipe(from data: PHAdjustmentData?) -> DevelopRecipe? {
        guard let data,
              data.formatIdentifier == formatIdentifier,
              data.formatVersion == formatVersion
        else { return nil }
        return try? JSONDecoder().decode(DevelopRecipe.self, from: data.data)
    }

    func begin(input: PHContentEditingInput, placeholder: UIImage) {
        cancel()
        closed = false
        self.input = input
        original = input.displaySizeImage ?? placeholder
        error = nil
        rendered = nil
        isLoading = true
        isFinishing = false
        exportStage = ""
        pending = false
        captureDate = nil

        // Do not treat restoring adjustment data as a new user edit.
        if let saved = Self.savedRecipe(from: input.adjustmentData) {
            recipe = saved
        } else {
            var initial = DevelopRecipe()
            initial.autoExposure = true
            recipe = initial
        }
        hasChanges = false

        loadingTask = Task { [weak self] in
            await self?.loadPreview()
        }
    }

    func selectFilm(_ id: String) {
        guard recipe.filmID != id else { return }
        var new = recipe
        new.selectFilm(id) // intentionally preserves the user's paper
        recipe = new
    }

    func selectPaper(_ id: String) {
        guard recipe.paperID != id else { return }
        var new = recipe
        new.paperID = id
        recipe = new
    }

    func change(_ update: (inout DevelopRecipe) -> Void) {
        var next = recipe
        update(&next)
        if next != recipe { recipe = next }
    }

    private func loadPreview() async {
        do {
            let engine = FilmEngine.shared
            try await engine.start()
            guard !closed, let original else { return }
            guard let ci = CIImage(image: original) else {
                throw EngineError.decode("无法读取照片预览")
            }

            // Decoder and GPU operations share the engine queue to avoid
            // competing memory allocations on iOS 16 / A15 devices.
            let frame = try await engine.run {
                let scaled = PhotoDecoder.prepare(ci, aspect: nil, maxLongEdge: 1600)
                return try engine.makeFrame(from: scaled)
            }
            guard !closed else { return }

            let opened = try await engine.openEditSession(
                frame: frame, recipe: recipe, previewLongEdge: 1400,
                captureDate: captureDate
            )
            guard !closed else {
                opened.close()
                return
            }
            session = opened
            isLoading = false
            await renderLoop()
        } catch {
            guard !closed else { return }
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func scheduleRender() {
        guard session != nil, !closed else { return }
        debounceTask?.cancel()
        if isRendering {
            pending = true
            session?.cancelInFlight()
            return
        }
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            await self?.renderLoop()
        }
    }

    private func renderLoop() async {
        guard !isRendering, let session, !closed else { return }
        isRendering = true
        repeat {
            pending = false
            let selected = recipe
            let ticket = revision
            do {
                let image = try await session.preview(recipe: selected)
                if !closed && !pending && ticket == revision && selected == recipe {
                    // Publish pixels and their associated recipe atomically.
                    rendered = Rendered(image: UIImage(cgImage: image.cgImage),
                                        recipe: selected, revision: ticket,
                                        milliseconds: image.elapsedMS)
                    error = nil
                }
            } catch {
                if !closed && !pending && ticket == revision && selected == recipe {
                    self.error = error.localizedDescription
                }
            }
            if ticket != revision || selected != recipe { pending = true }
        } while pending && !closed
        isRendering = false
    }

    func finish() async throws -> PHContentEditingOutput {
        guard !closed, !isFinishing, let input, let url = input.fullSizeImageURL else {
            throw EngineError.decode("系统照片没有提供完整原图")
        }
        let target = recipe
        isFinishing = true
        exportStage = "正在释放预览缓存"
        defer { isFinishing = false }

        // The extension was holding a 1600px interactive spectral session and
        // a separate rendered CGImage while allocating a 4096px 32-bit float
        // input. That peak can exceed Photos extension's memory allowance.
        // Stop and release the live session before any export allocation.
        closed = true
        revision &+= 1
        pending = false
        debounceTask?.cancel()
        loadingTask?.cancel()
        session?.cancelInFlight()
        session?.close() // enqueues the engine release on its serial queue
        session = nil
        rendered = nil
        original = nil

        let engine = FilmEngine.shared
        // The release above runs on the same serial queue as engine.run.
        // This fence waits until the session is actually destroyed.
        try await engine.run { () -> Void in }
        exportStage = "读取照片并准备显影"
        try await engine.start()
        try Task.checkCancellation()

        let output = PHContentEditingOutput(contentEditingInput: input)
        // For still Photos edits, Apple requires JPEG, with image orientation
        // already applied to the pixel data.
        let outputURL = output.renderedContentURL
        let sourceURL = url
        let edge = Self.maximumOutputLongEdge

        let frame = try await engine.run {
            let ci = try PhotoDecoder.ciImage(contentsOf: sourceURL)
            let prepared = PhotoDecoder.prepare(
                ci, aspect: nil, maxLongEdge: edge
            )
            return try engine.makeFrame(from: prepared)
        }
        exportStage = "光谱胶片显影中"
        try Task.checkCancellation()
        let params = target.engineParams(aspect: frame.aspect, purpose: .develop,
                                         captureDate: captureDate)
        let print = try await engine.develop(frame: frame, params: params)
        exportStage = "正在写入照片"
        try Task.checkCancellation()

        // Do not decode or map the entire original a second time for metadata
        // while full-resolution GPU textures are resident. Photos preserves
        // the asset's library metadata; the output JPEG carries upright pixels.
        try await Task.detached(priority: .userInitiated) {
            try PhotoDecoder.write(print.cgImage, to: outputURL, format: .jpeg,
                                   quality: 0.94, metadata: [:])
            let file = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            guard (file[.size] as? NSNumber)?.intValue ?? 0 > 1024 else {
                throw EngineError.encode
            }
        }.value

        let adjustment = try JSONEncoder().encode(target)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: Self.formatIdentifier,
            formatVersion: Self.formatVersion,
            data: adjustment
        )
        exportStage = "已生成，交回系统照片"
        return output
    }

    func cancel() {
        closed = true
        revision &+= 1
        debounceTask?.cancel()
        loadingTask?.cancel()
        session?.cancelInFlight()
        session?.close()
        session = nil
        input = nil
    }
}
