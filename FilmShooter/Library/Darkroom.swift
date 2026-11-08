import Combine
import Foundation
import UIKit
import CoreImage

/// One frame waiting for, or going through, development.
struct DevelopJob: Identifiable, Equatable {
    enum Phase: Equatable {
        case queued
        case developing
        case failed(String)
    }

    let id: UUID
    let recipe: DevelopRecipe
    /// A small preview of the frame as shot (shown as a "negative" while it develops).
    let preview: UIImage?
    var phase: Phase
    /// When development started, and roughly how long it should take
    /// (from the last few jobs), for a smooth progress estimate.
    var startedAt: Date?
    var expectedSeconds: Double

    static func == (a: DevelopJob, b: DevelopJob) -> Bool {
        a.id == b.id && a.phase == b.phase && a.startedAt == b.startedAt
    }
}

/// Where a frame comes from.
enum DevelopSource {
    /// Straight from the camera.
    case capture(CapturedPhoto)
    /// A photo file the user imported (bytes as in the library).
    case imported(data: Data, isRAW: Bool)
    /// Re-develop a frame already in the contact sheet from its kept original.
    case redevelop(DevelopedPhoto)
}

/// The development queue: frames go in from the shutter or the import picker
/// and come out as prints in the library (and in Photos). One at a time, on the
/// engine's queue, and only while the app is in the foreground -- iOS refuses
/// GPU work in the background.
@MainActor
final class Darkroom: ObservableObject {
    @Published private(set) var jobs: [DevelopJob] = []
    /// The most recent print, for the gallery button's thumbnail.
    @Published private(set) var lastDeveloped: DevelopedPhoto?
    /// Bumps every time a print is finished (the UI animates on it).
    @Published private(set) var completedCount = 0
    @Published private(set) var lastError: String?

    private let library: PhotoLibrary
    private let settings: AppSettings
    private var sources: [UUID: (DevelopSource, Double?, Int, Date)] = [:]
    private var worker: Task<Void, Never>?
    private var isForeground = true
    private var recentDurations: [Double] = [2.5]

    // Share must wait for the SPECIFIC developed photo, never the gallery's
    // lastDeveloped (which may belong to an earlier or unrelated job).
    private var completionWaiters: [UUID: CheckedContinuation<DevelopedPhoto, Error>] = [:]
    private var completedResults: [UUID: Result<DevelopedPhoto, Error>] = [:]

    func waitForCompletion(of jobID: UUID) async throws -> DevelopedPhoto {
        if let result = completedResults.removeValue(forKey: jobID) {
            return try result.get()
        }
        return try await withCheckedThrowingContinuation { continuation in
            completionWaiters[jobID] = continuation
        }
    }

    private func deliver(_ result: Result<DevelopedPhoto, Error>, for jobID: UUID) {
        if let waiter = completionWaiters.removeValue(forKey: jobID) {
            waiter.resume(with: result)
        } else {
            completedResults[jobID] = result
            // Only retain the latest completed jobs for a share request that
            // registers after completion; no unbounded bookkeeping.
            while completedResults.count > 24 {
                if let first = completedResults.keys.first { completedResults.removeValue(forKey: first) }
            }
        }
    }

    init(library: PhotoLibrary, settings: AppSettings) {
        self.library = library
        self.settings = settings
        lastDeveloped = library.photos.first
    }

    var isBusy: Bool { !jobs.isEmpty }
    var pendingCount: Int { jobs.filter { if case .failed = $0.phase { return false } else { return true } }.count }

    private var expected: Double {
        recentDurations.suffix(4).reduce(0, +) / Double(max(1, min(4, recentDurations.count)))
    }

    /// Queue a frame. `aspect` (long : short) crops it; `frameNumber` goes on the film edge.
    @discardableResult
    func enqueue(_ source: DevelopSource, recipe: DevelopRecipe, aspect: Double?, frameNumber: Int,
                 captureDate: Date = Date()) -> UUID {
        let id = UUID()
        var preview: UIImage?
        switch source {
        case .capture(let c): preview = PhotoDecoder.quickPreview(of: c.processedData)
        case .imported(let data, _): preview = PhotoDecoder.quickPreview(of: data)
        case .redevelop(let p): preview = library.thumbnail(for: p)
        }
        jobs.append(DevelopJob(id: id, recipe: recipe, preview: preview, phase: .queued,
                               startedAt: nil, expectedSeconds: expected))
        sources[id] = (source, aspect, frameNumber, captureDate)
        pump()
        return id
    }

    func dismissFailed(_ job: DevelopJob) {
        jobs.removeAll { $0.id == job.id }
        sources.removeValue(forKey: job.id)
    }

    func retry(_ job: DevelopJob) {
        guard let i = jobs.firstIndex(where: { $0.id == job.id }) else { return }
        jobs[i].phase = .queued
        pump()
    }

    func setForeground(_ fg: Bool) {
        isForeground = fg
        if fg { pump() }
    }

    private func pump() {
        guard worker == nil, isForeground else { return }
        guard let next = jobs.first(where: { $0.phase == .queued }) else { return }
        worker = Task { [weak self] in
            await self?.process(next.id)
            self?.worker = nil
            self?.pump()
        }
    }

    private func process(_ id: UUID) async {
        guard let i = jobs.firstIndex(where: { $0.id == id }), let entry = sources[id] else { return }
        let (source, aspect, frameNumber, date) = entry
        jobs[i].phase = .developing
        jobs[i].startedAt = Date()
        jobs[i].expectedSeconds = expected
        let recipe = jobs[i].recipe
        let started = Date()
        do {
            let photo = try await develop(source: source, recipe: recipe, aspect: aspect,
                                          frameNumber: frameNumber, captureDate: date)
            recentDurations.append(Date().timeIntervalSince(started))
            ScreenshotMode.log("developed \(recipe.filmID) \(photo.width)x\(photo.height) in \(String(format: "%.2f", Date().timeIntervalSince(started))) s")
            if case .redevelop(let old) = source {
                library.update(photo)
                _ = old
            } else {
                library.add(photo)
            }
            lastDeveloped = photo
            completedCount += 1
            deliver(.success(photo), for: id)
            jobs.removeAll { $0.id == id }
            sources.removeValue(forKey: id)
            if settings.autoSaveToPhotos {
                Task { try? await library.saveToPhotos(photo) }
            }
        } catch {
            let message = error.localizedDescription
            lastError = message
            deliver(.failure(error), for: id)
            ScreenshotMode.log("develop failed \(recipe.filmID): \(message)")
            if let j = jobs.firstIndex(where: { $0.id == id }) {
                // Sent to the background mid-render: just try again later.
                jobs[j].phase = isForeground ? .failed(message) : .queued
                jobs[j].startedAt = nil
            }
        }
    }

    /// Decode, develop, encode, file. Heavy work runs off the main actor.
    private func develop(source: DevelopSource, recipe: DevelopRecipe, aspect: Double?,
                         frameNumber: Int, captureDate: Date) async throws -> DevelopedPhoto {
        let quality = settings.outputQuality.longEdge
        let format = settings.saveFormat
        let keepOriginal = settings.keepOriginals
        let dir = library.directory
        let engine = FilmEngine.shared

        // Inputs: bytes to develop, bytes to keep as the original.
        var developData: Data
        var developIsRAW = false
        var originalData: Data?
        var originalExt = "heic"
        var existing: DevelopedPhoto?
        var metadataSource: Data

        switch source {
        case .capture(let c):
            if let raw = c.rawData {
                developData = raw
                developIsRAW = true
                originalData = raw
                originalExt = "dng"
            } else {
                developData = c.processedData
                originalData = c.processedData
                originalExt = PhotoDecoder.isRAW(data: c.processedData) ? "dng" : "heic"
            }
            metadataSource = c.processedData
        case .imported(let data, let isRAW):
            developData = data
            developIsRAW = isRAW
            originalData = data
            originalExt = isRAW ? "dng" : "heic"
            metadataSource = data
        case .redevelop(let p):
            guard let u = library.originalURL(for: p) else { throw EngineError.decode("原图未保留") }
            developData = try Data(contentsOf: u, options: .mappedIfSafe)
            developIsRAW = p.originalIsRAW
            metadataSource = developData
            existing = p
        }

        let id = existing?.id ?? UUID()
        let data = developData, isRAW = developIsRAW, metaData = metadataSource
        let ext = format.ext
        let fileName = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970)).\(ext)"
        let thumbName = "\(id.uuidString)-\(Int(Date().timeIntervalSince1970))-thumb.jpg"

        // Decode into the engine's frame on the engine queue: Core Image's GPU
        // work and the engine's planes never overlap in memory.
        let frame: EngineFrame = try await engine.run { () throws -> EngineFrame in
            let ci = try PhotoDecoder.ciImage(from: data, isRAW: isRAW)
            let prepared = PhotoDecoder.prepare(ci, aspect: aspect, maxLongEdge: quality)
            return try engine.makeFrame(from: prepared)
        }
        let params = recipe.engineParams(aspect: frame.aspect, purpose: .develop,
                                         captureDate: captureDate, frameNumber: frameNumber)
        let printed = try await engine.develop(frame: frame, params: params)

        let width = printed.width, height = printed.height
        try await Task.detached(priority: .userInitiated) {
            let metadata = PhotoDecoder.metadata(of: metaData)
            try PhotoDecoder.write(printed.cgImage, to: dir.appendingPathComponent(fileName), format: format,
                                   quality: 0.92, metadata: metadata)
            try PhotoDecoder.writeThumbnail(printed.cgImage, to: dir.appendingPathComponent(thumbName))
        }.value

        var originalName = existing?.originalName
        if existing == nil, keepOriginal, let originalData {
            let name = "\(id.uuidString)-src.\(originalExt)"
            try? originalData.write(to: dir.appendingPathComponent(name), options: .atomic)
            originalName = name
        }
        if let old = existing {
            // Replace the old print's files.
            let fm = FileManager.default
            if old.fileName != fileName { try? fm.removeItem(at: dir.appendingPathComponent(old.fileName)) }
            if old.thumbName != thumbName { try? fm.removeItem(at: dir.appendingPathComponent(old.thumbName)) }
        }

        return DevelopedPhoto(id: id, createdAt: existing?.createdAt ?? Date(), captureDate: captureDate,
                              recipe: recipe, width: width, height: height, fileName: fileName,
                              thumbName: thumbName, originalName: originalName,
                              originalIsRAW: existing?.originalIsRAW ?? isRAW,
                              assetLocalID: nil, frameNumber: existing?.frameNumber ?? frameNumber,
                              cropAspect: aspect)
    }
}
