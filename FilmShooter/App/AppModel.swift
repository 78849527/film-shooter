import Foundation
import Observation
import SwiftUI
import UIKit

/// The app's state: the film loaded in the camera, the engine, the viewfinder
/// table, the development queue and the contact sheet.
@Observable @MainActor
final class AppModel {
    enum EngineState: Equatable {
        case starting
        case ready
        case failed(String)
    }

    let settings: AppSettings
    let library: PhotoLibrary
    let camera: CameraService
    let darkroom: Darkroom
    @ObservationIgnored let luts = LUTStore()

    private(set) var engineState: EngineState = .starting

    /// What the camera develops with. Exposure here stays 0 in camera mode:
    /// exposure compensation is the camera's own (`camera.exposureBias`), so the
    /// viewfinder and the print agree.
    var recipe: DevelopRecipe {
        didSet {
            guard recipe != oldValue else { return }
            persistRecipe()
            refreshLUT()
        }
    }

    /// The viewfinder's current colour table (nil until the first bake).
    private(set) var lut: FilmLUT?
    private(set) var isBakingLUT = false

    /// The next frame number on the roll (1...rollLength).
    private(set) var frameNumber: Int
    /// A transient message for the HUD ("新胶卷已装好", errors ...).
    var banner: String?

    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var lutTask: Task<Void, Never>?

    var film: FilmStock { recipe.film }
    var paper: PrintPaper? { film.kind.usesPrintPaper ? FilmCatalog.paper(recipe.resolvedPaperID) : nil }

    /// The grain strength the viewfinder should simulate (0...2).
    var viewfinderGrain: Float {
        guard settings.viewfinderGrain else { return 0 }
        let base: Double
        switch film.kind {
        case .blackWhite: base = film.iso >= 400 ? 1.4 : 0.8
        default: base = film.iso >= 800 ? 1.3 : film.iso >= 400 ? 1.0 : film.iso >= 200 ? 0.75 : 0.5
        }
        return Float(base * recipe.grain * (recipe.format == .mm120 ? 0.5 : 1))
    }

    init() {
        let settings = AppSettings()
        let library = PhotoLibrary()
        self.settings = settings
        self.library = library
        self.camera = CameraService()
        self.darkroom = Darkroom(library: library, settings: settings)
        if let data = UserDefaults.standard.data(forKey: "recipe"),
           let r = try? JSONDecoder().decode(DevelopRecipe.self, from: data) {
            recipe = r
        } else {
            recipe = DevelopRecipe()
        }
        frameNumber = max(1, UserDefaults.standard.integer(forKey: "frameNumber"))
        lut = luts.cached(for: recipe)
    }

    // MARK: lifecycle

    /// Start the engine and bake the first table. Safe to call more than once.
    func boot() async {
        if engineState == .ready { return }
        engineState = .starting
        do {
            try await FilmEngine.shared.start()
            engineState = .ready
            ScreenshotMode.log("engine ready: \(String(cString: spk_build_info()))")
            FilmEngine.shared.warmUp(film: recipe.filmID, paper: recipe.resolvedPaperID)
            refreshLUT()
            darkroom.setForeground(true)
        } catch {
            engineState = .failed(error.localizedDescription)
            ScreenshotMode.log("engine failed: \(error.localizedDescription)")
        }
    }

    /// Called from the scene phase: GPU work is only allowed in the foreground.
    func setActive(_ active: Bool) {
        darkroom.setForeground(active)
        if active {
            Task { await camera.start() }
        } else {
            camera.stop()
            luts.cancelPrebake()
        }
    }

    // MARK: film

    func selectFilm(_ id: String) {
        guard id != recipe.filmID else { return }
        var r = recipe
        r.selectFilm(id)
        recipe = r
    }

    func selectPaper(_ id: String) {
        guard id != recipe.paperID else { return }
        recipe.paperID = id
    }

    private func persistRecipe() {
        if let data = try? JSONEncoder().encode(recipe) {
            UserDefaults.standard.set(data, forKey: "recipe")
        }
    }

    /// Bring the viewfinder table in line with the recipe: instantly from the
    /// cache, otherwise bake (only the latest request matters).
    private func refreshLUT() {
        if let cached = luts.cached(for: recipe) {
            lut = cached
            isBakingLUT = false
            luts.prebake(around: recipe)
            return
        }
        guard engineState == .ready else { return }
        lutTask?.cancel()
        let wanted = recipe
        isBakingLUT = true
        lutTask = Task { [weak self] in
            // Let a fast scroll through the carousel settle before baking.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard let self, !Task.isCancelled else { return }
            do {
                let t0 = Date()
                let table = try await self.luts.lut(for: wanted)
                ScreenshotMode.log("LUT \(wanted.filmID) in \(String(format: "%.0f", Date().timeIntervalSince(t0) * 1000)) ms")
                guard !Task.isCancelled, self.recipe == wanted else { return }
                self.lut = table
                self.isBakingLUT = false
                self.luts.prebake(around: wanted)
            } catch {
                guard !Task.isCancelled else { return }
                self.isBakingLUT = false
                ScreenshotMode.log("LUT failed: \(error.localizedDescription)")
                self.show("取景预览生成失败：\(error.localizedDescription)")
            }
        }
    }

    // MARK: shooting

    /// Fire the shutter: capture, advance the film, queue the frame for development.
    func shoot() async {
        guard camera.state == .running, !camera.isCapturing else { return }
        let recipe = self.recipe
        let aspect = settings.frameAspect.ratio
        let number = frameNumber
        do {
            let photo = try await camera.capturePhoto()
            advanceFrame()
            var r = recipe
            // A DNG is scene-linear and the phone exposes RAW low to keep the
            // highlights, so let the engine meter it; a processed HEIC is
            // already placed by the camera and develops as the viewfinder shows.
            if photo.rawData != nil { r.autoExposure = true }
            darkroom.enqueue(.capture(photo), recipe: r, aspect: aspect, frameNumber: number,
                             captureDate: photo.captureDate)
        } catch {
            show("拍摄失败：\(error.localizedDescription)")
        }
    }

    private func advanceFrame() {
        var n = frameNumber + 1
        if n > settings.rollLength {
            n = 1
            show("这卷拍完啦，已装上新胶卷")
        }
        frameNumber = n
        UserDefaults.standard.set(n, forKey: "frameNumber")
    }

    func rewindRoll() {
        frameNumber = 1
        UserDefaults.standard.set(1, forKey: "frameNumber")
    }

    /// Frames left on the roll (including the one about to be shot).
    var framesLeft: Int { max(0, settings.rollLength - frameNumber + 1) }

    // MARK: messages

    func show(_ message: String, seconds: Double = 2.4) {
        bannerTask?.cancel()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { banner = message }
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.3)) { self?.banner = nil }
        }
    }
}
