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

    @State private var filmPanelOpen = false
    @State private var chromeHidden = false
    @State private var resetZoomToken = 0

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
                        } else {
                            chromeHidden.toggle()
                        }
                    }
                }
                .padding(landscape ? 3 : 1)

                if !chromeHidden {
                    topBar(isLandscape: landscape)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .zIndex(2)

                    filmLabel
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(.top, 54)
                        .zIndex(1)

                    if !filmPanelOpen {
                        sideRail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .zIndex(2)
                    }

                    bottomTools
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .zIndex(1)

                    if filmPanelOpen {
                        filmPanel(in: geometry.size)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
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
    }

    private func topBar(isLandscape: Bool) -> some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                Label("返回", systemImage: "chevron.left")
                    .font(AppFont.ui(14, .medium))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 58, minHeight: 42)
            }
            .accessibilityLabel("返回并取消暗房编辑")

            Spacer()

            Button {
                if isLandscape {
                    EditorOrientation.rotateToPortrait()
                } else {
                    EditorOrientation.rotateToLandscape()
                }
            } label: {
                Image(systemName: isLandscape ? "iphone" : "rotate.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .accessibilityLabel(isLandscape ? "切换竖屏查看" : "横屏查看")
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .background(LinearGradient(
            colors: [.black.opacity(0.65), .black.opacity(0)],
            startPoint: .top, endPoint: .bottom
        ))
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

    private var sideRail: some View {
        HStack(spacing: 0) {
            if rightHanded { Spacer(minLength: 0) }
            Button {
                Haptics.selection()
                withAnimation(.easeOut(duration: 0.20)) { filmPanelOpen = true }
            } label: {
                VStack(spacing: 5) {
                    Image(systemName: "camera.filters")
                        .font(.system(size: 19))
                    Text("胶片")
                        .font(AppFont.ui(11, .semibold))
                }
                .foregroundStyle(Theme.text)
                .frame(width: 52, height: 68)
                .background(.black.opacity(0.68), in: RoundedRectangle(cornerRadius: 13))
            }
            .buttonStyle(.pressable(scale: 0.94))
            .accessibilityLabel("打开胶片和调整面板")
            .padding(.horizontal, 5)
            if !rightHanded { Spacer(minLength: 0) }
        }
        .padding(.bottom, 48)
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
        // Lower half only, either aligned bottom-left or bottom-right.
        // Portrait width leaves part of the image visible behind the panel;
        // landscape uses less than half the horizontal screen width.
        let panelWidth = landscape
            ? min(390, available.width * 0.48)
            : min(350, available.width * 0.84)
        let panelHeight = available.height * 0.50

        return ZStack(alignment: rightHanded ? .bottomTrailing : .bottomLeading) {
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { filmPanelOpen = false }
                }

            VStack(spacing: 0) {
                panelHeader

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        EditorFilmSection(editor: editor)
                            .padding(.horizontal, 5)
                        RecipeControls(recipe: $editor.recipe, showsExposure: true)
                            .padding(.horizontal, 8)
                        Text("相纸选择会在兼容胶卷间保留")
                            .font(AppFont.ui(11))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 10)
                            .padding(.bottom, 8)
                    }
                    .padding(.top, 4)
                }
                .scrollIndicators(.hidden)

                panelActions
            }
            .frame(width: panelWidth, height: panelHeight)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 17))
            .background(Theme.surface.opacity(0.60), in: RoundedRectangle(cornerRadius: 17))
            .overlay(RoundedRectangle(cornerRadius: 17)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 17))
            .padding(.horizontal, 7)
            .padding(.bottom, 7)
        }
        .frame(width: available.width, height: available.height)
    }

    private var panelHeader: some View {
        HStack(spacing: 10) {
            Label("胶片", systemImage: "camera.filters")
                .font(AppFont.ui(16, .semibold))
                .foregroundStyle(Theme.text)
            Spacer()
            Button {
                withAnimation(.easeOut(duration: 0.18)) { filmPanelOpen = false }
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

    private var panelActions: some View {
        HStack(spacing: 7) {
            Button(action: onBack) {
                Label("返回", systemImage: "arrow.uturn.backward")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .accessibilityLabel("返回并取消编辑")
            .background(.white.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))

            Button(action: onDevelop) {
                Label("冲洗", systemImage: "drop.fill")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .disabled(!editor.canDevelop || sent)
            .background(editor.canDevelop ? Theme.accent.opacity(0.35) :
                        .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))

            Button(action: onShare) {
                Label("分享", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity, minHeight: 40)
            }
            .accessibilityLabel("高清冲洗完成后分享照片")
            .disabled(!editor.canDevelop || sent)
            .background(editor.canDevelop ? Theme.accent.opacity(0.45) :
                        .white.opacity(0.08), in: RoundedRectangle(cornerRadius: 9))
        }
        .font(AppFont.ui(12, .semibold))
        .lineLimit(1)
        .minimumScaleFactor(0.7)
        .foregroundStyle(Theme.text)
        .buttonStyle(.pressable)
        .padding(.horizontal, 8)
        .padding(.vertical, 9)
        .background(.black.opacity(0.30))
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
