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

    // Standard Combine publishing is required for iOS 16's @ObservedObject:
    // the explicit didSet objectWillChange from previous ports notified
    // after the update and could leave SwiftUI one change behind.
    @Published var recipe: DevelopRecipe {
        didSet {
            guard recipe != oldValue else { return }
            revision &+= 1
            // Auto exposure, grain and halation act on the negative, not the
            // print. Prioritise the latest adjustment instead of waiting for
            // a now-obsolete GPU render to finish.
            let shootChanged = recipe.filmID != oldValue.filmID
                || recipe.autoExposure != oldValue.autoExposure
                || recipe.exposureEV != oldValue.exposureEV
                || recipe.grain != oldValue.grain
                || recipe.halation != oldValue.halation
                || recipe.format != oldValue.format
            scheduleRender(shootChanged: shootChanged)
        }
    }

    /// Image and the recipe that actually produced it are a SINGLE published
    /// value. Publishing previewRecipe separately before preview previously
    /// let SwiftUI label the old image as belonging to the next film.
    struct RenderedPreview {
        let image: UIImage
        let recipe: DevelopRecipe
        let elapsedMS: Double
        let revision: UInt64
    }
    @Published private(set) var renderedPreview: RenderedPreview?
    var preview: UIImage? { renderedPreview?.image }
    var previewRecipe: DevelopRecipe? { renderedPreview?.recipe }
    var lastRenderMS: Double { renderedPreview?.elapsedMS ?? 0 }

    /// The photo as it came in, for press-and-hold comparison.
    @Published private(set) var original: UIImage?
    @Published private(set) var isLoading = true
    @Published private(set) var isRendering = false
    @Published private(set) var error: String?
    var film: FilmStock { recipe.film }

    /// Commit the new film and its default paper with one recipe write.
    func selectFilm(_ id: String) {
        guard id != recipe.filmID else { return }
        var updated = recipe
        updated.selectFilm(id)
        recipe = updated
    }

    var previewMatchesSelection: Bool {
        guard let frame = renderedPreview else { return false }
        return frame.revision == revision && frame.recipe == recipe
    }
    // Do not let a render request be exported before its film + paper have
    // actually appeared in the preview the user approved.
    var canDevelop: Bool { error == nil && !isLoading && !isRendering && previewMatchesSelection }

    private var session: EditSession?
    private var isClosed = false
    private var renderTask: Task<Void, Never>?
    /// Incremented on every edit. Handles A→B→A changes that otherwise
    /// let an old A render be incorrectly accepted as the latest A.
    private var revision: UInt64 = 0
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
        renderTask?.cancel()
        isLoading = true
        error = nil
        renderedPreview = nil
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
            // Keep the developing loader until a real preview has been
            // produced. Showing the empty UIImage slot here looked like a
            // black image until the user moved a slider.
            await renderNow()
            isLoading = false
        } catch {
            isLoading = false
            self.error = error.localizedDescription
        }
    }

    private func scheduleRender(shootChanged: Bool) {
        guard session != nil else { return }
        if isRendering {
            pending = true
            // On/off metering and film textures must re-expose the negative.
            // Cancel the stale frame (supported by the engine) so the latest
            // recipe can render as soon as possible.
            if shootChanged { session?.cancelInFlight() }
            return
        }
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            // Coalesce slider writes; a toggle responds on the next UI tick.
            try? await Task.sleep(nanoseconds: shootChanged ? 20_000_000 : 30_000_000)
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
            let requestRevision = revision
            do {
                let img = try await session.preview(recipe: wanted)
                if !pending && requestRevision == revision && wanted == recipe {
                    // Commit the render + all metadata atomically.
                    // A view can never observe B's label over A's pixels.
                    renderedPreview = RenderedPreview(
                        image: UIImage(cgImage: img.cgImage),
                        recipe: wanted,
                        elapsedMS: img.elapsedMS,
                        revision: requestRevision
                    )
                    error = nil
                }
            } catch {
                if !pending && requestRevision == revision && wanted == recipe {
                    self.error = error.localizedDescription
                }
            }
            if requestRevision != revision || wanted != recipe { pending = true }
        } while pending && !isClosed
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
