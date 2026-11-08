import Foundation

/// Negative size. Grain, halation and coupler diffusion are physical sizes on the
/// film, so the same picture on 120 looks finer than on 135.
enum FilmFormat: String, Codable, CaseIterable, Identifiable {
    case mm35 = "135"
    case mm120 = "120"

    var id: String { rawValue }
    var title: String { self == .mm35 ? "135" : "120" }
    var subtitle: String { self == .mm35 ? "35mm 小画幅" : "中画幅" }

    /// Short side of the frame in millimetres.
    var shortSideMM: Double { self == .mm35 ? 24 : 56 }

    /// The engine's `film_format_mm` is the long edge of the frame in mm.
    func longEdgeMM(aspect: Double) -> Double {
        let a = max(aspect, 1 / aspect)
        return min(200, max(4, shortSideMM * a))
    }

    /// Film-edge (overscan) gate for a frame of this aspect ratio.
    func overscanFormat(aspect: Double) -> String {
        let a = max(aspect, 1 / aspect)
        switch self {
        case .mm35: return "135"
        case .mm120:
            if a < 1.12 { return "120_6x6" }
            if a < 1.27 { return "120_6x7" }
            if a < 1.40 { return "120_645" }
            return "120_6x9"
        }
    }
}

/// Everything that defines how a frame is developed and printed.
struct DevelopRecipe: Codable, Hashable {
    var filmID: String = FilmCatalog.defaultFilmID
    var paperID: String = "kodak_portra_endura"
    /// Film exposure compensation, stops.
    var exposureEV: Double = 0
    /// Let the engine meter the frame (on top of `exposureEV`). Off for camera
    /// captures: the camera already metered, and the viewfinder preview assumes it.
    var autoExposure: Bool = false
    /// 0 = off, 1 = the stock's own grain, up to 2.
    var grain: Double = 1.0
    /// 0 = off, 1 = the stock's own halation, up to 3.
    var halation: Double = 1.0
    var format: FilmFormat = .mm35
    /// Print brightness in stops (negative films only).
    var printBrightness: Double = 0
    /// Enlarger colour: + warmer, - cooler (negative films only), -1...1.
    var warmth: Double = 0
    /// Enlarger colour: + magenta, - green (negative films only), -1...1.
    var tint: Double = 0
    /// Print the frame on its own strip of film: rebate, perforations, edge print.
    var filmEdge: Bool = false
    /// Expose the date into the corner of the frame, like a date back.
    var dateStamp: Bool = false

    var film: FilmStock { FilmCatalog.film(filmID) }

    /// A paper the engine accepts for this film. Slides do not print, but the
    /// engine still loads a print stock, so they keep a valid colour paper.
    var resolvedPaperID: String {
        let film = self.film
        let valid = FilmCatalog.papers(for: film).map(\.id)
        if film.kind == .slide { return "kodak_portra_endura" }
        if valid.contains(paperID) { return paperID }
        return film.defaultPaper.isEmpty ? (valid.first ?? "kodak_portra_endura") : film.defaultPaper
    }

    mutating func selectFilm(_ id: String) {
        guard id != filmID else { return }
        // A new film brings its own reference paper. Preserve a manual paper
        // choice only while adjusting the same film; never carry a Kodak
        // paper across to a Fujifilm stock just because both are colour.
        let selected = FilmCatalog.film(id)
        filmID = selected.id
        paperID = selected.kind.usesPrintPaper
            ? selected.defaultPaper
            : "kodak_portra_endura" // engine-required neutral carrier for slides
    }

    /// Per-stock grain scaling for the measured B&W profiles (their sheets give a
    /// granularity; the colour profiles' own 1 is already right).
    private static func ownGrain(_ stock: String) -> Double {
        switch stock {
        case "kodak_tri_x_400": return 1.70
        case "ilford_hp5_plus_400": return 1.49
        case "kodak_tmax_100": return 0.74
        case "fujifilm_neopan_acros_100_ii": return 0.64
        default: return 1
        }
    }

    enum Purpose {
        /// A real development: every effect on.
        case develop
        /// A colour lookup table for the viewfinder: only point-wise effects.
        case lut
    }

    /// The engine parameter delta for this recipe.
    func engineParams(aspect: Double, purpose: Purpose, captureDate: Date? = nil,
                      frameNumber: Int? = nil) -> [String: Any] {
        let film = self.film
        var p: [String: Any] = [
            "product_defaults": true,
            "film_stock": film.id,
            "print_stock": resolvedPaperID,
            "exposure_compensation_ev": max(-8, min(8, exposureEV)),
            "auto_exposure": purpose == .develop ? autoExposure : false,
            "auto_exposure_method": "balanced",
            "scan_film": film.kind == .slide,
            "output_color_space": purpose == .lut ? "sRGB" : "Display P3",
            "output_cctf_encoding": true,
            "extended_dynamic_range": false,
        ]

        if film.kind.usesPrintPaper {
            p["print_exposure"] = max(0.05, min(20, pow(2, -printBrightness)))
            p["y_filter_shift"] = max(-1, min(1, -warmth))
            p["m_filter_shift"] = max(-1, min(1, -tint))
            p["filter_shift_scale"] = 40.0
        }
        if film.kind == .blackWhite {
            p["grain_sublayers_active"] = false
            // A B&W negative on B&W paper prints through a neutral pack.
            p["c_filter_neutral"] = 0.0
            p["m_filter_neutral"] = 0.0
            p["y_filter_neutral"] = 68.0
        }

        switch purpose {
        case .develop:
            p["film_format_mm"] = format.longEdgeMM(aspect: aspect)
            let g = grain * Self.ownGrain(film.id)
            p["grain_active"] = grain > 0.001
            p["grain_amount"] = max(0, min(2, g))
            p["halation_active"] = halation > 0.001
            p["halation_amount"] = max(0, min(4, halation))
            p["glare_active"] = true
            p["dir_couplers_active"] = true
            if filmEdge {
                p["overscan_active"] = true
                p["overscan_format"] = format.overscanFormat(aspect: aspect)
                p["overscan_mode"] = "filed"
                p["overscan_holes"] = "black"
                p["overscan_edge_text"] = edgeText(film)
                if let n = frameNumber { p["overscan_frame_number"] = max(0, min(99, n)) }
            } else {
                p["overscan_active"] = false
            }
            if dateStamp {
                p["date_imprint_active"] = true
                p["date_imprint_text"] = Self.dateText(captureDate ?? Date())
                p["date_imprint_style"] = "lcd"
                p["date_imprint_corner"] = "br"
            } else {
                p["date_imprint_active"] = false
            }
        case .lut:
            // The table is sampled on a synthetic grid: anything spatial or
            // stochastic would leak between neighbouring cells. A huge
            // negative makes each cell far wider than any diffusion kernel.
            p["film_format_mm"] = 200.0
            p["grain_active"] = false
            p["halation_active"] = false
            p["glare_active"] = false
            p["dir_couplers_active"] = true
            p["overscan_active"] = false
            p["date_imprint_active"] = false
            p["contrast_mask_active"] = false
            p["input_color_space"] = "sRGB"
            p["input_cctf_decoding"] = true
        }
        return p
    }

    private func edgeText(_ film: FilmStock) -> String {
        "\(film.brand.uppercased()) \(film.name.uppercased())"
    }

    /// "'26 11 3" -- the way a date back prints it.
    static func dateText(_ date: Date) -> String {
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let yy = (c.year ?? 2026) % 100
        return String(format: "'%02ld %ld %ld", yy, c.month ?? 1, c.day ?? 1)
    }
}

extension Dictionary where Key == String, Value == Any {
    var jsonString: String {
        guard let data = try? JSONSerialization.data(withJSONObject: self, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }
}
