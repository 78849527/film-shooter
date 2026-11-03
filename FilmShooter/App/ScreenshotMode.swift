import Foundation
import UIKit
import CoreVideo
import CoreImage

/// Launch with `-FSScreenshot <scene>` (the CI screenshot job does) to run the
/// app without a camera: the viewfinder is fed from
/// Documents/ScreenshotSample.jpg and the named scene opens directly.
/// Scenes: seed, camera, camera-film, print, gallery, detail, editor, settings, about.
/// Ordinary launches never see any of this.
enum ScreenshotMode {
    static let scene: String? = {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-FSScreenshot"), i + 1 < args.count else { return nil }
        return args[i + 1]
    }()

    static var isActive: Bool { scene != nil }

    static func `is`(_ name: String) -> Bool { scene == name }

    static var sampleURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ScreenshotSample.jpg")
    }

    static func sampleData() -> Data? { try? Data(contentsOf: sampleURL) }

    /// Append a line to Documents/screenshot-log.txt (collected by CI).
    static func log(_ message: String) {
        guard isActive else { return }
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("screenshot-log.txt")
        let line = "\(Date()) [\(scene ?? "-")] \(message)\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line.data(using: .utf8)!)
            try? h.close()
        } else {
            try? line.data(using: .utf8)!.write(to: url)
        }
    }

    /// The sample as an upright BGRA pixel buffer, like a portrait camera frame.
    static func samplePixelBuffer(width: Int = 1080) -> CVPixelBuffer? {
        guard let data = sampleData(), let image = CIImage(data: data, options: [.applyOrientationProperty: true]) else {
            return nil
        }
        let scale = CGFloat(width) / image.extent.width
        let height = Int((image.extent.height * scale).rounded())
        let scaled = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var pb: CVPixelBuffer?
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            attrs as CFDictionary, &pb)
        guard let pb else { return nil }
        let ctx = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        ctx.render(scaled, to: pb, bounds: CGRect(x: 0, y: 0, width: width, height: height),
                   colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        return pb
    }

    /// Develop the sample with a few films so the contact sheet has prints.
    @MainActor
    static func seed(model: AppModel) {
        guard let data = sampleData() else { log("no sample image"); return }
        let looks: [(String, (inout DevelopRecipe) -> Void)] = [
            ("kodak_portra_400", { _ in }),
            ("fujifilm_velvia_100", { _ in }),
            ("kodak_tri_x_400", { $0.filmEdge = true }),
            ("cinestill_800t", { $0.dateStamp = true }),
            ("kodak_gold_200", { $0.format = .mm120 }),
        ]
        for (i, look) in looks.enumerated() {
            var r = DevelopRecipe()
            r.selectFilm(look.0)
            look.1(&r)
            model.darkroom.enqueue(.imported(data: data, isRAW: false), recipe: r, aspect: 1.5,
                                   frameNumber: i + 1, captureDate: Date())
        }
        log("seeded \(looks.count) jobs")
    }
}
