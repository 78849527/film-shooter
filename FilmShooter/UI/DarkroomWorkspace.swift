import SwiftUI
import UIKit

/// Image-first main-app darkroom. A SINGLE half-height translucent film panel
/// contains stock, paper and all print controls. It docks to the preferred
/// hand's lower side and does not reserve any permanent image space.
struct DarkroomWorkspace: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var settings: AppSettings
    let sent: Bool
    let isSharing: Bool
    let onBack: () -> Void
    let onDevelop: () -> Void
    let onShare: () -> Void
    let onSettings: () -> Void

    @State private var filmPanelOpen = false
    @State private var chromeHidden = false
    @State private var resetZoomToken = 0
    /// Long press first unlocks floating mode. A separate pan then moves it,
    /// so the panel never relocates while its activation touch is being tracked.
    @State private var panelFloating = false
    @State private var floatingOffset: CGSize = .zero
    @State private var floatingDragStart: CGSize = .zero

    private var rightHanded: Bool { settings.editorHandedness == .right }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                Color.black

                DarkroomZoomCanvas(editor: editor, resetToken: $resetZoomToken) {
                    withAnimation(.easeOut(duration: 0.18)) {
                        if filmPanelOpen {
                            filmPanelOpen = false
                            resetPanelPosition()
                        } else {
                            chromeHidden.toggle()
                        }
                    }
                }
                .padding(landscape ? 3 : 1)

                if !chromeHidden {
                    filmLabel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 54)
                        .zIndex(1)

                    if !filmPanelOpen {
                        sideRail(isLandscape: landscape)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .zIndex(2)
                    }

                    bottomTools
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .zIndex(1)

                    if filmPanelOpen {
                        filmPanel(in: geometry.size)
                            .transition(.move(edge: rightHanded ? .trailing : .leading).combined(with: .opacity))
                            .zIndex(3)
                    }
                }

                if isSharing {
                    Color.black.opacity(0.32)
                        .ignoresSafeArea()
                        .allowsHitTesting(true)
                        .zIndex(4)
                    VStack(spacing: 12) {
                        ProgressView()
                            .tint(Theme.accent)
                        Text("正在冲洗成品，完成后打开分享")
                            .font(AppFont.ui(13, .medium))
                            .foregroundStyle(Theme.text)
                    }
                    .padding(22)
                    .background(.black.opacity(0.82), in: RoundedRectangle(cornerRadius: 15))
                    .zIndex(5)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
            .background(Color.black.ignoresSafeArea())
        }
        .preferredColorScheme(.dark)
        .disabled(sent)
        .compatibleOnChange(of: rightHanded) { _, _ in resetPanelPosition() }
    }

    private var filmLabel: some View {
        HStack(spacing: 6) {
            if rightHanded {
                labelContent
                Spacer(minLength: 0)
            } else {
                Spacer(minLength: 0)
                labelContent
            }
        }
        .padding(.leading, rightHanded ? 10 : 65)
        .padding(.trailing, rightHanded ? 65 : 10)
        .allowsHitTesting(false)
    }

    private var labelContent: some View {
        VStack(alignment: rightHanded ? .leading : .trailing, spacing: 2) {
            Text(editor.recipe.film.displayName)
                .font(AppFont.ui(13, .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            if editor.previewMatchesSelection {
                Text(editor.recipe.film.kind.chipTitle)
                    .font(AppFont.ui(10))
                    .foregroundStyle(.white.opacity(0.68))
            } else {
                Text("正在显影")
                    .font(AppFont.ui(10))
                    .foregroundStyle(Theme.accent)
            }
        }
        .foregroundStyle(Theme.text)
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(.black.opacity(0.62), in: RoundedRectangle(cornerRadius: 9))
    }

    /// Primary controls stay accessible without opening the film panel.
    /// Return cancels; Share initiates the real full-resolution development.
    private func sideRail(isLandscape: Bool) -> some View {
        HStack(spacing: 0) {
            if rightHanded { Spacer(minLength: 0) }
            VStack(spacing: 8) {
                railButton(title: "胶片", symbol: "camera.filters", action: {
                    Haptics.selection()
                    resetPanelPosition()
                    withAnimation(.easeOut(duration: 0.24)) { filmPanelOpen = true }
                })
                railButton(title: "分享", symbol: "square.and.arrow.up", enabled: editor.canDevelop, action: onShare)
                railButton(title: "返回", symbol: "chevron.backward", action: onBack)
                railButton(title: "设置", symbol: "gearshape", action: onSettings)
                railButton(title: isLandscape ? "竖屏" : "横屏",
                           symbol: isLandscape ? "iphone" : "rotate.right", action: {
                    if isLandscape {
                        EditorOrientation.rotateToPortrait()
                    } else {
                        EditorOrientation.rotateToLandscape()
                    }
                })
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 7)
            .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 5)
            if !rightHanded { Spacer(minLength: 0) }
        }
    }

    private func railButton(title: String, symbol: String, enabled: Bool = true,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 17))
                    .frame(height: 22)
                Text(title)
                    .font(AppFont.ui(10, .semibold))
            }
            .foregroundStyle(Theme.text.opacity(enabled ? 1 : 0.45))
            .frame(width: 46, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.95))
        .disabled(!enabled || sent)
        .accessibilityLabel(title == "分享" ? "高清冲印后分享照片" : title)
    }

    private var bottomTools: some View {
        HStack(spacing: 8) {
            Text("单击隐藏 · 双击放大 · 长按原图")
                .font(AppFont.ui(10))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .foregroundStyle(.white.opacity(0.8))
            Spacer(minLength: 5)
            Button {
                resetZoomToken &+= 1
            } label: {
                Label("适合屏幕", systemImage: "arrow.down.right.and.arrow.up.left")
                    .font(AppFont.ui(11, .medium))
                    .foregroundStyle(Theme.text)
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.black.opacity(0.5))
    }

    private func filmPanel(in available: CGSize) -> some View {
        let landscape = available.width > available.height
        // Landscape gets a tall panel (86% of the usable height); portrait
        // keeps the original half-height panel for maximum photo visibility.
        let panelWidth = landscape
            ? min(400, available.width * 0.46)
            : min(350, available.width * 0.84)
        let panelHeight = available.height * (landscape ? 0.86 : 0.50) * (2.0 / 3.0)

        return ZStack(alignment: rightHanded ? .bottomTrailing : .bottomLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.20)) { filmPanelOpen = false }
                    resetPanelPosition()
                }

            VStack(spacing: 0) {
                panelHeader(in: available, panelWidth: panelWidth, panelHeight: panelHeight)

                ScrollView {
                    VStack(alignment: .leading, spacing: 9) {
                        EditorFilmSection(editor: editor)
                            .padding(.horizontal, 3)
                        RecipeControls(recipe: $editor.recipe, showsExposure: true,
                                       showsPaper: false, frostedSections: true, compact: true)
                            .padding(.horizontal, 6)
                    }
                    .padding(.top, 2)
                }
                .scrollIndicators(.hidden)

            }
            .frame(width: panelWidth, height: panelHeight)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
            .background(Theme.surface.opacity(0.48), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17)
                .strokeBorder(.white.opacity(panelFloating ? 0.32 : 0.15),
                              lineWidth: panelFloating ? 1.3 : 1))
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .offset(floatingOffset)
            .padding(.horizontal, 7)
            .padding(.bottom, 7)
        }
        .frame(width: available.width, height: available.height)
    }

    private func resetPanelPosition() {
        panelFloating = false
        floatingOffset = .zero
        floatingDragStart = .zero
    }

    /// Unlock movement without repositioning the panel under the activation
    /// touch. The next pan gesture performs the actual move.
    private func activateFloatingPanel() {
        guard !panelFloating else { return }
        floatingDragStart = floatingOffset
        panelFloating = true
        Haptics.selection()
    }

    private func movePanel(_ translation: CGSize, in available: CGSize,
                           panelWidth: CGFloat, panelHeight: CGFloat) {
        guard panelFloating else { return }
        let target = CGSize(width: floatingDragStart.width + translation.width,
                            height: floatingDragStart.height + translation.height)
        floatingOffset = constrainedPanelOffset(target, in: available,
                                                panelWidth: panelWidth,
                                                panelHeight: panelHeight)
    }

    private func constrainedPanelOffset(_ proposed: CGSize, in available: CGSize,
                                        panelWidth: CGFloat, panelHeight: CGFloat) -> CGSize {
        let maxHorizontalTravel = max(0, available.width - panelWidth - 14)
        let xMin: CGFloat = rightHanded ? -maxHorizontalTravel : 0
        let xMax: CGFloat = rightHanded ? 0 : maxHorizontalTravel
        let yMin = -max(0, available.height - panelHeight - 14)
        return CGSize(width: min(xMax, max(xMin, proposed.width)),
                      height: min(0, max(yMin, proposed.height)))
    }

    private func panelHeader(in available: CGSize, panelWidth: CGFloat,
                             panelHeight: CGFloat) -> some View {
        HStack(spacing: 7) {
            panelActions

            VStack(alignment: .leading, spacing: 2) {
                Label("胶片", systemImage: "camera.filters")
                    .font(AppFont.ui(12, .semibold))
                Text(panelFloating ? "悬浮中" : "长按拖动")
                    .font(AppFont.ui(9))
                    .foregroundStyle(Theme.secondary)
            }
            .foregroundStyle(Theme.text)
            .frame(minWidth: 70, minHeight: 33, alignment: .leading)
            .overlay {
                DarkroomPanelDragHandle(
                    isFloating: panelFloating,
                    onActivate: activateFloatingPanel,
                    onMove: { delta in
                        movePanel(delta, in: available, panelWidth: panelWidth,
                                  panelHeight: panelHeight)
                    },
                    onEnd: { floatingDragStart = floatingOffset }
                )
            }
            Spacer(minLength: 2)
            Text(editor.recipe.film.displayName)
                .font(AppFont.ui(10, .medium))
                .foregroundStyle(Theme.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 86, alignment: .trailing)
            Button {
                withAnimation(.easeOut(duration: 0.18)) { filmPanelOpen = false }
                resetPanelPosition()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .frame(width: 32, height: 32)
                    .background(.black.opacity(0.28), in: Circle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel("收起胶片面板")
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
    }

    /// Inner panel has only the print action; return and share stay in the
    /// primary side rail so they are available without opening the panel.
    private var panelActions: some View {
        Button(action: onDevelop) {
            Label("冲印", systemImage: "drop.fill")
                .font(AppFont.ui(11, .semibold))
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 9)
                .frame(height: 32)
                .background(editor.canDevelop ? Theme.accent.opacity(0.36) :
                            .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        }
        .disabled(!editor.canDevelop || sent)
        .buttonStyle(.pressable)
    }

}

/// Pinch, pan, double tap and hold-to-compare share a single image transform.
/// Keeping the original and processed print in the same transformed ZStack
/// prevents the original comparison from jumping to a different crop.
struct DarkroomZoomCanvas: View {
    @ObservedObject var editor: EditorModel
    @Binding var resetToken: Int
    let onTap: () -> Void

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @GestureState private var holding = false

    private var displayImage: UIImage? {
        editor.previewMatchesSelection ? editor.preview : editor.original
    }

    var body: some View {
        GeometryReader { geometry in
            let image = displayImage
            let aspect = image.map { $0.size.width / max(1, $0.size.height) } ?? (2.0 / 3.0)
            let fitted = LayoutMath.fit(aspect: aspect, in: geometry.size)

            ZStack {
                Color.black

                if editor.isLoading {
                    DevelopingLoader(original: editor.original)
                        .frame(width: fitted.width, height: fitted.height)
                } else if let image {
                    ZStack {
                        Image(uiImage: image)
                            .resizable()
                            .interpolation(.high)
                            .scaledToFit()
                            .frame(width: fitted.width, height: fitted.height)

                        if holding, let original = editor.original {
                            Image(uiImage: original)
                                .resizable()
                                .interpolation(.high)
                                .scaledToFit()
                                .frame(width: fitted.width, height: fitted.height)
                                .transition(.opacity)
                        }
                    }
                    .scaleEffect(scale)
                    .offset(offset)
                } else if let error = editor.error {
                    VStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle")
                        Text(error)
                            .font(AppFont.ui(13))
                            .multilineTextAlignment(.center)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(20)
                } else {
                    ProgressView().tint(Theme.accent)
                }

                if !editor.isLoading && !editor.previewMatchesSelection && editor.error == nil {
                    VStack(spacing: 7) {
                        ProgressView().tint(Theme.accent)
                        Text("正在显影：\(editor.recipe.film.name)")
                            .font(AppFont.ui(12, .medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .background(.black.opacity(0.8), in: Capsule())
                    .allowsHitTesting(false)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                toggleZoom(container: geometry.size, fitted: fitted, image: image)
            }
            .onTapGesture { onTap() }
            .gesture(panGesture(container: geometry.size, fitted: fitted),
                     including: scale > 1.01 ? .all : .subviews)
            .simultaneousGesture(magnifyGesture(container: geometry.size, fitted: fitted))
            .simultaneousGesture(holdGesture, including: editor.original != nil ? .all : .subviews)
            .overlay(alignment: .top) {
                if holding {
                    Text("原图")
                        .font(AppFont.ui(12, .medium))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.7), in: Capsule())
                        .padding(.top, 102)
                        .allowsHitTesting(false)
                }
            }
        }
        .compatibleOnChange(of: resetToken) { _, _ in resetZoom(animated: true) }
    }

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.28)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($holding) { value, state, _ in
                if case .second(true, _) = value { state = true }
            }
    }

    private func magnifyGesture(container: CGSize, fitted: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = LayoutMath.clamp(baseScale * value, 1, 6)
            }
            .onEnded { _ in
                if scale <= 1.02 {
                    resetZoom(animated: true)
                } else {
                    baseScale = scale
                    withAnimation(Motion.standard) {
                        offset = clamped(offset, container: container, fitted: fitted)
                    }
                    baseOffset = offset
                }
            }
    }

    private func panGesture(container: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { gesture in
                guard scale > 1.01 else { return }
                offset = CGSize(width: baseOffset.width + gesture.translation.width,
                                height: baseOffset.height + gesture.translation.height)
            }
            .onEnded { gesture in
                guard scale > 1.01 else { return }
                let projected = CGSize(width: baseOffset.width + gesture.predictedEndTranslation.width,
                                       height: baseOffset.height + gesture.predictedEndTranslation.height)
                withAnimation(Motion.gentle) {
                    offset = clamped(projected, container: container, fitted: fitted)
                }
                baseOffset = offset
            }
    }

    private func toggleZoom(container: CGSize, fitted: CGSize, image: UIImage?) {
        Haptics.softTap(0.4)
        guard scale <= 1.01 else {
            resetZoom(animated: true)
            return
        }
        // 1 image pixel per display pixel where the 1600px preview supports it;
        // otherwise 2x is an inspection zoom, not invented image detail.
        let native = CGFloat(image?.cgImage?.width ?? 1600) /
                     max(1, fitted.width * UIScreen.main.scale)
        let target = min(6, max(2, native))
        withAnimation(Motion.standard) {
            scale = target
            offset = .zero
        }
        baseScale = target
        baseOffset = .zero
    }

    private func resetZoom(animated: Bool) {
        if animated {
            withAnimation(Motion.standard) {
                scale = 1
                offset = .zero
            }
        } else {
            scale = 1
            offset = .zero
        }
        baseScale = 1
        baseOffset = .zero
    }

    private func clamped(_ proposed: CGSize, container: CGSize, fitted: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(width: LayoutMath.clamp(proposed.width, -maxX, maxX),
                      height: LayoutMath.clamp(proposed.height, -maxY, maxY))
    }
}


/// iOS 16 safe two-step floating interaction: long press unlocks floating
/// mode; a fresh pan gesture moves the panel. The activation recognizer never
/// tracks a view that is moving underneath the finger.
private struct DarkroomPanelDragHandle: UIViewRepresentable {
    let isFloating: Bool
    let onActivate: () -> Void
    let onMove: (CGSize) -> Void
    let onEnd: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onActivate: onActivate, onMove: onMove, onEnd: onEnd)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        context.coordinator.configure(view, isFloating: isFloating)
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.onActivate = onActivate
        context.coordinator.onMove = onMove
        context.coordinator.onEnd = onEnd
        context.coordinator.configure(view, isFloating: isFloating)
    }

    final class Coordinator: NSObject {
        var onActivate: () -> Void
        var onMove: (CGSize) -> Void
        var onEnd: () -> Void
        private weak var view: UIView?
        private var longPress: UILongPressGestureRecognizer?
        private var pan: UIPanGestureRecognizer?
        private var configuredForFloating: Bool?

        init(onActivate: @escaping () -> Void,
             onMove: @escaping (CGSize) -> Void,
             onEnd: @escaping () -> Void) {
            self.onActivate = onActivate
            self.onMove = onMove
            self.onEnd = onEnd
        }

        func configure(_ view: UIView, isFloating: Bool) {
            self.view = view
            guard configuredForFloating != isFloating else { return }
            if let longPress { view.removeGestureRecognizer(longPress) }
            if let pan { view.removeGestureRecognizer(pan) }
            longPress = nil
            pan = nil
            configuredForFloating = isFloating

            if isFloating {
                let gesture = UIPanGestureRecognizer(
                    target: self, action: #selector(handlePan(_:))
                )
                gesture.minimumNumberOfTouches = 1
                gesture.maximumNumberOfTouches = 1
                gesture.cancelsTouchesInView = false
                view.addGestureRecognizer(gesture)
                pan = gesture
            } else {
                let gesture = UILongPressGestureRecognizer(
                    target: self, action: #selector(handleLongPress(_:))
                )
                gesture.minimumPressDuration = 0.42
                gesture.allowableMovement = 18
                gesture.cancelsTouchesInView = false
                view.addGestureRecognizer(gesture)
                longPress = gesture
            }
        }

        @objc private func handleLongPress(_ recognizer: UILongPressGestureRecognizer) {
            guard recognizer.state == .began else { return }
            onActivate()
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            switch recognizer.state {
            case .began, .changed:
                let delta = recognizer.translation(in: recognizer.view?.window)
                onMove(CGSize(width: delta.x, height: delta.y))
            case .ended, .cancelled, .failed:
                onEnd()
            default:
                break
            }
        }
    }
}
