import Foundation

/// Editable color adjustments applied after FilmShooter has finished printing.
/// The recipe is stored with the developed photo and remains independent from
/// the camera and photochemical development settings.
struct GradePoint: Codable, Hashable, Sendable {
    var x: Double
    var y: Double
}

struct PostGradeRecipe: Codable, Hashable, Sendable {
    static let identity: [GradePoint] = [
        GradePoint(x: 0, y: 0), GradePoint(x: 0.25, y: 0.25),
        GradePoint(x: 0.5, y: 0.5), GradePoint(x: 0.75, y: 0.75),
        GradePoint(x: 1, y: 1)
    ]

    var exposure: Double = 0
    var contrast: Double = 0
    var saturation: Double = 0
    var temperature: Double = 0
    var tint: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var masterCurve = Self.identity
    var redCurve = Self.identity
    var greenCurve = Self.identity
    var blueCurve = Self.identity

    enum CodingKeys: String, CodingKey {
        case exposure, contrast, saturation, temperature, tint, highlights, shadows
        case masterCurve, redCurve, greenCurve, blueCurve
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        exposure = try c.decodeIfPresent(Double.self, forKey: .exposure) ?? 0
        contrast = try c.decodeIfPresent(Double.self, forKey: .contrast) ?? 0
        saturation = try c.decodeIfPresent(Double.self, forKey: .saturation) ?? 0
        temperature = try c.decodeIfPresent(Double.self, forKey: .temperature) ?? 0
        tint = try c.decodeIfPresent(Double.self, forKey: .tint) ?? 0
        highlights = try c.decodeIfPresent(Double.self, forKey: .highlights) ?? 0
        shadows = try c.decodeIfPresent(Double.self, forKey: .shadows) ?? 0
        masterCurve = try c.decodeIfPresent([GradePoint].self, forKey: .masterCurve) ?? Self.identity
        redCurve = try c.decodeIfPresent([GradePoint].self, forKey: .redCurve) ?? Self.identity
        greenCurve = try c.decodeIfPresent([GradePoint].self, forKey: .greenCurve) ?? Self.identity
        blueCurve = try c.decodeIfPresent([GradePoint].self, forKey: .blueCurve) ?? Self.identity
    }
}
