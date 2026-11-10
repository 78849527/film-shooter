import Foundation

/// Small image/vector containers required by Oltra's standalone grade engine.
/// Kept separate from FilmShooter's photochemical engine and image pipeline.
struct Vec3: Equatable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double, _ y: Double, _ z: Double) { self.x = x; self.y = y; self.z = z }
    static func + (lhs: Vec3, rhs: Vec3) -> Vec3 { Vec3(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z) }
    static func * (lhs: Vec3, rhs: Double) -> Vec3 { Vec3(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs) }
    static func / (lhs: Vec3, rhs: Double) -> Vec3 { Vec3(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs) }
}

struct ImageRGB {
    var width: Int
    var height: Int
    var data: [Float]

    init(width: Int, height: Int, data: [Float]? = nil) {
        self.width = width
        self.height = height
        let count = max(0, width * height * 3)
        self.data = data ?? [Float](repeating: 0, count: count)
        precondition(self.data.count == count)
    }

    init(width: Int, height: Int, data: [Double]) {
        self.init(width: width, height: height, data: data.map(Float.init))
    }
}

enum GradeImageResizer {
    static func longEdge(_ image: ImageRGB, maxSize: Int) -> ImageRGB {
        let long = max(image.width, image.height)
        guard maxSize > 0, long > maxSize, image.width > 0, image.height > 0 else { return image }
        let scale = Double(maxSize) / Double(long)
        let width = max(1, Int((Double(image.width) * scale).rounded()))
        let height = max(1, Int((Double(image.height) * scale).rounded()))
        var output = ImageRGB(width: width, height: height)
        for y in 0..<height {
            let sy = (Double(y) + 0.5) * Double(image.height) / Double(height) - 0.5
            let y0 = min(max(Int(floor(sy)), 0), image.height - 1)
            let y1 = min(y0 + 1, image.height - 1)
            let fy = min(max(sy - floor(sy), 0), 1)
            for x in 0..<width {
                let sx = (Double(x) + 0.5) * Double(image.width) / Double(width) - 0.5
                let x0 = min(max(Int(floor(sx)), 0), image.width - 1)
                let x1 = min(x0 + 1, image.width - 1)
                let fx = min(max(sx - floor(sx), 0), 1)
                let dst = (y * width + x) * 3
                let p00 = (y0 * image.width + x0) * 3
                let p10 = (y0 * image.width + x1) * 3
                let p01 = (y1 * image.width + x0) * 3
                let p11 = (y1 * image.width + x1) * 3
                for c in 0..<3 {
                    let top = Double(image.data[p00 + c]) * (1 - fx) + Double(image.data[p10 + c]) * fx
                    let bottom = Double(image.data[p01 + c]) * (1 - fx) + Double(image.data[p11 + c]) * fx
                    output.data[dst + c] = Float(top * (1 - fy) + bottom * fy)
                }
            }
        }
        return output
    }
}
