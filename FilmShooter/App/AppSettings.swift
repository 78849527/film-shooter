import Combine
import Foundation

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

/// The editing controls follow the user's preferred thumb.
enum EditorHandedness: String, Codable, CaseIterable, Identifiable {
    case left, right

    var id: String { rawValue }
    var title: String { self == .left ? "左手" : "右手" }
}

/// The initial destination on a fresh app launch.
enum StartupDestination: String, Codable, CaseIterable, Identifiable {
    case camera, editor

    var id: String { rawValue }
    var title: String { self == .camera ? "相机" : "修图" }
}

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    // Explicit publisher remains stable with no @Published properties.
    // Settings must notify SwiftUI after their new values are stored.
    let objectWillChange = ObservableObjectPublisher()
    private let defaults = UserDefaults.standard

    var outputQuality: OutputQuality { didSet { save(outputQuality.rawValue, "outputQuality"); objectWillChange.send() } }
    var saveFormat: PhotoDecoder.Format { didSet { save(saveFormat.rawValue, "saveFormat"); objectWillChange.send() } }
    var autoSaveToPhotos: Bool { didSet { save(autoSaveToPhotos, "autoSaveToPhotos"); objectWillChange.send() } }
    var keepOriginals: Bool { didSet { save(keepOriginals, "keepOriginals"); objectWillChange.send() } }
    var showGrid: Bool { didSet { save(showGrid, "showGrid"); objectWillChange.send() } }
    var frameAspect: FrameAspect { didSet { save(frameAspect.rawValue, "frameAspect"); objectWillChange.send() } }
    var editorHandedness: EditorHandedness {
        didSet { save(editorHandedness.rawValue, "editorHandedness"); objectWillChange.send() }
    }
    var startupDestination: StartupDestination {
        didSet { save(startupDestination.rawValue, "startupDestination"); objectWillChange.send() }
    }
    var viewfinderGrain: Bool { didSet { save(viewfinderGrain, "viewfinderGrain"); objectWillChange.send() } }
    var haptics: Bool {
        didSet {
            save(haptics, "haptics")
            Haptics.isEnabled = haptics
            if haptics && !oldValue {
                // A clear confirmation pulse so enabling the switch is testable.
                Haptics.tap()
            }
            objectWillChange.send()
        }
    }
    var rollLength: Int { didSet { save(rollLength, "rollLength"); objectWillChange.send() } }
    /// Favourite films, in the order the user starred them.
    var favoriteFilmIDs: [String] { didSet { save(favoriteFilmIDs, "favoriteFilmIDs"); objectWillChange.send() } }
    /// Most recently used films, most recent first.
    var recentFilmIDs: [String] { didSet { save(recentFilmIDs, "recentFilmIDs"); objectWillChange.send() } }

    init() {
        let d = UserDefaults.standard
        outputQuality = OutputQuality(rawValue: d.string(forKey: "outputQuality") ?? "") ?? .recommended
        saveFormat = PhotoDecoder.Format(rawValue: d.string(forKey: "saveFormat") ?? "") ?? .heic
        autoSaveToPhotos = d.object(forKey: "autoSaveToPhotos") as? Bool ?? true
        keepOriginals = d.object(forKey: "keepOriginals") as? Bool ?? true
        showGrid = d.object(forKey: "showGrid") as? Bool ?? false
        frameAspect = FrameAspect(rawValue: d.string(forKey: "frameAspect") ?? "") ?? .r3x2
        editorHandedness = EditorHandedness(rawValue: d.string(forKey: "editorHandedness") ?? "") ?? .right
        startupDestination = StartupDestination(rawValue: d.string(forKey: "startupDestination") ?? "") ?? .camera
        viewfinderGrain = d.object(forKey: "viewfinderGrain") as? Bool ?? true
        haptics = d.object(forKey: "haptics") as? Bool ?? true
        rollLength = d.object(forKey: "rollLength") as? Int ?? 36
        favoriteFilmIDs = d.stringArray(forKey: "favoriteFilmIDs")
            ?? ["kodak_portra_400", "kodak_gold_200", "fujifilm_pro_400h", "cinestill_800t", "kodak_tri_x_400"]
        recentFilmIDs = d.stringArray(forKey: "recentFilmIDs") ?? []
        // Do not depend on the root SwiftUI view update order for haptics.
        Haptics.isEnabled = haptics
    }

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
