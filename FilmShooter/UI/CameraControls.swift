import SwiftUI
import PhotosUI
import AVFoundation

// MARK: - Top bar

struct TopBar: View {
    @Binding var showAspectPicker: Bool
    let openSettings: () -> Void

    var body: some View {
        ZStack {
            HStack(spacing: 8) {
                FlashButton()
                AspectButton(isOpen: $showAspectPicker)
                Spacer(minLength: 0)
                RAWButton()
                Button {
                    Haptics.tap()
                    openSettings()
                } label: {
                    RoundIcon(systemName: "gearshape", size: 36, iconSize: 15)
                        .uprightWithDevice()
                }
                .buttonStyle(.pressable)
                .accessibilityLabel(Text("设置"))
            }
            FrameCounter()
        }
        .padding(.horizontal, 14)
        .frame(height: 50)
        .animation(Motion.snappy, value: showAspectPicker)
    }
}

/// Off -> auto -> on, with a symbol replace transition. Hidden without a flash.
struct FlashButton: View {
    @Environment(AppModel.self) private var model

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
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: 36, height: 36)
                        .background(Circle().fill(Theme.surface))
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        .uprightWithDevice()
                        .contentShape(Circle())
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
    @Environment(AppModel.self) private var model
    @Binding var isOpen: Bool

    var body: some View {
        let aspect = model.settings.frameAspect
        Button {
            Haptics.tap()
            withAnimation(Motion.standard) { isOpen.toggle() }
        } label: {
            HStack(spacing: 6) {
                AspectGlyph(aspect: CGFloat(aspect.portraitAspect), selected: isOpen, size: 14)
                Text(aspect.title)
                    .font(AppFont.ui(13, .semibold))
                    .foregroundStyle(isOpen ? Theme.accent : Theme.text)
                    .contentTransition(.interpolate)
            }
            .padding(.horizontal, 11)
            .frame(height: 36)
            .background(Capsule().fill(Theme.surface))
            .overlay(Capsule().strokeBorder(isOpen ? Theme.accent.opacity(0.5) : Theme.hairline, lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.pressable)
        .animation(Motion.snappy, value: aspect)
        .accessibilityLabel(Text("画幅 \(aspect.title)"))
    }
}

struct RAWButton: View {
    @Environment(AppModel.self) private var model

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
                        .font(AppFont.mono(11, .bold))
                        .foregroundStyle(on ? Theme.background : Theme.secondary)
                        .strikethrough(!on, color: Theme.secondary.opacity(0.7))
                        .padding(.horizontal, 8)
                        .frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(on ? Theme.accent : Color.clear))
                        .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(on ? Color.clear : Theme.hairlineStrong, lineWidth: 1))
                        .uprightWithDevice()
                        .frame(height: 36)
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

/// The analog frame counter: big LCD digits over unlit "88" segments, "/36".
struct FrameCounter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let n = model.frameNumber
        let total = model.settings.rollLength
        HStack(alignment: .firstTextBaseline, spacing: 1) {
            ZStack {
                Text("88")
                    .lcdText(22, color: Theme.lcd.opacity(0.08), glow: false)
                Text(String(format: "%02ld", n))
                    .lcdText(22)
                    .contentTransition(.numericText(value: Double(n)))
            }
            Text("/\(total)")
                .lcdText(11, color: Theme.lcd.opacity(0.5), glow: false)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.black))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Theme.lcd.opacity(0.16), lineWidth: 1))
        .animation(Motion.bouncy, value: n)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("第 \(n) 张，共 \(total) 张"))
    }
}

// MARK: - Aspect picker

struct AspectPickerPanel: View {
    @Environment(AppModel.self) private var model
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
                            .foregroundStyle(selected ? Theme.accent : Theme.text)
                        Text(aspect.subtitle)
                            .font(AppFont.ui(9.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 11)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? Theme.accent.opacity(0.12) : Color.clear))
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

/// Gallery thumbnail, shutter, import and flip.
struct ControlDeck: View {
    let namespace: Namespace.ID
    @Binding var editor: EditorModel?
    let openGallery: () -> Void

    var body: some View {
        ZStack {
            ShutterButton()
            HStack(alignment: .center) {
                GalleryButton(namespace: namespace, action: openGallery)
                Spacer(minLength: 0)
                HStack(spacing: 12) {
                    ImportButton(editor: $editor)
                    FlipButton()
                }
            }
        }
        .padding(.horizontal, 22)
        .frame(height: 92)
    }
}

/// The latest print -- or, while frames are developing, the current one as a
/// negative turning positive, traced by a progress line, with a count badge.
struct GalleryButton: View {
    @Environment(AppModel.self) private var model
    let namespace: Namespace.ID
    let action: () -> Void

    var body: some View {
        let darkroom = model.darkroom
        let jobs = darkroom.jobs
        let active = jobs.first(where: { $0.phase == .developing }) ?? jobs.last
        let hasFailed = jobs.contains { job in
            if case .failed = job.phase { return true }
            return false
        }
        let photos = model.library.photos
        let last = darkroom.lastDeveloped.flatMap { p in photos.contains(where: { $0.id == p.id }) ? p : nil }
            ?? photos.first
        Button {
            Haptics.tap()
            action()
        } label: {
            ZStack {
                Theme.surface
                if let job = active {
                    DevelopingJobImage(job: job) { progress in
                        ProgressBorder(progress: progress, cornerRadius: 12, lineWidth: 2.5)
                    }
                    .transition(.opacity)
                } else if let last {
                    LibraryThumbnail(photo: last)
                        .id(last.fileName)
                        .transition(.opacity)
                } else {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 18, weight: .light))
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 54, height: 54)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.hairlineStrong, lineWidth: 1))
            .overlay(alignment: .topTrailing) {
                badge(count: darkroom.pendingCount, failed: hasFailed)
            }
            .phaseAnimator([1.0, 1.1, 1.0], trigger: darkroom.completedCount) { content, scale in
                content.scaleEffect(scale)
            } animation: { _ in
                .spring(response: 0.26, dampingFraction: 0.6)
            }
            .animation(.easeInOut(duration: 0.45), value: active?.id)
            .animation(.easeInOut(duration: 0.45), value: last?.fileName)
            .uprightWithDevice()
        }
        .buttonStyle(.pressable)
        .matchedTransitionSource(id: "gallery", in: namespace)
        .onChange(of: darkroom.completedCount) { _, _ in Haptics.softTap(0.7) }
        .accessibilityLabel(Text("底片册"))
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
                    .contentTransition(.numericText(value: Double(count)))
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

/// Outer ring and a pale inner disc that sinks under the thumb.
struct ShutterButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let camera = model.camera
        let live = camera.state == .running || ScreenshotMode.isActive
        let busy = camera.isCapturing || camera.isSwitching
        Button {
            guard !camera.isCapturing else { return }
            Task { await model.shoot() }
        } label: {
            ShutterFace(isLive: live, isBusy: busy)
        }
        .buttonStyle(ShutterButtonStyle())
        .disabled(!live)
        .accessibilityLabel(Text("快门"))
    }
}

struct ShutterFace: View {
    let isLive: Bool
    let isBusy: Bool

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.text.opacity(isLive ? 0.95 : 0.3), lineWidth: 3.5)
                .frame(width: 80, height: 80)
            Circle()
                .fill(RadialGradient(colors: [Color(hex: 0xFBF8F2), Color(hex: 0xD9D1C5)],
                                     center: UnitPoint(x: 0.4, y: 0.32), startRadius: 2, endRadius: 42))
                .overlay(Circle().strokeBorder(Color.black.opacity(0.07), lineWidth: 1).padding(7))
                .frame(width: 66, height: 66)
                .scaleEffect(isBusy ? 0.86 : 1)
                .opacity(isLive ? 1 : 0.3)
        }
        .frame(width: 84, height: 84)
        .contentShape(Circle())
        .animation(.spring(response: 0.24, dampingFraction: 0.62), value: isBusy)
        .animation(.easeOut(duration: 0.3), value: isLive)
    }
}

@MainActor
struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.6), value: configuration.isPressed)
            .onChange(of: configuration.isPressed) { _, pressed in
                if pressed { Haptics.shutter() }
            }
    }
}

/// Front/back with a 3D flip of the icon.
struct FlipButton: View {
    @Environment(AppModel.self) private var model
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

/// Pick a photo from the library and open it in the darkroom editor.
struct ImportButton: View {
    @Environment(AppModel.self) private var model
    @Binding var editor: EditorModel?

    @State private var item: PhotosPickerItem?
    @State private var isLoading = false

    var body: some View {
        PhotosPicker(selection: $item, matching: .images, preferredItemEncoding: .current) {
            ZStack {
                if isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Theme.text)
                        .transition(.opacity)
                } else {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.text)
                        .uprightWithDevice()
                        .transition(.opacity)
                }
            }
            .frame(width: 40, height: 40)
            .background(Circle().fill(Theme.surface))
            .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
            .contentShape(Circle())
            .animation(Motion.fade, value: isLoading)
        }
        .buttonStyle(.pressable)
        .disabled(isLoading)
        .accessibilityLabel(Text("导入照片冲洗"))
        .onChange(of: item) { _, newItem in
            guard let newItem else { return }
            load(newItem)
        }
    }

    private func load(_ picked: PhotosPickerItem) {
        isLoading = true
        Task {
            defer {
                isLoading = false
                item = nil
            }
            do {
                guard let data = try await picked.loadTransferable(type: Data.self) else {
                    model.show("无法读取这张照片")
                    return
                }
                let isRAW = PhotoDecoder.isRAW(data: data)
                Haptics.tap()
                editor = EditorModel(source: .imported(data: data, isRAW: isRAW), recipe: model.recipe,
                                     outputLongEdge: model.settings.outputQuality.longEdge)
            } catch {
                model.show("导入失败：\(error.localizedDescription)")
            }
        }
    }
}
