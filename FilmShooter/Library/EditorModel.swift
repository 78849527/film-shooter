import Combine
import Foundation
import UIKit

/// The darkroom editor: one photo held open in the engine while the user tries
/// films, papers and print settings on it; every change re-renders a
/// screen-sized print (the negative is cached, so print-side changes are fast).
@MainActor
final class EditorModel: ObservableObject, Identifiable {
    enum Source {
        case imported(data: Data, isRAW: Bool)
        case existing(DevelopedPhoto)
    }

    let id = UUID()
    let source: Source

    @Published var recipe: DevelopRecipe {
        didSet { if recipe != oldValue { scheduleRender(filmChanged: recipe.filmID != oldValue.filmID) } }
    }

    /// The latest rendered print (screen size).
    @Published private(set) var preview: UIImage?
    /// The photo as it came in, for press-and-hold comparison.
    @Published private(set) var original: UIImage?
    @Published private(set) var isLoading = true
    @Published private(set) var isRendering = false
    @Published private(set) var error: String?
    /// Render time of the last preview, ms.
    @Published private(set) var lastRenderMS: Double = 0

    var film: FilmStock { recipe.film }
    var canDevelop: Bool { error == nil && !isLoading }

    private var session: EditSession?
    private var isClosed = false
    private var renderTask: Task<Void, Never>?
    private var pending = false
    private let quality: Int
    private var captureDate: Date?

    init(source: Source, recipe: DevelopRecipe, outputLongEdge: Int) {
        self.source = source
        var r = recipe
        // Imported photos have not been metered by our camera.
        if case .imported = source { r.autoExposure = true; r.exposureEV = 0 }
        self.recipe = r
        self.quality = outputLongEdge
    }

    /// Decode the photo, open it in the engine and render the first print.
    func load(library: PhotoLibrary) async {
        isLoading = true
        error = nil
        do {
            let data: Data
            let isRAW: Bool
            switch source {
            case .imported(let d, let raw):
                data = d; isRAW = raw
                captureDate = PhotoDecoder.captureDate(of: d)
            case .existing(let p):
                guard let u = library.originalURL(for: p) else { throw EngineError.decode("原图未保留，无法重新冲洗") }
                data = try Data(contentsOf: u, options: .mappedIfSafe)
                isRAW = p.originalIsRAW
                captureDate = p.captureDate
            }
            original = await Task.detached(priority: .userInitiated) {
                PhotoDecoder.quickPreview(of: data, maxPixel: 1800)
            }.value

            let engine = FilmEngine.shared
            let quality = self.quality
            var cropAspect: Double?
            if case .existing(let p) = source { cropAspect = p.cropAspect }
            let crop = cropAspect
            let frame: EngineFrame = try await engine.run { () throws -> EngineFrame in
                let ci = try PhotoDecoder.ciImage(from: data, isRAW: isRAW)
                // The editor works on a frame no bigger than the export.
                let prepared = PhotoDecoder.prepare(ci, aspect: crop, maxLongEdge: quality)
                return try engine.makeFrame(from: prepared)
            }
            let opened = try await engine.openEditSession(frame: frame, recipe: recipe, previewLongEdge: 1600,
                                                          captureDate: captureDate)
            // Dismissed while loading: release the engine session right away.
            if isClosed { opened.close(); return }
            session = opened
            isLoading = false
            await renderNow()
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    private func scheduleRender(filmChanged: Bool) {
        guard session != nil else { return }
        if isRendering {
            pending = true
            if filmChanged { session?.cancelInFlight() }
            return
        }
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            // Short debounce: slider drags coalesce, taps feel immediate.
            try? await Task.sleep(nanoseconds: filmChanged ? 60_000_000 : 30_000_000)
            guard !Task.isCancelled else { return }
            await self?.renderNow()
        }
    }

    private func renderNow() async {
        guard let session else { return }
        isRendering = true
        repeat {
            pending = false
            let wanted = recipe
            do {
                let img = try await session.preview(recipe: wanted)
                lastRenderMS = img.elapsedMS
                if !pending {
                    preview = UIImage(cgImage: img.cgImage)
                }
                error = nil
            } catch {
                if !pending { self.error = error.localizedDescription }
            }
        } while pending
        isRendering = false
    }

    /// Release the engine session (frees its GPU planes).
    func close() {
        isClosed = true
        renderTask?.cancel()
        session?.close()
        session = nil
    }

    /// Hand the photo to the darkroom for a full-resolution development.
    func develop(into darkroom: Darkroom, frameNumber: Int) {
        let r = recipe
        close()
        switch source {
        case .imported(let data, let isRAW):
            darkroom.enqueue(.imported(data: data, isRAW: isRAW), recipe: r, aspect: nil,
                             frameNumber: frameNumber, captureDate: captureDate ?? Date())
        case .existing(let p):
            darkroom.enqueue(.redevelop(p), recipe: r, aspect: p.cropAspect, frameNumber: p.frameNumber,
                             captureDate: p.captureDate)
        }
    }
}
