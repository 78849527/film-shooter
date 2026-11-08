import SwiftUI
import UIKit

/// Image-first editor. All controls float above the full-size picture canvas,
/// so no film carousel or print sliders permanently consume image height.
struct DarkroomWorkspace: View {
    enum Drawer: String {
        case films, paper, adjustments

        var title: String {
            switch self {
            case .films: return "胶卷"
            case .paper: return "相纸"
            case .adjustments: return "调整"
            }
        }

        var symbol: String {
            switch self {
            case .films: return "camera.filters"
            case .paper: return "square.stack.3d.up"
            case .adjustments: return "slider.horizontal.3"
            }
        }
    }

    @ObservedObject var editor: EditorModel
    @ObservedObject var settings: AppSettings
    let sent: Bool
    let onCancel: () -> Void
    let onDevelop: () -> Void

    @State private var drawer: Drawer?
    @State private var chromeHidden = false
    @State private var resetZoomToken = 0

    private var rightHanded: Bool { settings.editorHandedness == .right }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height

            ZStack {
                Color.black

                DarkroomZoomCanvas(editor: editor, resetToken: $resetZoomToken) {
                    withAnimation(.easeOut(duration: 0.2)) {
                        if drawer != nil {
                            drawer = nil
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

                    if drawer == nil {
                        sideRail
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .zIndex(2)
                    }

                    bottomTools
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .zIndex(1)

                    if let drawer {
                        drawerOverlay(drawer, in: geometry.size)
                            .transition(.opacity)
                            .zIndex(3)
                    }
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
        HStack(spacing: 10) {
            Button(action: onCancel) {
                Text("取消")
                    .font(AppFont.ui(15, .medium))
                    .foregroundStyle(Theme.text)
                    .frame(minWidth: 48, minHeight: 42)
            }
            .accessibilityLabel("取消暗房编辑")

            Spacer(minLength: 8)

            Button {
                if isLandscape {
                    EditorOrientation.rotateToPortrait()
                } else {
                    EditorOrientation.rotateToLandscape()
                }
            } label: {
                Image(systemName: isLandscape ? "iphone" : "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(Theme.text)
                    .frame(width: 42, height: 42)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            .accessibilityLabel(isLandscape ? "切换竖屏查看" : "横屏查看")

            Button(action: onDevelop) {
                PrimaryCapsule(title: "冲洗", systemImage: "drop.fill",
                               isEnabled: editor.canDevelop, height: 34)
                    .frame(minHeight: 42)
            }
            .disabled(!editor.canDevelop || sent)
            .accessibilityLabel("按当前胶卷和相纸冲洗")
        }
        .buttonStyle(.pressable)
        .padding(.horizontal, 12)
        .padding(.top, 2)
        .background(LinearGradient(
            colors: [.black.opacity(0.72), .black.opacity(0)],
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
        .padding(.leading, rightHanded ? 10 : 60)
        .padding(.trailing, rightHanded ? 60 : 10)
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
        .background(.black.opacity(0.64), in: RoundedRectangle(cornerRadius: 9))
    }

    private var sideRail: some View {
        HStack(spacing: 0) {
            if rightHanded { Spacer(minLength: 0) }
            VStack(spacing: 9) {
                railButton(.films)
                railButton(.paper)
                railButton(.adjustments)
            }
            .padding(.horizontal, 5)
            .padding(.vertical, 10)
            .background(.black.opacity(0.66), in: RoundedRectangle(cornerRadius: 16))
            .padding(.horizontal, 5)
            if !rightHanded { Spacer(minLength: 0) }
        }
    }

    private func railButton(_ panel: Drawer) -> some View {
        Button {
            Haptics.selection()
            withAnimation(.easeOut(duration: 0.22)) { drawer = panel }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: panel.symbol)
                    .font(.system(size: 17))
                    .frame(height: 22)
                Text(panel.title)
                    .font(AppFont.ui(10, .medium))
            }
            .foregroundStyle(Theme.text)
            .frame(width: 45, height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.95))
        .accessibilityLabel("打开\(panel.title)面板")
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
        .background(.black.opacity(0.53))
    }

    private func drawerOverlay(_ chosen: Drawer, in available: CGSize) -> some View {
        let isLandscape = available.width > available.height
        let width = min(isLandscape ? 370 : 316, max(220, available.width - 64))
        return ZStack {
            Color.black.opacity(0.32)
                .contentShape(Rectangle())
                .onTapGesture {
                    withAnimation(.easeOut(duration: 0.2)) { drawer = nil }
                }
            HStack(spacing: 0) {
                if rightHanded { Spacer(minLength: 0) }
                panelContent(chosen)
                    .frame(width: width)
                    .frame(maxHeight: .infinity)
                    .background(Theme.surface.opacity(0.98))
                    .overlay(alignment: rightHanded ? .leading : .trailing) {
                        Rectangle()
                            .fill(Theme.hairlineStrong)
                            .frame(width: 1)
                    }
                if !rightHanded { Spacer(minLength: 0) }
            }
        }
        .ignoresSafeArea(edges: .bottom)
    }

    private func panelContent(_ chosen: Drawer) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(chosen.title)
                    .font(AppFont.ui(16, .semibold))
                    .foregroundStyle(Theme.text)
                Spacer(minLength: 8)
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { drawer = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .frame(width: 35, height: 35)
                        .background(Theme.surfaceHigher, in: Circle())
                }
                .accessibilityLabel("关闭\(chosen.title)面板")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)

            ScrollView {
                switch chosen {
                case .films:
                    VStack(alignment: .leading, spacing: 10) {
                        Text("选择胶卷 · 预览即时匹配当前选择")
                            .font(AppFont.ui(11))
                            .foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 12)
                        EditorFilmSection(editor: editor)
                    }
                    .padding(.top, 6)
                case .paper:
                    paperControls
                        .padding(12)
                case .adjustments:
                    RecipeControls(recipe: $editor.recipe, showsExposure: true)
                        .padding(12)
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    @ViewBuilder
    private var paperControls: some View {
        let film = editor.recipe.film
        if film.kind.usesPrintPaper {
            VStack(alignment: .leading, spacing: 18) {
                Text("已选相纸会在兼容胶卷间保留")
                    .font(AppFont.ui(11))
                    .foregroundStyle(Theme.secondary)
                PaperPicker(film: film, selection: Binding(
                    get: { editor.recipe.resolvedPaperID },
                    set: { newPaper in
                        var updated = editor.recipe
                        updated.paperID = newPaper
                        editor.recipe = updated
                    }
                ))
                .id(film.id)
                ControlSection(title: "放大机", spacing: 14) {
                    FilmSlider(title: "亮度", value: $editor.recipe.printBrightness, range: -2...2,
                               defaultValue: 0, leadingLabel: "暗", trailingLabel: "亮",
                               format: FilmSlider.ev)
                    FilmSlider(title: "冷暖", value: $editor.recipe.warmth, range: -1...1,
                               defaultValue: 0, leadingLabel: "冷", trailingLabel: "暖",
                               format: FilmSlider.signed)
                    FilmSlider(title: "品绿", value: $editor.recipe.tint, range: -1...1,
                               defaultValue: 0, leadingLabel: "绿", trailingLabel: "品",
                               format: FilmSlider.signed)
                }
            }
        } else {
            Text("反转片直接观看，不使用冲印相纸。切回负片时可继续使用原先的相纸选择。")
                .font(AppFont.ui(13))
                .foregroundStyle(Theme.secondary)
        }
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
