import SwiftUI
import PhotosUI
import AVFoundation

// MARK: - Top bar

/// 36 pt controls with 44 pt hit areas on a 44 pt bar; the frame counter in
/// the middle.
struct TopBar: View {
    @Binding var showAspectPicker: Bool
    let openSettings: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                FlashButton()
                AspectButton(isOpen: $showAspectPicker)
                Spacer(minLength: 0)
                RAWButton()
                Button {
                    openSettings()
                } label: {
                    RoundIcon(systemName: "gearshape", size: 36, iconSize: 15)
                        .uprightWithDevice()
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(Text("设置"))
            }
            FrameCounter()
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
        .animation(Motion.snappy, value: showAspectPicker)
    }
}

/// Off -> auto -> on, with a symbol replace transition. Hidden without a flash.
struct FlashButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let camera = model.camera
        ZStack {
            if camera.hasFlash {
                Button {
                    Haptics.selection()
                    withAnimation(Motion.snappy) { camera.flashMode = Self.next(camera.flashMode) }
                } label: {
                    Image(systemName: Self.symbol(camera.flashMode))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(camera.flashMode == .off ? Theme.text : Theme.accent)
                        .compatibleSymbolReplacement()
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.surface))
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        .uprightWithDevice()
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(Text("闪光灯：\(Self.title(camera.flashMode))"))
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: camera.hasFlash)
    }

    static func next(_ mode: AVCaptureDevice.FlashMode) -> AVCaptureDevice.FlashMode {
        switch mode {
        case .off: return .auto
        case .auto: return .on
        case .on: return .off
        @unknown default: return .off
        }
    }

    static func symbol(_ mode: AVCaptureDevice.FlashMode) -> String {
        switch mode {
        case .off: return "bolt.slash.fill"
        case .auto: return "bolt.badge.a.fill"
        case .on: return "bolt.fill"
        @unknown default: return "bolt.slash.fill"
        }
    }

    static func title(_ mode: AVCaptureDevice.FlashMode) -> String {
        switch mode {
        case .off: return "关"
        case .auto: return "自动"
        case .on: return "开"
        @unknown default: return "关"
        }
    }
}

/// Shows the current frame aspect; opens the aspect picker.
struct AspectButton: View {
    @EnvironmentObject private var model: AppModel
    @Binding var isOpen: Bool

    var body: some View {
        let aspect = model.settings.frameAspect
        Button {
            withAnimation(Motion.standard) { isOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                AspectGlyph(aspect: CGFloat(aspect.portraitAspect), selected: false, size: 14)
                Text(aspect.title)
                    .font(AppFont.ui(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .contentTransition(.interpolate)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(isOpen ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1))
            .padding(4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .animation(Motion.snappy, value: aspect)
        .accessibilityLabel(Text("画幅 \(aspect.title)"))
    }
}

/// A 36 pt capsule like the aspect button: amber when RAW is on; when off,
/// secondary text with a diagonal slash.
struct RAWButton: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let camera = model.camera
        ZStack {
            if camera.isRAWSupported {
                let on = camera.captureRAW
                Button {
                    Haptics.selection()
                    withAnimation(Motion.snappy) { camera.captureRAW.toggle() }
                    model.show(on ? "已关闭 RAW" : "RAW 已开启 · 同时保存 DNG 底片", seconds: 1.6)
                } label: {
                    Text("RAW")
                        .font(AppFont.mono(12, .bold))
                        .foregroundStyle(on ? Theme.background : Theme.secondary)
                        .overlay {
                            if !on {
                                Capsule()
                                    .fill(Theme.secondary)
                                    .frame(width: 30, height: 1.2)
                                    .rotationEffect(.degrees(-24))
                            }
                        }
                        .uprightWithDevice()
                        .padding(.horizontal, 12)
                        .frame(height: 36)
                        .background(Capsule().fill(on ? Theme.accent : Theme.surface))
                        .overlay(Capsule().strokeBorder(on ? Color.clear : Theme.hairline, lineWidth: 1))
                        .padding(4)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(Text(on ? "RAW 已开启" : "RAW 已关闭"))
                .transition(.scale(scale: 0.7).combined(with: .opacity))
            }
        }
        .animation(Motion.snappy, value: camera.isRAWSupported)
    }
}

/// The analog frame counter: LCD digits and "/36" on a 36 pt black plate.
struct FrameCounter: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let n = model.frameNumber
        let total = model.settings.rollLength
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            Text(String(format: "%02ld", n))
                .lcdText(20)
                .compatibleNumericText(Double(n))
            Text("/\(total)")
                .lcdText(11, color: Theme.lcd.opacity(0.5), glow: false)
        }
        .padding(.horizontal, 12)
        .frame(height: 36)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.lcd.opacity(0.14), lineWidth: 1))
        .animation(Motion.bouncy, value: n)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("第 \(n) 张，共 \(total) 张"))
    }
}

// MARK: - Aspect picker

struct AspectPickerPanel: View {
    @EnvironmentObject private var model: AppModel
    let close: () -> Void

    var body: some View {
        let current = model.settings.frameAspect
        HStack(spacing: 6) {
            ForEach(FrameAspect.allCases) { aspect in
                let selected = aspect == current
                Button {
                    guard aspect != current else { close(); return }
                    Haptics.selection()
                    withAnimation(Motion.gentle) { model.settings.frameAspect = aspect }
                    Task {
                        try? await Task.sleep(nanoseconds: 200_000_000)
                        close()
                    }
                } label: {
                    VStack(spacing: 6) {
                        AspectGlyph(aspect: CGFloat(aspect.portraitAspect), selected: selected, size: 28)
                        Text(aspect.title)
                            .font(AppFont.ui(13, .semibold))
                            .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.85))
                        Text(aspect.subtitle)
                            .font(AppFont.ui(11))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Color.white.opacity(0.08) : Color.clear))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(selected ? Theme.accent.opacity(0.55) : Color.clear, lineWidth: 1))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.pressable(scale: 0.95))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.surface))
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairlineStrong, lineWidth: 1))
        .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
        .padding(.horizontal, 14)
        .animation(Motion.snappy, value: current)
    }
}

/// A frame outline of the given aspect (width / height).
struct AspectGlyph: View {
    let aspect: CGFloat
    var selected: Bool = false
    var size: CGFloat = 28

    var body: some View {
        let fitted = LayoutMath.fit(aspect: aspect, in: CGSize(width: size, height: size))
        RoundedRectangle(cornerRadius: max(1.5, size * 0.08), style: .continuous)
            .strokeBorder(selected ? Theme.accent : Theme.text.opacity(0.75), lineWidth: max(1, size * 0.06))
            .frame(width: max(4, fitted.width), height: max(4, fitted.height))
            .frame(width: size, height: size)
    }
}

// MARK: - Deck

/// [gallery 50] — shutter — [flip 50]. Importing a photo lives in the gallery
/// (and in the gallery button's context menu).
struct ControlDeck: View {
    let namespace: Namespace.ID
    @Binding var editor: EditorModel?
    let openGallery: () -> Void

    @State private var showImporter = false

    var body: some View {
        ZStack {
            ShutterButton()
            HStack(alignment: .center) {
                GalleryButton(namespace: namespace, action: openGallery, importPhoto: { showImporter = true })
                Spacer(minLength: 0)
                FlipButton()
            }
        }
        .padding(.horizontal, 28)
        .frame(height: 88)
        .photoImporter(isPresented: $showImporter) { newEditor in
            editor = newEditor
        }
    }
}

/// The latest print -- or, while frames are developing, the current one as a
/// negative turning positive, traced by a progress line, with a count badge.
/// Long-press for "导入照片冲洗".
struct GalleryButton: View {
    @EnvironmentObject private var model: AppModel
    let namespace: Namespace.ID
    let action: () -> Void
    let importPhoto: () -> Void

    var body: some View {
        let darkroom = model.darkroom
        let jobs = darkroom.jobs
        let active = jobs.first(where: { $0.phase == .developing }) ?? jobs.last
        let hasFailed = jobs.contains { job in
            if case .failed = job.phase { return true }
            return false
        }
        let photos = model.library.photos
        let last = darkroom.lastDeveloped.flatMap { p in photos.first(where: { $0.id == p.id }) }
            ?? photos.first
        Button(action: action) {
            ZStack {
                Theme.surface
                if let job = active {
                    DevelopingJobImage(job: job) { progress in
                        ProgressBorder(progress: progress, cornerRadius: 10, lineWidth: 2.5)
                    }
                    .id(job.id)
                    .transition(.opacity)
                } else if let last {
                    LibraryThumbnail(photo: last)
                        .id(last.thumbName)
                        .transition(.opacity)
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 17, weight: .light))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 50, height: 50)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                badge(count: darkroom.pendingCount, failed: hasFailed)
            }
            .compatibleBadgePulse(trigger: darkroom.completedCount)
            .animation(.easeInOut(duration: 0.45), value: active?.id)
            .animation(.easeInOut(duration: 0.45), value: last?.thumbName)
            .uprightWithDevice()
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
        .compatibleMatchedTransitionSource(id: "gallery", in: namespace)
        .contextMenu {
            Button(action: action) {
                Label("打开底片册", systemImage: "photo.on.rectangle")
            }
            Button(action: importPhoto) {
                Label("导入照片冲洗", systemImage: "photo.badge.plus")
            }
        }
        .compatibleOnChange(of: darkroom.completedCount) { _, _ in Haptics.softTap(0.7) }
        .accessibilityLabel(Text("底片册"))
        .accessibilityHint(Text("长按可导入照片冲洗"))
    }

    @ViewBuilder
    private func badge(count: Int, failed: Bool) -> some View {
        ZStack {
            if failed {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 10, weight: .heavy))
                    .foregroundStyle(Color.white)
                    .frame(width: 18, height: 18)
                    .background(Circle().fill(Theme.danger))
                    .transition(.scale.combined(with: .opacity))
            } else if count > 0 {
                Text("\(count)")
                    .font(AppFont.mono(10, .bold))
                    .foregroundStyle(Theme.background)
                    .compatibleNumericText(Double(count))
                    .padding(.horizontal, 5)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(Capsule().fill(Theme.accent))
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .offset(x: 6, y: -6)
        .animation(Motion.bouncy, value: count)
        .animation(Motion.bouncy, value: failed)
    }
}

// MARK: - Shutter

/// A chrome release button inside an advance ring: the ring's fine ticks turn
/// one notch per frame; only the disc sinks under the thumb.
struct ShutterButton: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var notch = 0

    var body: some View {
        let camera = model.camera
        let live = camera.state == .running || ScreenshotMode.isActive
        let busy = camera.isCapturing || camera.isSwitching
        Button {
            guard !camera.isCapturing else { return }
            Task { await model.shoot() }
        } label: {
            Color.clear
        }
        .buttonStyle(ShutterButtonStyle(isLive: live, isBusy: busy, notch: notch))
        .disabled(!live)
        .compatibleOnChange(of: model.frameNumber) { _, _ in
            // Always forward, also when the roll wraps to 1.
            if !reduceMotion { notch += 1 }
        }
        .accessibilityLabel(Text("快门"))
    }
}

/// Fine ticks around a circle (the film-advance ring).
struct TickRing: Shape {
    var count = 36
    var length: CGFloat = 3.5

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let r = min(rect.width, rect.height) / 2
        for i in 0..<count {
            let a = CGFloat(i) / CGFloat(count) * 2 * .pi
            p.move(to: CGPoint(x: c.x + cos(a) * (r - length), y: c.y + sin(a) * (r - length)))
            p.addLine(to: CGPoint(x: c.x + cos(a) * r, y: c.y + sin(a) * r))
        }
        return p
    }
}

struct ShutterFace: View {
    let isLive: Bool
    let isDown: Bool
    let notch: Int

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.text.opacity(0.92), lineWidth: 2.5)
                .frame(width: 80, height: 80)
            TickRing()
                .stroke(Theme.text.opacity(0.28), style: StrokeStyle(lineWidth: 1, lineCap: .round))
                .frame(width: 72, height: 72)
                .rotationEffect(.degrees(Double(notch) * 10))
            Circle()
                .fill(RadialGradient(colors: [Color.white, Color(hex: 0xEDE8DF), Color(hex: 0xC9C1B4)],
                                     center: UnitPoint(x: 0.38, y: 0.3), startRadius: 1, endRadius: 38))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 0.75))
                .frame(width: 60, height: 60)
                .shadow(color: .black.opacity(isDown ? 0.1 : 0.35), radius: isDown ? 1 : 3, y: isDown ? 0.5 : 1.5)
                .scaleEffect(isDown ? 0.9 : 1)
                .brightness(isDown ? -0.06 : 0)
        }
        .frame(width: 84, height: 84)
        .opacity(isLive ? 1 : 0.35)
        .contentShape(Circle())
        .animation(.spring(response: 0.18, dampingFraction: 0.7), value: isDown)
        .animation(.spring(response: 0.5, dampingFraction: 0.75), value: notch)
        .animation(.easeOut(duration: 0.3), value: isLive)
    }
}

@MainActor
struct ShutterButtonStyle: ButtonStyle {
    let isLive: Bool
    let isBusy: Bool
    let notch: Int

    func makeBody(configuration: Configuration) -> some View {
        ShutterFace(isLive: isLive, isDown: configuration.isPressed || isBusy, notch: notch)
            .compatibleOnChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.softTap(0.55) }
            }
    }
}

// MARK: - Flip

/// Front/back with a 3D flip of the icon.
struct FlipButton: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var turns: Double = 0

    var body: some View {
        let camera = model.camera
        let enabled = camera.state == .running && !camera.isSwitching && !camera.isCapturing
        Button {
            Haptics.tap()
            withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.6, dampingFraction: 0.8)) {
                turns += reduceMotion ? 0 : 360
            }
            camera.flipCamera()
        } label: {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(Theme.text)
                .rotation3DEffect(.degrees(turns), axis: (x: 0, y: 1, z: 0), perspective: 0.6)
                .uprightWithDevice()
                .frame(width: 50, height: 50)
                .background(Circle().fill(Theme.surface))
                .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                .contentShape(Circle())
        }
        .buttonStyle(.pressable)
        .disabled(!enabled)
        .opacity(enabled || camera.isSwitching ? 1 : 0.45)
        .accessibilityLabel(Text("切换前后摄像头"))
    }
}

// MARK: - Import

/// Presents the photo picker and turns the picked photo into a darkroom
/// editor (`onEditor`). Shared by the gallery header and the gallery button.
@MainActor
struct PhotoImporter: ViewModifier {
    @EnvironmentObject private var model: AppModel
    @Binding var isPresented: Bool
    let onEditor: (EditorModel) -> Void

    @State private var item: PhotosPickerItem?

    func body(content: Content) -> some View {
        content
            .photosPicker(isPresented: $isPresented, selection: $item, matching: .images,
                          preferredItemEncoding: .current)
            .compatibleOnChange(of: item) { _, newItem in
                guard let newItem else { return }
                load(newItem)
            }
    }

    private func load(_ picked: PhotosPickerItem) {
        model.show("正在读取照片…", seconds: 8)
        Task {
            defer { item = nil }
            do {
                guard let data = try await picked.loadTransferable(type: Data.self) else {
                    model.show("无法读取这张照片")
                    return
                }
                let isRAW = PhotoDecoder.isRAW(data: data)
                model.banner = nil
                onEditor(EditorModel(source: .imported(data: data, isRAW: isRAW), recipe: model.recipe,
                                     outputLongEdge: model.settings.outputQuality.longEdge))
            } catch {
                model.show("导入失败：\(error.localizedDescription)")
            }
        }
    }
}

extension View {
    /// The photo picker → darkroom editor flow.
    func photoImporter(isPresented: Binding<Bool>, onEditor: @escaping (EditorModel) -> Void) -> some View {
        modifier(PhotoImporter(isPresented: isPresented, onEditor: onEditor))
    }
}
