import SwiftUI
import UIKit

// MARK: - Colour

extension Color {
    /// `Color(hex: 0xF4A94A)` -- sRGB.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: opacity)
    }
}

/// Design tokens. One dark, warm palette for the whole app.
enum Theme {
    static let background = Color(hex: 0x0B0A09)
    static let surface = Color(hex: 0x171513)
    static let surfaceHigh = Color(hex: 0x221F1C)
    static let surfaceHigher = Color(hex: 0x2C2825)
    static let hairline = Color.white.opacity(0.08)
    static let hairlineStrong = Color.white.opacity(0.14)

    static let text = Color(hex: 0xF2EDE3)
    static let secondary = Color(hex: 0x9C948A)
    static let tertiary = Color(hex: 0x6E675F)

    static let accent = Color(hex: 0xF4A94A)
    static let accentDeep = Color(hex: 0xC9822F)
    static let lcd = Color(hex: 0xFF6A3D)
    static let danger = Color(hex: 0xEF5B4C)
    static let success = Color(hex: 0x9BC88E)

    /// The orange mask of a colour negative.
    static let filmBase = Color(red: 1.0, green: 0.66, blue: 0.42)
    /// Darkroom safelight red.
    static let safelight = Color(hex: 0x2A0D09)

    static let radiusSmall: CGFloat = 8
    static let radiusMedium: CGFloat = 14
    static let radiusLarge: CGFloat = 22
}

// MARK: - Type

enum AppFont {
    /// UI text. The default design: SF Rounded has no CJK glyphs, so mixed
    /// Chinese/Latin strings pair badly with it. Sizes in use: 10 (tracked
    /// Latin caps only), 11, 12, 13, 15, 17, 20, 28, 34.
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Monospaced numbers (counters, readouts).
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    /// The date-back LCD face.
    static func lcd(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .monospaced)
    }
}

/// Orange-red segment-display text with a faint glow, like a camera date back.
struct LCDTextStyle: ViewModifier {
    var size: CGFloat
    var color: Color = Theme.lcd
    var glow: Bool = true

    func body(content: Content) -> some View {
        content
            .font(AppFont.lcd(size))
            .monospacedDigit()
            .foregroundStyle(color)
            .shadow(color: glow ? color.opacity(0.4) : .clear, radius: glow ? max(1, size * 0.09) : 0)
    }
}

extension View {
    func lcdText(_ size: CGFloat, color: Color = Theme.lcd, glow: Bool = true) -> some View {
        modifier(LCDTextStyle(size: size, color: color, glow: glow))
    }

    /// A rounded surface card with a hairline edge.
    func surfaceCard(radius: CGFloat = Theme.radiusMedium, fill: Color = Theme.surface) -> some View {
        background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(fill))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Motion

enum Motion {
    /// Small controls: chips, toggles, presses.
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.86)
    /// The default spring for layout changes.
    static let standard = Animation.spring(response: 0.38, dampingFraction: 0.82)
    /// Large, calm movements (sheets of content, aspect morphs).
    static let gentle = Animation.spring(response: 0.52, dampingFraction: 0.88)
    /// A little overshoot for playful confirmations.
    static let bouncy = Animation.spring(response: 0.42, dampingFraction: 0.64)
    /// Cross-fades.
    static let fade = Animation.easeOut(duration: 0.22)

    /// With Reduce Motion on, big motions become a short fade-like ease.
    static func pick(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? .easeOut(duration: 0.16) : animation
    }
}

// MARK: - Haptics

/// Haptic helpers, gated by the "触感反馈" setting (`Haptics.isEnabled` is kept in
/// sync with `settings.haptics` by the root view).
@MainActor
enum Haptics {
    static var isEnabled = true

    private static let light = UIImpactFeedbackGenerator(style: .light)
    private static let heavy = UIImpactFeedbackGenerator(style: .heavy)
    private static let rigid = UIImpactFeedbackGenerator(style: .rigid)
    private static let soft = UIImpactFeedbackGenerator(style: .soft)
    private static let selectionGenerator = UISelectionFeedbackGenerator()
    private static let notification = UINotificationFeedbackGenerator()

    static func prepareShutter() {
        guard isEnabled else { return }
        heavy.prepare()
        rigid.prepare()
    }

    static func selection() {
        guard isEnabled else { return }
        selectionGenerator.selectionChanged()
        selectionGenerator.prepare()
    }

    static func tap() {
        guard isEnabled else { return }
        light.impactOccurred()
    }

    static func softTap(_ intensity: CGFloat = 0.6) {
        guard isEnabled else { return }
        soft.impactOccurred(intensity: intensity)
    }

    /// The shutter button going down.
    static func shutter() {
        guard isEnabled else { return }
        heavy.impactOccurred()
        rigid.prepare()
    }

    /// The shutter fired: a short ratchet, like a winding lever advancing the film.
    static func filmAdvance() {
        guard isEnabled else { return }
        rigid.impactOccurred(intensity: 0.75)
        Task {
            for i in 0..<3 {
                try? await Task.sleep(nanoseconds: 62_000_000)
                rigid.impactOccurred(intensity: 0.32 + 0.1 * CGFloat(i))
            }
        }
    }

    static func success() {
        guard isEnabled else { return }
        notification.notificationOccurred(.success)
    }

    static func warning() {
        guard isEnabled else { return }
        notification.notificationOccurred(.warning)
    }
}

// MARK: - Button styles

/// Press-down scale with a spring; the basic feel of every tappable thing.
struct PressableStyle: ButtonStyle {
    var scale: CGFloat = 0.92
    var pressedOpacity: Double = 0.85

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? scale : 1)
            .opacity(configuration.isPressed ? pressedOpacity : 1)
            .animation(.spring(response: 0.26, dampingFraction: 0.72), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
    static func pressable(scale: CGFloat) -> PressableStyle { PressableStyle(scale: scale) }
}

/// A round icon button face.
struct RoundIcon: View {
    let systemName: String
    var size: CGFloat = 44
    var iconSize: CGFloat = 17
    var tint: Color = Theme.text
    var fill: Color = Theme.surface

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(Circle().fill(fill))
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Circle())
    }
}

/// The amber primary capsule ("冲洗", "前往设置").
struct PrimaryCapsule: View {
    let title: String
    var systemImage: String? = nil
    var isEnabled: Bool = true
    /// Fixed height (e.g. 34 in toolbars); nil = 44.
    var height: CGFloat? = nil

    var body: some View {
        let h = height ?? 44
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage).font(.system(size: h < 40 ? 12 : 14, weight: .semibold))
            }
            Text(title).font(AppFont.ui(h < 40 ? 13 : 15, .semibold))
        }
        .foregroundStyle(Theme.background)
        .padding(.horizontal, h < 40 ? 14 : 20)
        .frame(height: h)
        .background(Capsule().fill(isEnabled ? Theme.accent : Theme.tertiary))
        .contentShape(Capsule())
    }
}

// MARK: - Geometry

enum LayoutMath {
    /// The largest size with `aspect` (width / height) that fits in `size`.
    static func fit(aspect: CGFloat, in size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0, aspect > 0 else { return .zero }
        if size.width / size.height > aspect {
            return CGSize(width: size.height * aspect, height: size.height)
        }
        return CGSize(width: size.width, height: size.width / aspect)
    }

    static func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
        min(upper, max(lower, value))
    }
}

/// The camera feed held upright is 3:4 (width / height). The viewfinder's
/// Metal view always has this shape; the chosen frame is a mask cut out of it,
/// which is exactly the centre crop the darkroom makes.
enum ViewfinderGeometry {
    static let sensorAspect: CGFloat = 3.0 / 4.0
}

// MARK: - Sheets

/// The one sheet background used everywhere: a thin material darkened
/// towards the app background.
struct SheetBackground: View {
    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            Theme.background.opacity(0.6)
        }
        .ignoresSafeArea()
    }
}
