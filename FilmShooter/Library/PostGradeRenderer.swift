import CoreImage
import CoreImage.CIFilterBuiltins
import CoreGraphics
import Foundation
import UIKit

/// GPU accelerated, post-print grading. It consumes the developed image file;
/// it has no access to RAW decoding or FilmShooter's film development engine.
enum PostGradeRenderer {
    static func render(inputURL: URL, recipe: PostGradeRecipe, maxLongEdge: Int? = nil) throws -> UIImage {
        guard let input = CIImage(contentsOf: inputURL, options: [.applyOrientationProperty: true]) else {
            throw EngineError.decode("无法读取冲印后的照片")
        }

        var image = input
        if let maxLongEdge, maxLongEdge > 0 {
            let longEdge = max(input.extent.width, input.extent.height)
            if longEdge > CGFloat(maxLongEdge) {
                let scale = CGFloat(maxLongEdge) / longEdge
                image = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            }
        }
        if recipe.exposure != 0 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = image
            filter.ev = Float(clamp(recipe.exposure, -5, 5))
            image = filter.outputImage ?? image
        }
        if recipe.contrast != 0 || recipe.saturation != 0 {
            let filter = CIFilter.colorControls()
            filter.inputImage = image
            filter.contrast = Float(1 + clamp(recipe.contrast, -100, 100) / 100)
            filter.saturation = Float(1 + clamp(recipe.saturation, -100, 100) / 100)
            image = filter.outputImage ?? image
        }
        if recipe.temperature != 0 || recipe.tint != 0 {
            let filter = CIFilter.temperatureAndTint()
            filter.inputImage = image
            filter.neutral = CIVector(x: 6500 + clamp(recipe.temperature, -100, 100) * 35,
                                      y: clamp(recipe.tint, -100, 100) * 0.35)
            filter.targetNeutral = CIVector(x: 6500, y: 0)
            image = filter.outputImage ?? image
        }
        if recipe.highlights != 0 || recipe.shadows != 0 {
            let filter = CIFilter.highlightShadowAdjust()
            filter.inputImage = image
            filter.highlightAmount = Float(1 - clamp(recipe.highlights, -100, 100) / 100)
            filter.shadowAmount = Float(clamp(recipe.shadows, -100, 100) / 100)
            image = filter.outputImage ?? image
        }

        if let cubeData = makeCube(recipe: recipe) {
            let filter = CIFilter.colorCube()
            filter.inputImage = image
            filter.cubeDimension = 33
            filter.cubeData = cubeData
            image = filter.outputImage ?? image
        }

        let context = CIContext(options: [.workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any])
        guard let cgImage = context.createCGImage(image, from: image.extent, format: .RGBA8,
                                                  colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
            throw EngineError.decode("调色渲染失败")
        }
        return UIImage(cgImage: cgImage, scale: 1, orientation: .up)
    }

    private static func makeCube(recipe: PostGradeRecipe) -> Data? {
        let size = 33
        let channels = [recipe.masterCurve, recipe.redCurve, recipe.greenCurve, recipe.blueCurve]
        guard channels.contains(where: { $0 != PostGradeRecipe.identity }) else { return nil }
        var values = [Float]()
        values.reserveCapacity(size * size * size * 4)
        // Core Image expects red to vary fastest, followed by green and blue.
        for blue in 0..<size {
            for green in 0..<size {
                for red in 0..<size {
                    let source = [Double(red) / Double(size - 1),
                                  Double(green) / Double(size - 1),
                                  Double(blue) / Double(size - 1)]
                    var output = source
                    for channel in 0..<3 {
                        output[channel] = evaluate(channels[channel + 1], at: source[channel])
                        output[channel] = evaluate(recipe.masterCurve, at: output[channel])
                    }
                    values.append(Float(output[0]))
                    values.append(Float(output[1]))
                    values.append(Float(output[2]))
                    values.append(1)
                }
            }
        }
        return values.withUnsafeBufferPointer { buffer in
            guard let baseAddress = buffer.baseAddress else { return Data() }
            return Data(bytes: baseAddress, count: buffer.count * MemoryLayout<Float>.stride)
        }
    }

    private static func evaluate(_ points: [GradePoint], at value: Double) -> Double {
        guard points.count >= 2 else { return value }
        let sorted = points.sorted { $0.x < $1.x }
        let x = clamp(value, 0, 1)
        if x <= sorted[0].x { return clamp(sorted[0].y, 0, 1) }
        if x >= sorted[sorted.count - 1].x { return clamp(sorted[sorted.count - 1].y, 0, 1) }
        for index in 1..<sorted.count where x <= sorted[index].x {
            let left = sorted[index - 1]
            let right = sorted[index]
            let width = max(0.000001, right.x - left.x)
            let t = (x - left.x) / width
            return clamp(left.y + (right.y - left.y) * t, 0, 1)
        }
        return x
    }

    private static func clamp(_ value: Double, _ low: Double, _ high: Double) -> Double {
        min(max(value, low), high)
    }
}
