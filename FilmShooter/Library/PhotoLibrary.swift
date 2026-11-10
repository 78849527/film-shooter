import Combine
import Foundation
import Photos
import UIKit

/// One developed frame in the app's own contact sheet.
struct DevelopedPhoto: Identifiable, Codable, Hashable {
    let id: UUID
    var createdAt: Date
    var captureDate: Date
    var recipe: DevelopRecipe
    /// Non-destructive post-development grade settings.
    var postGrade: PostGradeRecipe? = nil
    /// Original developed print kept so later grade edits never compound.
    var gradeBaseName: String? = nil
    var width: Int
    var height: Int
    var fileName: String
    var thumbName: String
    var originalName: String?
    var originalIsRAW: Bool
    var assetLocalID: String?
    var frameNumber: Int
    /// The crop (long : short) the frame was developed at; nil = the whole picture.
    var cropAspect: Double?

    var film: FilmStock { recipe.film }
    var aspect: Double { Double(width) / Double(max(height, 1)) }
}

/// The developed photos, stored in Documents/Roll as files plus a JSON sidecar
/// each (so the library survives anything short of deleting the app).
@MainActor
final class PhotoLibrary: ObservableObject {
    @Published private(set) var photos: [DevelopedPhoto] = []

    private let thumbs = NSCache<NSUUID, UIImage>()
    let directory: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        directory = docs.appendingPathComponent("Roll", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        thumbs.countLimit = 300
        load()
    }

    func url(_ name: String) -> URL { directory.appendingPathComponent(name) }
    func fileURL(for photo: DevelopedPhoto) -> URL { url(photo.fileName) }
    func originalURL(for photo: DevelopedPhoto) -> URL? { photo.originalName.map(url) }

    private func load() {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var list: [DevelopedPhoto] = []
        for f in files where f.pathExtension == "json" {
            if let data = try? Data(contentsOf: f), let p = try? decoder.decode(DevelopedPhoto.self, from: data),
               fm.fileExists(atPath: url(p.fileName).path) {
                list.append(p)
            }
        }
        photos = list.sorted { $0.createdAt > $1.createdAt }
    }

    private func writeSidecar(_ p: DevelopedPhoto) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(p) {
            try? data.write(to: url("\(p.id.uuidString).json"), options: .atomic)
        }
    }

    func add(_ photo: DevelopedPhoto) {
        writeSidecar(photo)
        photos.insert(photo, at: 0)
    }

    func update(_ photo: DevelopedPhoto) {
        if let previous = photos.first(where: { $0.id == photo.id }),
           let oldBase = previous.gradeBaseName, oldBase != photo.gradeBaseName {
            try? FileManager.default.removeItem(at: url(oldBase))
        }
        writeSidecar(photo)
        if let i = photos.firstIndex(where: { $0.id == photo.id }) { photos[i] = photo }
        thumbs.removeObject(forKey: photo.id as NSUUID)
    }

    func delete(_ photo: DevelopedPhoto) {
        let fm = FileManager.default
        for name in [photo.fileName, photo.thumbName, photo.originalName, photo.gradeBaseName,
                     "\(photo.id.uuidString).json"].compactMap({ $0 }) {
            try? fm.removeItem(at: url(name))
        }
        thumbs.removeObject(forKey: photo.id as NSUUID)
        photos.removeAll { $0.id == photo.id }
    }

    /// Cached contact-sheet thumbnail (synchronous: it is a small JPEG).
    /// Prefer `cachedThumbnail` + `loadThumbnail` in scrolling views.
    func thumbnail(for photo: DevelopedPhoto) -> UIImage? {
        if let t = thumbs.object(forKey: photo.id as NSUUID) { return t }
        guard let img = UIImage(contentsOfFile: url(photo.thumbName).path) else { return nil }
        thumbs.setObject(img, forKey: photo.id as NSUUID)
        return img
    }

    /// The thumbnail only if it is already decoded (never touches the disk).
    func cachedThumbnail(for photo: DevelopedPhoto) -> UIImage? {
        thumbs.object(forKey: photo.id as NSUUID)
    }

    /// Decode the thumbnail off the main thread (ready for display) and cache it.
    func loadThumbnail(for photo: DevelopedPhoto) async -> UIImage? {
        if let t = thumbs.object(forKey: photo.id as NSUUID) { return t }
        let path = url(photo.thumbName).path
        let img = await Task.detached(priority: .userInitiated) {
            UIImage(contentsOfFile: path)?.preparingForDisplay()
        }.value
        if let img { thumbs.setObject(img, forKey: photo.id as NSUUID) }
        return img
    }

    /// The developed print, downsampled for the screen, decoded off the main thread.
    func displayImage(for photo: DevelopedPhoto, maxPixel: Int = 2800) async -> UIImage? {
        let u = fileURL(for: photo)
        return await Task.detached(priority: .userInitiated) {
            PhotoDecoder.displayImage(at: u, maxPixel: maxPixel)
        }.value
    }

    /// Apply ordinary post-development color grading to the developed print.
    /// Later edits use the same saved base print instead of compounding JPEGs.
    func applyPostGrade(_ recipe: PostGradeRecipe, to photo: DevelopedPhoto) async throws {
        let sourceURL: URL
        var updated = photo
        if let baseName = photo.gradeBaseName {
            sourceURL = url(baseName)
        } else {
            let suffix = photo.fileName.split(separator: ".").last.map(String.init) ?? "jpg"
            let baseName = "\(photo.id.uuidString)-grade-base.\(suffix)"
            let baseURL = url(baseName)
            if !FileManager.default.fileExists(atPath: baseURL.path) {
                try FileManager.default.copyItem(at: fileURL(for: photo), to: baseURL)
            }
            updated.gradeBaseName = baseName
            sourceURL = baseURL
        }

        let outputName = "\(photo.id.uuidString)-postgrade.jpg"
        let outputURL = url(outputName)
        let thumbURL = url(photo.thumbName)
        let rendered = try await Task.detached(priority: .userInitiated) {
            try PostGradeRenderer.render(inputURL: sourceURL, recipe: recipe)
        }.value
        guard let cgImage = rendered.cgImage,
              let data = rendered.jpegData(compressionQuality: 0.96) else {
            throw EngineError.decode("调色图像编码失败")
        }
        try data.write(to: outputURL, options: .atomic)
        try await Task.detached(priority: .userInitiated) {
            try PhotoDecoder.writeThumbnail(cgImage, to: thumbURL)
        }.value
        updated.fileName = outputName
        updated.postGrade = recipe
        updated.assetLocalID = nil
        update(updated)
        if photo.fileName != outputName { try? FileManager.default.removeItem(at: fileURL(for: photo)) }
    }

    /// The original as shot, for before/after.
    func originalDisplayImage(for photo: DevelopedPhoto, maxPixel: Int = 2800) async -> UIImage? {
        guard let u = originalURL(for: photo) else { return nil }
        return await Task.detached(priority: .userInitiated) {
            PhotoDecoder.displayImage(at: u, maxPixel: maxPixel)
        }.value
    }

    // MARK: Photos

    /// Save a developed print to the system photo library (add-only access).
    func saveToPhotos(_ photo: DevelopedPhoto) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw NSError(domain: "FilmShooter", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有相册写入权限"])
        }
        let file = fileURL(for: photo)
        final class IDBox: @unchecked Sendable { var value: String? }
        let localID = IDBox()
        let frameNumber = photo.frameNumber, filmName = photo.film.name, date = photo.captureDate
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCreationRequest.forAsset()
            let opts = PHAssetResourceCreationOptions()
            opts.originalFilename = "FilmShooter_\(frameNumber)_\(filmName).\(file.pathExtension)"
            req.addResource(with: .photo, fileURL: file, options: opts)
            req.creationDate = date
            localID.value = req.placeholderForCreatedAsset?.localIdentifier
        }
        var p = photo
        p.assetLocalID = localID.value
        update(p)
    }
}
