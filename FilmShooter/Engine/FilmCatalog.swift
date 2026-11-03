import SwiftUI

/// What kind of emulsion a stock is. Drives grouping in the picker and whether a
/// print paper applies (a slide is viewed directly; it has no print stage).
enum FilmKind: String, Codable, CaseIterable, Identifiable {
    case colorNegative
    case cinema
    case slide
    case blackWhite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .colorNegative: return "彩色负片"
        case .cinema:        return "电影胶片"
        case .slide:         return "反转片"
        case .blackWhite:    return "黑白"
        }
    }

    var shortTitle: String {
        switch self {
        case .colorNegative: return "C-41"
        case .cinema:        return "ECN-2"
        case .slide:         return "E-6"
        case .blackWhite:    return "B&W"
        }
    }

    var usesPrintPaper: Bool { self != .slide }
}

/// One taking stock the engine can simulate. `id` is the engine's profile name.
struct FilmStock: Identifiable, Hashable {
    let id: String
    let brand: String
    let name: String
    let iso: Int
    let kind: FilmKind
    /// The paper the stock was designed to be printed on (profile `target_print`).
    let defaultPaper: String
    /// One line, in Chinese, about the look.
    let tagline: String
    /// Two colours for the canister card: body and band.
    let body: Color
    let band: Color
    /// A third colour for the label text on the card.
    let ink: Color

    var displayName: String { "\(brand) \(name)" }
    var isoLabel: String { "ISO \(iso)" }
}

/// A print stock (colour paper, cine print film, or B&W paper).
struct PrintPaper: Identifiable, Hashable {
    let id: String
    let name: String
    let tagline: String
    let isBlackWhite: Bool
}

enum FilmCatalog {
    private static func rgb(_ hex: UInt32) -> Color {
        Color(red: Double((hex >> 16) & 0xFF) / 255,
              green: Double((hex >> 8) & 0xFF) / 255,
              blue: Double(hex & 0xFF) / 255)
    }

    static let films: [FilmStock] = [
        // Colour negative, still
        FilmStock(id: "kodak_portra_400", brand: "Kodak", name: "Portra 400", iso: 400, kind: .colorNegative,
                  defaultPaper: "kodak_portra_endura", tagline: "温润肤色 · 宽容度极高",
                  body: rgb(0xF3EEE4), band: rgb(0xE0A43A), ink: rgb(0x2B2620)),
        FilmStock(id: "kodak_portra_160", brand: "Kodak", name: "Portra 160", iso: 160, kind: .colorNegative,
                  defaultPaper: "kodak_portra_endura", tagline: "柔和低反差 · 人像经典",
                  body: rgb(0xF4F0E8), band: rgb(0xC9A15A), ink: rgb(0x2B2620)),
        FilmStock(id: "kodak_portra_800", brand: "Kodak", name: "Portra 800", iso: 800, kind: .colorNegative,
                  defaultPaper: "kodak_portra_endura", tagline: "高感暖调 · 夜色细腻",
                  body: rgb(0xF1EADC), band: rgb(0xD9792E), ink: rgb(0x2B2620)),
        FilmStock(id: "kodak_portra_800_push1", brand: "Kodak", name: "Portra 800 +1", iso: 1600, kind: .colorNegative,
                  defaultPaper: "kodak_portra_endura", tagline: "增感一档 · 反差更硬",
                  body: rgb(0xEDE3D1), band: rgb(0xC9612A), ink: rgb(0x2B2620)),
        FilmStock(id: "kodak_portra_800_push2", brand: "Kodak", name: "Portra 800 +2", iso: 3200, kind: .colorNegative,
                  defaultPaper: "kodak_portra_endura", tagline: "增感两档 · 颗粒浓烈",
                  body: rgb(0xE6D9C3), band: rgb(0xB24A26), ink: rgb(0x2B2620)),
        FilmStock(id: "kodak_gold_200", brand: "Kodak", name: "Gold 200", iso: 200, kind: .colorNegative,
                  defaultPaper: "kodak_portra_endura", tagline: "金黄暖阳 · 怀旧日常",
                  body: rgb(0xF6C431), band: rgb(0xD4422B), ink: rgb(0x3A1E10)),
        FilmStock(id: "kodak_ultramax_400", brand: "Kodak", name: "UltraMax 400", iso: 400, kind: .colorNegative,
                  defaultPaper: "kodak_portra_endura", tagline: "鲜艳饱和 · 街头随拍",
                  body: rgb(0xF0B92A), band: rgb(0x1F3E8C), ink: rgb(0x14213D)),
        FilmStock(id: "kodak_ektar_100", brand: "Kodak", name: "Ektar 100", iso: 100, kind: .colorNegative,
                  defaultPaper: "kodak_portra_endura", tagline: "高饱和 · 极细颗粒 · 风光",
                  body: rgb(0xF1EFEA), band: rgb(0xD8352A), ink: rgb(0x231F1E)),
        FilmStock(id: "fujifilm_pro_400h", brand: "Fujifilm", name: "Pro 400H", iso: 400, kind: .colorNegative,
                  defaultPaper: "fujifilm_crystal_archive_typeii", tagline: "清透青绿 · 日系空气感",
                  body: rgb(0xE9EEF0), band: rgb(0x4E8F7E), ink: rgb(0x1A2A2A)),
        FilmStock(id: "fujifilm_xtra_400", brand: "Fujifilm", name: "X-Tra 400", iso: 400, kind: .colorNegative,
                  defaultPaper: "fujifilm_crystal_archive_typeii", tagline: "冷绿基调 · 通透锐利",
                  body: rgb(0x2F8F55), band: rgb(0xE8E4D8), ink: rgb(0xF4F1E8)),
        FilmStock(id: "fujifilm_c200", brand: "Fujifilm", name: "C200", iso: 200, kind: .colorNegative,
                  defaultPaper: "fujifilm_crystal_archive_typeii", tagline: "淡雅清新 · 平价日常",
                  body: rgb(0x3FA35F), band: rgb(0xF2EFE6), ink: rgb(0xF7F4EC)),

        // Motion picture negative
        FilmStock(id: "kodak_vision3_250d", brand: "Kodak", name: "Vision3 250D", iso: 250, kind: .cinema,
                  defaultPaper: "kodak_2383", tagline: "日光电影感 · 宽广动态",
                  body: rgb(0x2A2A2C), band: rgb(0xE8A23A), ink: rgb(0xF2EDE3)),
        FilmStock(id: "kodak_vision3_50d", brand: "Kodak", name: "Vision3 50D", iso: 50, kind: .cinema,
                  defaultPaper: "kodak_2383", tagline: "最细颗粒 · 明亮日景",
                  body: rgb(0x2E2D2B), band: rgb(0xF2C14E), ink: rgb(0xF2EDE3)),
        FilmStock(id: "kodak_vision3_200t", brand: "Kodak", name: "Vision3 200T", iso: 200, kind: .cinema,
                  defaultPaper: "kodak_2383", tagline: "灯光片 · 室内暖光变冷调",
                  body: rgb(0x262830), band: rgb(0x5B86C9), ink: rgb(0xF2EDE3)),
        FilmStock(id: "kodak_vision3_500t", brand: "Kodak", name: "Vision3 500T", iso: 500, kind: .cinema,
                  defaultPaper: "kodak_2383", tagline: "夜景电影 · 霓虹氛围",
                  body: rgb(0x1F2230), band: rgb(0x3E63B5), ink: rgb(0xF2EDE3)),
        FilmStock(id: "cinestill_800t", brand: "CineStill", name: "800T", iso: 800, kind: .cinema,
                  defaultPaper: "kodak_2383", tagline: "无防光晕层 · 红色光晕",
                  body: rgb(0x1B1B1D), band: rgb(0xD8352A), ink: rgb(0xF2EDE3)),
        FilmStock(id: "kodak_verita_200d", brand: "Kodak", name: "Verita 200D", iso: 200, kind: .cinema,
                  defaultPaper: "kodak_2383", tagline: "现代日光 · 自然色彩",
                  body: rgb(0x2C2B29), band: rgb(0xC9B37E), ink: rgb(0xF2EDE3)),

        // Reversal
        FilmStock(id: "fujifilm_velvia_100", brand: "Fujifilm", name: "Velvia 100", iso: 100, kind: .slide,
                  defaultPaper: "", tagline: "浓郁饱和 · 风光之王",
                  body: rgb(0x6C3A8E), band: rgb(0xE9E2F0), ink: rgb(0xF6F1FA)),
        FilmStock(id: "fujifilm_provia_100f", brand: "Fujifilm", name: "Provia 100F", iso: 100, kind: .slide,
                  defaultPaper: "", tagline: "中性准确 · 干净通透",
                  body: rgb(0x2D6FB4), band: rgb(0xE6EEF6), ink: rgb(0xF4F8FC)),
        FilmStock(id: "kodak_ektachrome_100", brand: "Kodak", name: "Ektachrome E100", iso: 100, kind: .slide,
                  defaultPaper: "", tagline: "冷调清澈 · 蓝天更蓝",
                  body: rgb(0x1E4E8C), band: rgb(0xF0B92A), ink: rgb(0xF4F1E8)),
        FilmStock(id: "kodak_kodachrome_64", brand: "Kodak", name: "Kodachrome 64", iso: 64, kind: .slide,
                  defaultPaper: "", tagline: "传奇色彩 · 红黄浓烈",
                  body: rgb(0xF2C230), band: rgb(0xC8322B), ink: rgb(0x2A1A10)),

        // Black and white
        FilmStock(id: "kodak_tri_x_400", brand: "Kodak", name: "Tri-X 400", iso: 400, kind: .blackWhite,
                  defaultPaper: "ilford_multigrade_iv_rc", tagline: "纪实经典 · 粗犷颗粒",
                  body: rgb(0xF2C230), band: rgb(0x1A1A1A), ink: rgb(0x1A1A1A)),
        FilmStock(id: "ilford_hp5_plus_400", brand: "Ilford", name: "HP5 Plus", iso: 400, kind: .blackWhite,
                  defaultPaper: "ilford_multigrade_iv_rc", tagline: "柔和影调 · 宽容耐推",
                  body: rgb(0xEDEDED), band: rgb(0x111111), ink: rgb(0x111111)),
        FilmStock(id: "kodak_tmax_100", brand: "Kodak", name: "T-Max 100", iso: 100, kind: .blackWhite,
                  defaultPaper: "ilford_multigrade_iv_rc", tagline: "T 颗粒 · 锐利细腻",
                  body: rgb(0x1C1C1C), band: rgb(0xF2C230), ink: rgb(0xF2EDE3)),
        FilmStock(id: "fujifilm_neopan_acros_100_ii", brand: "Fujifilm", name: "Acros II", iso: 100, kind: .blackWhite,
                  defaultPaper: "ilford_multigrade_iv_rc", tagline: "银盐质感 · 极细颗粒",
                  body: rgb(0x2A2A2A), band: rgb(0x9A9A9A), ink: rgb(0xF2F2F2)),
    ]

    static let papers: [PrintPaper] = [
        PrintPaper(id: "kodak_portra_endura", name: "Kodak Portra Endura", tagline: "柔和自然 · 人像相纸", isBlackWhite: false),
        PrintPaper(id: "kodak_endura_premier", name: "Kodak Endura Premier", tagline: "反差适中 · 色彩准确", isBlackWhite: false),
        PrintPaper(id: "kodak_supra_endura", name: "Kodak Supra Endura", tagline: "鲜明饱和", isBlackWhite: false),
        PrintPaper(id: "kodak_ultra_endura", name: "Kodak Ultra Endura", tagline: "高饱和 · 高反差", isBlackWhite: false),
        PrintPaper(id: "kodak_ektacolor_edge", name: "Kodak Ektacolor Edge", tagline: "冲印店经典", isBlackWhite: false),
        PrintPaper(id: "fujifilm_crystal_archive_typeii", name: "Fujifilm Crystal Archive", tagline: "富士冲印 · 清爽", isBlackWhite: false),
        PrintPaper(id: "kodak_2383", name: "Kodak Vision 2383", tagline: "电影拷贝 · 银幕质感", isBlackWhite: false),
        PrintPaper(id: "kodak_2393", name: "Kodak Vision Premier 2393", tagline: "电影拷贝 · 更浓郁", isBlackWhite: false),
        PrintPaper(id: "ilford_multigrade_iv_rc", name: "Ilford Multigrade IV RC", tagline: "黑白可变反差相纸", isBlackWhite: true),
    ]

    static let defaultFilmID = "kodak_portra_400"

    static func film(_ id: String) -> FilmStock {
        films.first { $0.id == id } ?? films[0]
    }

    static func paper(_ id: String) -> PrintPaper? {
        papers.first { $0.id == id }
    }

    /// Papers that make sense for a stock: B&W papers for B&W film, colour papers otherwise.
    static func papers(for film: FilmStock) -> [PrintPaper] {
        guard film.kind.usesPrintPaper else { return [] }
        return papers.filter { $0.isBlackWhite == (film.kind == .blackWhite) }
    }

    static func films(of kind: FilmKind) -> [FilmStock] {
        films.filter { $0.kind == kind }
    }
}
