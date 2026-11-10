import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UIKit

/// Bridges FilmShooter images to Oltra's independent post-image grade engine.
/// The input is decoded by FilmShooter (including its existing RAW decoder),
/// then normalized to linear sRGB before grading.
enum GradeImageCodec {
    private static let outputSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private static let context = CIContext(options: [.workingColorSpace: outputSpace])

    static func render(inputURL: URL, recipe: GradeRecipe, maxLongEdge: Int? = nil) throws -> UIImage {
        let data = try Data(contentsOf: inputURL, options: .mappedIfSafe)
        let raw = PhotoDecoder.isRAW(url: inputURL, data: data)
        let image = try render(data: data, isRAW: raw, recipe: recipe, maxLongEdge: maxLongEdge)
        guard let cgImage = image else { throw EngineError.decode("调色渲染失败") }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    static func render(data: Data, isRAW: Bool, recipe: GradeRecipe,
                       maxLongEdge: Int? = nil) throws -> CGImage? {
        let ciImage = try PhotoDecoder.ciImage(from: data, isRAW: isRAW)
        let edge = maxLongEdge ?? max(Int(ciImage.extent.width), Int(ciImage.extent.height))
        let prepared = PhotoDecoder.prepare(ciImage, aspect: nil, maxLongEdge: max(1, edge))
        guard let decoded = context.createCGImage(prepared, from: prepared.extent,
                                                  format: .RGBA8, colorSpace: outputSpace) else {
            throw EngineError.decode("无法准备调色图像")
        }
        let linear = try linearSRGB(from: decoded)
        let graded = try GradeEngine.render(linear, recipe: recipe, analyze: false).image
        return encodedSRGB(graded)
    }

    private static func linearSRGB(from image: CGImage) throws -> ImageRGB {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: outputSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw EngineError.decode("无法读取调色图像像素")
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let bytes = context.data else { throw EngineError.decode("调色图像像素为空") }
        let pixels = bytes.bindMemory(to: UInt8.self, capacity: width * height * 4)
        var rgb = ImageRGB(width: width, height: height)
        for pixel in 0..<(width * height) {
            let src = pixel * 4, dst = pixel * 3
            let alpha = Double(pixels[src + 3]) / 255
            for channel in 0..<3 {
                let encoded = alpha > 0 ? min(1, Double(pixels[src + channel]) / 255 / alpha) : 0
                let linear = encoded <= 0.04045 ? encoded / 12.92 : pow((encoded + 0.055) / 1.055, 2.4)
                rgb.data[dst + channel] = Float(linear)
            }
        }
        return rgb
    }

    private static func encodedSRGB(_ image: ImageRGB) -> CGImage? {
        let width = image.width, height = image.height
        guard width > 0, height > 0,
              let context = CGContext(data: nil, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: outputSpace,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let bytes = context.data?.bindMemory(to: UInt8.self, capacity: width * height * 4) else {
            return nil
        }
        for pixel in 0..<(width * height) {
            let src = pixel * 3, dst = pixel * 4
            for channel in 0..<3 {
                let value = Double(image.data[src + channel])
                bytes[dst + channel] = UInt8((min(max(value.isFinite ? value : 0, 0), 1) * 255).rounded())
            }
            bytes[dst + 3] = 255
        }
        return context.makeImage()
    }
}
