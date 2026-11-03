import Foundation

/// A 3D colour lookup table baked from the spectral engine for one recipe.
///
/// Domain and range are both **sRGB-encoded** values in 0...1: index the table
/// with a camera preview pixel as it comes off the sensor pipeline (BGRA8,
/// sRGB) and the result is that pixel developed and printed, ready to show on
/// an sRGB drawable. Only point-wise effects are in it (no grain, halation,
/// glare): the viewfinder adds an approximate grain of its own.
///
/// Layout: `rgba.count == size * size * size * 4`, red fastest, then green,
/// then blue -- the index of cell (r, g, b) is `((b * size + g) * size + r) * 4`.
/// That is exactly the memory layout of an `MTLTexture` of type `.type3D` with
/// width = height = depth = `size` (x = r, y = g, z = b), so it uploads with one
/// `replace(region:...)` call. Alpha is always 1.
final class FilmLUT: @unchecked Sendable, Identifiable {
    let id = UUID()
    let size: Int
    /// Half-float RGBA, ready for an `.rgba16Float` 3D texture.
    let rgba: [Float16]
    /// The recipe key it was baked for (for caching).
    let key: String

    init(size: Int, rgba: [Float16], key: String) {
        precondition(rgba.count == size * size * size * 4)
        self.size = size
        self.rgba = rgba
        self.key = key
    }

    /// Bytes per row / per image for `MTLTexture.replace(region:mipmapLevel:slice:withBytes:bytesPerRow:bytesPerImage:)`.
    var bytesPerRow: Int { size * 4 * MemoryLayout<Float16>.stride }
    var bytesPerImage: Int { bytesPerRow * size }

    /// An identity table (the camera as it is), used before the first bake.
    static func identity(size: Int = 17) -> FilmLUT {
        var v = [Float16](repeating: 1, count: size * size * size * 4)
        let d = Float(size - 1)
        for b in 0..<size {
            for g in 0..<size {
                for r in 0..<size {
                    let i = ((b * size + g) * size + r) * 4
                    v[i] = Float16(Float(r) / d)
                    v[i + 1] = Float16(Float(g) / d)
                    v[i + 2] = Float16(Float(b) / d)
                }
            }
        }
        return FilmLUT(size: size, rgba: v, key: "identity")
    }
}
