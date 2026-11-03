import Foundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import UIKit

/// Turns photo files (camera HEIC/JPEG, DNG, anything from the library) into
/// pictures the engine can develop, and developed prints back into files.
enum PhotoDecoder {

    // MARK: decode

    /// Decode file bytes. RAW (DNG) goes through `CIRAWFilter` with Apple's
    /// tone rendering switched off, so the film sees the sensor's response.
    static func ciImage(from data: Data, isRAW: Bool) throws -> CIImage {
        if isRAW, let raw = CIRAWFilter(imageData: data, identifierHint: UTType.dng.identifier) {
            raw.boostAmount = 0
            raw.boostShadowAmount = 0
            raw.isGamutMappingEnabled = false
            raw.localToneMapAmount = 0
            raw.extendedDynamicRangeAmount = 0
            raw.isDraftModeEnabled = false
            if raw.isLensCorrectionSupported { raw.isLensCorrectionEnabled = true }
            if let image = raw.outputImage { return image }
        }
        guard let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            throw EngineError.decode("不支持的格式")
        }
        return image
    }

    static func ciImage(contentsOf url: URL) throws -> CIImage {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try ciImage(from: data, isRAW: isRAW(url: url, data: data))
    }

    static func isRAW(url: URL? = nil, data: Data) -> Bool {
        if let ext = url?.pathExtension.lowercased(),
           ["dng", "nef", "arw", "cr2", "cr3", "raf", "orf", "rw2", "pef", "srw"].contains(ext) {
            return true
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(src) as String?,
              let ut = UTType(type) else { return false }
        return ut.conforms(to: .rawImage)
    }

    /// Centre-crop to `aspect` (long : short, >= 1, in the picture's own
    /// orientation; nil keeps the frame) and scale down so the long edge is at
    /// most `maxLongEdge`.
    static func prepare(_ image: CIImage, aspect: Double?, maxLongEdge: Int) -> CIImage {
        var img = image
        let ext = img.extent
        if let aspect, aspect >= 1, ext.width > 0, ext.height > 0 {
            let landscape = ext.width >= ext.height
            let target = landscape ? aspect : 1 / aspect           // width / height
            let current = ext.width / ext.height
            var crop = ext
            if current > target {
                let w = ext.height * target
                crop = CGRect(x: ext.midX - w / 2, y: ext.minY, width: w, height: ext.height)
            } else if current < target {
                let h = ext.width / target
                crop = CGRect(x: ext.minX, y: ext.midY - h / 2, width: ext.width, height: h)
            }
            img = img.cropped(to: crop.integral)
        }
        let e = img.extent
        let long = max(e.width, e.height)
        if long > CGFloat(maxLongEdge), long > 0 {
            let scale = CGFloat(maxLongEdge) / long
            if let f = CIFilter(name: "CILanczosScaleTransform") {
                f.setValue(img, forKey: kCIInputImageKey)
                f.setValue(scale, forKey: kCIInputScaleKey)
                f.setValue(1.0, forKey: kCIInputAspectRatioKey)
                if let out = f.outputImage { img = out }
            } else {
                img = img.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        let fe = img.extent.integral
        return img.cropped(to: fe).transformed(by: .init(translationX: -fe.minX, y: -fe.minY))
    }

    /// The EXIF/TIFF/GPS dictionaries of a file, for carrying into the print.
    static func metadata(of data: Data) -> [String: Any] {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] else { return [:] }
        var out: [String: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyExifAuxDictionary] as [CFString] {
            if let v = props[key as String] { out[key as String] = v }
        }
        if var tiff = out[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
            tiff[kCGImagePropertyTIFFOrientation as String] = 1
            tiff[kCGImagePropertyTIFFSoftware as String] = "FilmShooter"
            out[kCGImagePropertyTIFFDictionary as String] = tiff
        }
        return out
    }

    static func captureDate(of data: Data) -> Date? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any],
              let exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any],
              let s = exif[kCGImagePropertyExifDateTimeOriginal as String] as? String else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f.date(from: s)
    }

    // MARK: encode

    enum Format: String, Codable, CaseIterable, Identifiable {
        case heic, jpeg
        var id: String { rawValue }
        var title: String { self == .heic ? "HEIF" : "JPEG" }
        var ext: String { self == .heic ? "heic" : "jpg" }
        var utType: UTType { self == .heic ? .heic : .jpeg }
    }

    /// Write `image` (16-bit Display P3) to a file, with the original's metadata.
    static func write(_ image: CGImage, to url: URL, format: Format, quality: Double,
                      metadata: [String: Any]) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, format.utType.identifier as CFString, 1, nil) else {
            throw EngineError.encode
        }
        var props = metadata
        props[kCGImageDestinationLossyCompressionQuality as String] = quality
        props[kCGImagePropertyOrientation as String] = 1
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw EngineError.encode }
    }

    /// A small JPEG for the contact sheet.
    static func writeThumbnail(_ image: CGImage, to url: URL, maxPixel: Int = 480) throws {
        let w = image.width, h = image.height
        let scale = min(1, Double(maxPixel) / Double(max(w, h)))
        let tw = max(1, Int(Double(w) * scale)), th = max(1, Int(Double(h) * scale))
        guard let ctx = CGContext(data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: FilmEngine.displayP3,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw EngineError.encode }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tw, height: th))
        guard let thumb = ctx.makeImage() else { throw EngineError.encode }
        try write(thumb, to: url, format: .jpeg, quality: 0.85, metadata: [:])
    }

    /// Downsampled decode of a file for display (ImageIO thumbnailing: fast and
    /// memory-light, never decodes the full image).
    static func displayImage(at url: URL, maxPixel: Int) -> UIImage? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// A quick, small preview of freshly captured bytes (for the developing tray).
    static func quickPreview(of data: Data, maxPixel: Int = 360) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }
}
