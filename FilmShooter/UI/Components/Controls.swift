import SwiftUI

// MARK: - Slider

/// A film-darkroom slider: hairline track, a notch at the default value, an
/// amber fill from the notch to the thumb, a value bubble while dragging, a
/// soft detent at the default and double-tap to reset. Range labels (冷/暖…)
/// sit at the two ends of the track.
///
/// The drag is attached simultaneously and locks to the horizontal axis on its
/// first movement, so vertical scrolls through a sheet still work.
struct FilmSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var defaultValue: Double = 0
    var leadingLabel: String? = nil
    var trailingLabel: String? = nil
    var format: (Double) -> String = FilmSlider.signed
    /// Called with true when a drag starts and false when it ends.
    var compact: Bool = false
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var isDragging = false
    @State private var startValue: Double = 0
    @State private var lockedAxis: Axis?
    @State private var inDetent = false

    private var span: Double { max(0.0001, range.upperBound - range.lowerBound) }
    private var isAtDefault: Bool { abs(value - defaultValue) < span * 0.002 }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(AppFont.ui(compact ? 12 : 15, .medium))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text(format(value))
                    .font(AppFont.mono(compact ? 10 : 12))
                    .monospacedDigit()
                    .foregroundStyle(isAtDefault ? Theme.secondary : Theme.text)
                    .animation(Motion.fade, value: isAtDefault)
            }
            HStack(spacing: compact ? 5 : 10) {
                if let leadingLabel {
                    Text(leadingLabel)
                        .font(AppFont.ui(compact ? 10 : 11))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize()
                }
                track
                    .frame(height: compact ? 23 : 26)
                if let trailingLabel {
                    Text(trailingLabel)
                        .font(AppFont.ui(compact ? 10 : 11))
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize()
                }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            guard !isAtDefault else { return }
            Haptics.softTap()
            onEditingChanged(true)
            withAnimation(Motion.standard) { value = defaultValue }
            onEditingChanged(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(format(value)))
        .accessibilityAdjustableAction { direction in
            let stepSize = span / 20
            switch direction {
            case .increment: value = min(range.upperBound, value + stepSize)
            case .decrement: value = max(range.lowerBound, value - stepSize)
            @unknown default: break
            }
        }
    }

    private var track: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let fraction = CGFloat((LayoutMath.clamp(value, range.lowerBound, range.upperBound) - range.lowerBound) / span)
            let zero = CGFloat((defaultValue - range.lowerBound) / span)
            let thumbX = fraction * width
            let zeroX = zero * width

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 3)
                Capsule()
                    .fill(Theme.accent)
                    .frame(width: max(0, abs(thumbX - zeroX)), height: 3)
                    .offset(x: min(thumbX, zeroX))
                Capsule()
                    .fill(Theme.secondary.opacity(0.9))
                    .frame(width: 1.5, height: 10)
                    .offset(x: zeroX - 0.75)
                Circle()
                    .fill(Theme.text)
                    .frame(width: 18, height: 18)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .scaleEffect(isDragging ? 1.2 : 1)
                    .offset(x: thumbX - 9)
                if isDragging {
                    Text(format(value))
                        .font(AppFont.mono(11, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.background)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Theme.text))
                        .frame(width: 64)
                        .offset(x: thumbX - 32, y: -26)
                        .transition(.scale(scale: 0.6, anchor: .bottom).combined(with: .opacity))
                        .allowsHitTesting(false)
                }
            }
            .frame(width: width, height: geo.size.height)
            .contentShape(Rectangle())
            .simultaneousGesture(dragGesture(width: width))
        }
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .local)
            .onChanged { g in
                if lockedAxis == nil {
                    let horizontal = abs(g.translation.width) >= abs(g.translation.height)
                    lockedAxis = horizontal ? .horizontal : .vertical
                    if horizontal {
                        startValue = value
                        inDetent = isAtDefault
                        onEditingChanged(true)
                        withAnimation(Motion.snappy) { isDragging = true }
                    }
                }
                guard lockedAxis == .horizontal else { return }
                var v = startValue + Double(g.translation.width / width) * span
                v = LayoutMath.clamp(v, range.lowerBound, range.upperBound)
                let quantum = span / 400
                v = (v / quantum).rounded() * quantum
                let near = abs(v - defaultValue) < span * 0.022
                if near { v = defaultValue }
                if near != inDetent {
                    inDetent = near
                    if near { Haptics.selection() }
                }
                if v != value { value = v }
            }
            .onEnded { _ in
                lockedAxis = nil
                if isDragging {
                    withAnimation(Motion.snappy) { isDragging = false }
                    onEditingChanged(false)
                }
            }
    }

    // Formats.
    nonisolated static func signed(_ v: Double) -> String {
        abs(v) < 0.005 ? "0" : String(format: "%+.2f", v)
    }

    nonisolated static func ev(_ v: Double) -> String {
        abs(v) < 0.005 ? "0 EV" : String(format: "%+.1f EV", v)
    }

    nonisolated static func times(_ v: Double) -> String {
        v < 0.005 ? "关" : String(format: "%.1f×", v)
    }
}

// MARK: - Segmented

/// A segmented control whose selection pill slides with a spring. The pill is
/// a neutral light fill (amber is kept for "on" states and primary actions).
struct PillSegmented<Option: Hashable>: View {
    let options: [Option]
    @Binding var selection: Option
    let title: (Option) -> String
    var subtitle: ((Option) -> String)? = nil

    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button {
                    guard option != selection else { return }
                    Haptics.selection()
                    withAnimation(Motion.snappy) { selection = option }
                } label: {
                    VStack(spacing: 1) {
                        Text(title(option))
                            .font(AppFont.ui(13, .semibold))
                        if let subtitle {
                            Text(subtitle(option))
                                .font(AppFont.ui(11))
                                .opacity(0.8)
                        }
                    }
                    .foregroundStyle(selected ? Theme.text : Theme.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, subtitle == nil ? 7 : 6)
                    .background {
                        if selected {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(Color.white.opacity(0.14))
                                .matchedGeometryEffect(id: "pill", in: namespace)
                        }
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(3)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Color.white.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
    }
}

// MARK: - Rows & sections

/// A toggle row with an optional explanation underneath.
struct SettingToggle: View {
    let title: String
    var subtitle: String? = nil
    var systemImage: String? = nil
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: 12) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(Theme.secondary)
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(AppFont.ui(15, .medium))
                        .foregroundStyle(Theme.text)
                    if let subtitle {
                        Text(subtitle)
                            .font(AppFont.ui(12))
                            .foregroundStyle(Theme.secondary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .tint(Theme.accent)
        .compatibleOnChange(of: isOn) { _, _ in Haptics.selection() }
    }
}

/// A thin divider; `inset` lines it up with row text after an icon.
struct RowDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

/// A titled group of controls on a surface card.
struct ControlSection<Content: View>: View {
    let title: String
    var trailing: String? = nil
    var spacing: CGFloat = 16
    var compact: Bool = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 4 : 8) {
            HStack {
                Text(title)
                    .font(AppFont.ui(compact ? 11 : 13, .medium))
                    .foregroundStyle(Theme.secondary)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(AppFont.ui(compact ? 10 : 11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .padding(.horizontal, compact ? 2 : 4)
            VStack(alignment: .leading, spacing: spacing) {
                content()
            }
            .padding(compact ? 9 : 14)
            .surfaceCard(radius: compact ? 12 : 18)
        }
    }
}

// MARK: - Device rotation

/// Keeps an icon upright when the phone is turned (the UI itself stays portrait).
@MainActor
struct DeviceRotation: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        let angle = model.camera.uiRotationAngle
        content
            .rotationEffect(.degrees(angle))
            .animation(Motion.pick(Motion.standard, reduceMotion: reduceMotion), value: angle)
    }
}

extension View {
    func uprightWithDevice() -> some View { modifier(DeviceRotation()) }
}

// MARK: - Banner

/// `model.banner` as a capsule toast that springs in from the top.
struct BannerOverlay: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var topPadding: CGFloat = 8

    var body: some View {
        VStack {
            if let text = model.banner {
                Text(text)
                    .font(AppFont.ui(13, .medium))
                    .foregroundStyle(Theme.text)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(Theme.surfaceHigh))
                    .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
                    .padding(.horizontal, 24)
                    .id(text)
                    .transition(bannerTransition)
            }
            Spacer(minLength: 0)
        }
        .padding(.top, topPadding)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        .animation(Motion.pick(Motion.bouncy, reduceMotion: reduceMotion), value: model.banner)
    }

    private var bannerTransition: AnyTransition {
        if reduceMotion { return AnyTransition.opacity }
        return AnyTransition.move(edge: .top)
            .combined(with: .opacity)
            .combined(with: .scale(scale: 0.92, anchor: .top))
    }
}
