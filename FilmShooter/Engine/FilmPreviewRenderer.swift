import Foundation
import CoreVideo
import CoreGraphics
import UIKit

/// Tiny live previews for the film library: the current viewfinder frame,
/// downsampled, pushed through each film's viewfinder table on the CPU.
/// ~150 x 200 px x 25 films is well under 10 ms of work.
enum FilmPreviewRenderer {

    /// Downsample a BGRA pixel buffer to `width` px wide, as packed RGB bytes.
    static func downsample(_ pb: CVPixelBuffer, width: Int) -> (rgb: [UInt8], w: Int, h: Int)? {
        guard CVPixelBufferGetPixelFormatType(pb) == kCVPixelFormatType_32BGRA else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let sw = CVPixelBufferGetWidth(pb), sh = CVPixelBufferGetHeight(pb)
        let bpr = CVPixelBufferGetBytesPerRow(pb)
        guard sw > 0, sh > 0 else { return nil }
        let w = min(width, sw)
        let h = max(1, Int((Double(sh) * Double(w) / Double(sw)).rounded()))
        let src = base.assumingMemoryBound(to: UInt8.self)
        var out = [UInt8](repeating: 0, count: w * h * 3)
        // Box filter over the source footprint of each output pixel (2x2 taps
        // per footprint is enough at this size and avoids shimmering).
        let fx = Double(sw) / Double(w), fy = Double(sh) / Double(h)
        for y in 0..<h {
            let y0 = min(sh - 1, Int(Double(y) * fy + fy * 0.25))
            let y1 = min(sh - 1, Int(Double(y) * fy + fy * 0.75))
            for x in 0..<w {
                let x0 = min(sw - 1, Int(Double(x) * fx + fx * 0.25))
                let x1 = min(sw - 1, Int(Double(x) * fx + fx * 0.75))
                var b = 0, g = 0, r = 0
                for (yy, xx) in [(y0, x0), (y0, x1), (y1, x0), (y1, x1)] {
                    let p = src + yy * bpr + xx * 4
                    b += Int(p[0]); g += Int(p[1]); r += Int(p[2])
                }
                let o = (y * w + x) * 3
                out[o] = UInt8(r >> 2); out[o + 1] = UInt8(g >> 2); out[o + 2] = UInt8(b >> 2)
            }
        }
        return (out, w, h)
    }

    /// Apply `lut` (sRGB in, sRGB out) to packed RGB bytes with trilinear interpolation.
    static func apply(_ lut: FilmLUT, to rgb: [UInt8], w: Int, h: Int) -> CGImage? {
        let n = lut.size
        let table = lut.rgba.map { Float($0) }
        let scale = Float(n - 1) / 255
        var out = [UInt8](repeating: 255, count: w * h * 4)
        table.withUnsafeBufferPointer { t in
            rgb.withUnsafeBufferPointer { s in
                out.withUnsafeMutableBufferPointer { o in
                    for i in 0..<(w * h) {
                        let fr = Float(s[i * 3]) * scale, fg = Float(s[i * 3 + 1]) * scale, fb = Float(s[i * 3 + 2]) * scale
                        let r0 = min(n - 2, Int(fr)), g0 = min(n - 2, Int(fg)), b0 = min(n - 2, Int(fb))
                        let dr = fr - Float(r0), dg = fg - Float(g0), db = fb - Float(b0)
                        let sg = n * 4, sb = n * n * 4
                        let i000 = ((b0 * n + g0) * n + r0) * 4
                        for c in 0..<3 {
                            let a = i000 + c
                            let c00 = t[a] * (1 - dr) + t[a + 4] * dr
                            let c10 = t[a + sg] * (1 - dr) + t[a + sg + 4] * dr
                            let c01 = t[a + sb] * (1 - dr) + t[a + sb + 4] * dr
                            let c11 = t[a + sb + sg] * (1 - dr) + t[a + sb + sg + 4] * dr
                            let c0 = c00 * (1 - dg) + c10 * dg
                            let c1 = c01 * (1 - dg) + c11 * dg
                            let v = c0 * (1 - db) + c1 * db
                            o[i * 4 + c] = UInt8(max(0, min(255, v * 255 + 0.5)))
                        }
                    }
                }
            }
        }
        let data = Data(out) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                       space: FilmEngine.sRGB,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }

    static func render(pixelBuffer: CVPixelBuffer, tables: [(String, FilmLUT)], width: Int) -> [String: UIImage] {
        guard let small = downsample(pixelBuffer, width: width) else { return [:] }
        var result: [String: UIImage] = [:]
        for (id, lut) in tables {
            if let cg = apply(lut, to: small.rgb, w: small.w, h: small.h) {
                result[id] = UIImage(cgImage: cg)
            }
        }
        return result
    }
}
