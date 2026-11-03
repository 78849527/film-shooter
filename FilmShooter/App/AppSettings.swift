import Foundation
import Observation

/// The picture's shape in the camera, long : short.
enum FrameAspect: String, Codable, CaseIterable, Identifiable {
    case r3x2, r4x3, r1x1, r65x24

    var id: String { rawValue }

    var title: String {
        switch self {
        case .r3x2: return "3:2"
        case .r4x3: return "4:3"
        case .r1x1: return "1:1"
        case .r65x24: return "XPan"
        }
    }

    var subtitle: String {
        switch self {
        case .r3x2: return "135 标准"
        case .r4x3: return "645 / 半格"
        case .r1x1: return "6×6 方画幅"
        case .r65x24: return "宽幅全景"
        }
    }

    /// long : short (>= 1).
    var ratio: Double {
        switch self {
        case .r3x2: return 3.0 / 2.0
        case .r4x3: return 4.0 / 3.0
        case .r1x1: return 1.0
        case .r65x24: return 65.0 / 24.0
        }
    }

    /// width / height of the viewfinder held upright (portrait).
    var portraitAspect: Double { 1.0 / ratio }
}

/// Long edge cap for full-resolution developments. The engine keeps ~9 float
/// planes alive at full resolution, so this is what decides peak memory.
enum OutputQuality: String, Codable, CaseIterable, Identifiable {
    case standard, high, maximum

    var id: String { rawValue }

    var longEdge: Int {
        switch self {
        case .standard: return 3072
        case .high: return 4032
        case .maximum: return 6048
        }
    }

    var title: String {
        switch self {
        case .standard: return "标准"
        case .high: return "高"
        case .maximum: return "最高"
        }
    }

    var detail: String {
        switch self {
        case .standard: return "约 700 万像素 · 最快"
        case .high: return "约 1200 万像素"
        case .maximum: return "最高 3600 万像素 · 需要大内存"
        }
    }

    static var recommended: OutputQuality {
        ProcessInfo.processInfo.physicalMemory >= 5_500_000_000 ? .high : .standard
    }
}

/// User preferences, persisted in UserDefaults.
@Observable @MainActor
final class AppSettings {
    private let defaults = UserDefaults.standard

    var outputQuality: OutputQuality { didSet { save(outputQuality.rawValue, "outputQuality") } }
    var saveFormat: PhotoDecoder.Format { didSet { save(saveFormat.rawValue, "saveFormat") } }
    var autoSaveToPhotos: Bool { didSet { save(autoSaveToPhotos, "autoSaveToPhotos") } }
    var keepOriginals: Bool { didSet { save(keepOriginals, "keepOriginals") } }
    var showGrid: Bool { didSet { save(showGrid, "showGrid") } }
    var frameAspect: FrameAspect { didSet { save(frameAspect.rawValue, "frameAspect") } }
    var viewfinderGrain: Bool { didSet { save(viewfinderGrain, "viewfinderGrain") } }
    var haptics: Bool { didSet { save(haptics, "haptics") } }
    var rollLength: Int { didSet { save(rollLength, "rollLength") } }

    init() {
        let d = UserDefaults.standard
        outputQuality = OutputQuality(rawValue: d.string(forKey: "outputQuality") ?? "") ?? .recommended
        saveFormat = PhotoDecoder.Format(rawValue: d.string(forKey: "saveFormat") ?? "") ?? .heic
        autoSaveToPhotos = d.object(forKey: "autoSaveToPhotos") as? Bool ?? true
        keepOriginals = d.object(forKey: "keepOriginals") as? Bool ?? true
        showGrid = d.object(forKey: "showGrid") as? Bool ?? false
        frameAspect = FrameAspect(rawValue: d.string(forKey: "frameAspect") ?? "") ?? .r3x2
        viewfinderGrain = d.object(forKey: "viewfinderGrain") as? Bool ?? true
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        rollLength = d.object(forKey: "rollLength") as? Int ?? 36
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
