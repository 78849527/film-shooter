import SwiftUI
import UIKit

private struct GradeLaunch: Identifiable {
    let id = UUID()
    let photo: DevelopedPhoto
    let source: GradeInputSource
}

private struct PregradePayload {
    let gradedData: Data
    let originalData: Data
    let originalExtension: String
}

/// One print at a time, paging horizontally. Pinch / double-tap to zoom,
/// press and hold to see the original, swipe down (the zoom transition's own
/// gesture) or the chevron to go back.
struct PhotoDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    let startID: UUID
    @Binding var currentID: UUID?

    @State private var scrolledID: UUID?
    @State private var isZoomed = false
    @State private var chromeHidden = false
    @State private var confirmDelete = false
    @State private var editor: EditorModel?
    @State private var gradeLaunch: GradeLaunch?
    @State private var pendingPregrade: PregradePayload?
    @State private var isSaving = false

    init(startID: UUID, currentID: Binding<UUID?>) {
        self.startID = startID
        _currentID = currentID
        _scrolledID = State(initialValue: startID)
    }

    private var current: DevelopedPhoto? {
        let id = scrolledID ?? startID
        return model.library.photos.first { $0.id == id }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            pager
        }
        .overlay(alignment: .top) {
            if let photo = current, !chromeHidden {
                topBar(photo)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .overlay(alignment: .bottom) {
            if let photo = current, !chromeHidden {
                bottomBar(photo)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(Motion.standard, value: chromeHidden)
        .toolbar(.hidden, for: .navigationBar)
        .onAppear {
            ScreenshotMode.log("detail appeared for \(startID), \(model.library.photos.count) photos")
        }
        .compatibleOnChange(of: scrolledID) { _, new in
            currentID = new
            if isZoomed { isZoomed = false }
        }
        .confirmationDialog("删除这张照片？", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let photo = current { delete(photo) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("冲好的照片和保留的原图都会被删除，无法恢复。")
        }
        .fullScreenCover(item: $editor) { editor in
            EditorView(editor: editor)
                .environmentObject(model)
        }
        .fullScreenCover(item: $gradeLaunch, onDismiss: openPendingPregrade) { launch in
            IndependentGradeView(photo: launch.photo, source: launch.source, library: model.library) {
                gradedData, originalData, originalExtension in
                pendingPregrade = PregradePayload(gradedData: gradedData, originalData: originalData,
                                                  originalExtension: originalExtension)
            }
        }
    }

    // MARK: pager

    @ViewBuilder
    private var pager: some View {
        if #available(iOS 17.0, *) {
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(model.library.photos) { photo in
                        PhotoPage(photo: photo, isZoomed: $isZoomed) {
                            withAnimation(Motion.standard) { chromeHidden.toggle() }
                        }
                        .containerRelativeFrame([.horizontal, .vertical])
                        .id(photo.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $scrolledID)
            .scrollDisabled(isZoomed)
            .scrollIndicators(.hidden)
            .ignoresSafeArea()
            .onAppear { proxy.scrollTo(startID) }
        }
        } else {
            // iOS 16: use the native paged TabView; the iOS 17 scroll-position
            // and container-relative sizing APIs are not available here.
            TabView(selection: $scrolledID) {
                ForEach(model.library.photos) { photo in
                    GeometryReader { geo in
                        PhotoPage(photo: photo, isZoomed: $isZoomed) {
                            withAnimation(Motion.standard) { chromeHidden.toggle() }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                    }
                    .tag(Optional(photo.id))
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .ignoresSafeArea()
        }
    }

    // MARK: chrome

    private func topBar(_ photo: DevelopedPhoto) -> some View {
        let photos = model.library.photos
        let index = (photos.firstIndex { $0.id == photo.id } ?? 0) + 1
        return HStack(spacing: 12) {
            Button {
                dismiss()
            } label: {
                RoundIcon(systemName: "chevron.down", size: 36, iconSize: 14, fill: Color.black.opacity(0.45))
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("返回"))
            Spacer()
            Text("\(index) / \(photos.count)")
                .font(AppFont.mono(12, .medium))
                .foregroundStyle(Theme.text.opacity(0.85))
                .compatibleNumericText(Double(index))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.black.opacity(0.45)))
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .animation(Motion.snappy, value: index)
    }

    private func bottomBar(_ photo: DevelopedPhoto) -> some View {
        let film = photo.film
        let paperName = film.kind.usesPrintPaper
            ? (FilmCatalog.paper(photo.recipe.resolvedPaperID)?.name ?? "")
            : "反转片直出"
        let saved = photo.assetLocalID != nil
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(film.displayName)
                        .font(AppFont.ui(17, .semibold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    Text("No. \(String(format: "%02ld", photo.frameNumber))")
                        .lcdText(13)
                }
                Text("\(paperName) · \(photo.recipe.format.title) · \(photo.captureDate.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "zh_CN"))))")
                    .font(AppFont.ui(12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if photo.originalName != nil {
                    Text("按住照片查看原图")
                        .font(AppFont.ui(11))
                        .foregroundStyle(Theme.tertiary)
                }
            }
            .id(photo.id)
            .transition(.opacity)

            HStack(spacing: 0) {
                ShareLink(item: model.library.fileURL(for: photo)) {
                    actionLabel("square.and.arrow.up", "分享")
                }
                Button {
                    save(photo)
                } label: {
                    actionLabel(saved ? "checkmark.circle" : "arrow.down.to.line", saved ? "已存入相册" : "存入相册",
                                busy: isSaving)
                }
                Button {
                    editor = EditorModel(source: .existing(photo), recipe: photo.recipe,
                                         outputLongEdge: model.settings.outputQuality.longEdge)
                } label: {
                    actionLabel("camera.filters", "重新冲洗")
                }
                .disabled(photo.originalName == nil)
                .opacity(photo.originalName == nil ? 0.35 : 1)
                Menu {
                    if photo.originalName != nil {
                        Button("冲印前原图调色") { gradeLaunch = GradeLaunch(photo: photo, source: .original) }
                    }
                    Button("冲印后成片调色") { gradeLaunch = GradeLaunch(photo: photo, source: .print) }
                } label: {
                    actionLabel("slider.horizontal.3", "调色")
                }
                Button {
                    confirmDelete = true
                } label: {
                    actionLabel("trash", "删除")
                }
            }
            .buttonStyle(.pressable)
        }
        .padding(.horizontal, 20)
        .padding(.top, 36)
        .padding(.bottom, 8)
        .background(
            LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.75), Color.black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .bottom)
        )
        .animation(Motion.fade, value: photo.id)
    }

    private func actionLabel(_ symbol: String, _ title: String, busy: Bool = false) -> some View {
        VStack(spacing: 6) {
            ZStack {
                if busy {
                    ProgressView().controlSize(.small).tint(Theme.text)
                } else {
                    Image(systemName: symbol)
                        .font(.system(size: 18, weight: .regular))
                        .compatibleSymbolReplacement()
                }
            }
            .frame(height: 22)
            Text(title)
                .font(AppFont.ui(11, .medium))
        }
        .foregroundStyle(Theme.text)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    // MARK: actions

    private func save(_ photo: DevelopedPhoto) {
        guard !isSaving else { return }
        isSaving = true
        Haptics.tap()
        Task {
            do {
                try await model.library.saveToPhotos(photo)
                Haptics.success()
                model.show("已存入相册")
            } catch {
                model.show("保存失败：\(error.localizedDescription)")
            }
            isSaving = false
        }
    }

    private func delete(_ photo: DevelopedPhoto) {
        let photos = model.library.photos
        guard let i = photos.firstIndex(where: { $0.id == photo.id }) else { return }
        let next: UUID? = i + 1 < photos.count ? photos[i + 1].id : (i > 0 ? photos[i - 1].id : nil)
        Haptics.warning()
        guard let next else {
            model.library.delete(photo)
            dismiss()
            return
        }
        withAnimation(Motion.standard) {
            scrolledID = next
            model.library.delete(photo)
        }
    }

    private func openPendingPregrade() {
        guard let pending = pendingPregrade else { return }
        pendingPregrade = nil
        editor = EditorModel(
            source: .pregraded(data: pending.gradedData, originalData: pending.originalData,
                               originalExtension: pending.originalExtension,
                               captureDate: current?.captureDate),
            recipe: model.recipe, outputLongEdge: model.settings.outputQuality.longEdge
        )
    }
}

// MARK: - Page

/// One zoomable print: the cached thumbnail at once, cross-fading to the
/// screen-resolution decode; the original while held.
struct PhotoPage: View {
    @EnvironmentObject private var model: AppModel
    let photo: DevelopedPhoto
    @Binding var isZoomed: Bool
    let onTap: () -> Void

    @State private var full: UIImage?
    @State private var thumb: UIImage?
    @State private var original: UIImage?
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero
    @GestureState private var holding = false

    var body: some View {
        GeometryReader { geo in
            let fitted = LayoutMath.fit(aspect: CGFloat(photo.aspect), in: geo.size)
            ZStack {
                CrossfadeImage(image: full ?? thumb ?? model.library.cachedThumbnail(for: photo), duration: 0.3)
                    .frame(width: fitted.width, height: fitted.height)
                if holding, let original {
                    Image(uiImage: original)
                        .resizable()
                        .scaledToFit()
                        .frame(width: fitted.width, height: fitted.height)
                        .transition(.opacity)
                }
            }
            .scaleEffect(scale)
            .offset(offset)
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { toggleZoom(container: geo.size, fitted: fitted) }
            .onTapGesture { onTap() }
            .gesture(panGesture(container: geo.size, fitted: fitted), including: scale > 1.01 ? .all : .subviews)
            .simultaneousGesture(magnifyGesture(container: geo.size, fitted: fitted))
            .simultaneousGesture(holdGesture, including: photo.originalName != nil ? .all : .subviews)
            .overlay(alignment: .top) {
                if holding {
                    Text(original == nil ? "正在载入原图…" : "原图")
                        .font(AppFont.ui(13, .semibold))
                        .foregroundStyle(Theme.text)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(Color.black.opacity(0.6)))
                        .padding(.top, 64)
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }
            }
            .animation(.easeOut(duration: 0.15), value: holding)
            .animation(.easeOut(duration: 0.15), value: original == nil)
        }
        .task(id: photo.fileName) {
            if model.library.cachedThumbnail(for: photo) == nil {
                let small = await model.library.loadThumbnail(for: photo)
                guard !Task.isCancelled else { return }
                thumb = small
            }
            let image = await model.library.displayImage(for: photo, maxPixel: 2400)
            guard !Task.isCancelled else { return }
            full = image
        }
        .compatibleOnChange(of: holding) { _, isHolding in
            guard isHolding else { return }
            Haptics.softTap(0.5)
            if original == nil { loadOriginal() }
        }
        .onDisappear {
            full = nil
            original = nil
            resetZoom(animated: false)
        }
    }

    // MARK: gestures

    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .updating($holding) { value, state, _ in
                switch value {
                case .second(true, _): state = true
                default: break
                }
            }
    }

    private func magnifyGesture(container: CGSize, fitted: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                scale = LayoutMath.clamp(baseScale * value, 0.85, 5)
                setZoomed(scale > 1.01)
            }
            .onEnded { _ in
                if scale <= 1.02 {
                    resetZoom(animated: true)
                } else {
                    baseScale = scale
                    withAnimation(Motion.standard) { offset = clamped(offset, container: container, fitted: fitted) }
                    baseOffset = offset
                }
            }
    }

    private func panGesture(container: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture()
            .onChanged { g in
                offset = CGSize(width: baseOffset.width + g.translation.width,
                                height: baseOffset.height + g.translation.height)
            }
            .onEnded { g in
                let projected = CGSize(width: baseOffset.width + g.predictedEndTranslation.width,
                                       height: baseOffset.height + g.predictedEndTranslation.height)
                withAnimation(Motion.gentle) { offset = clamped(projected, container: container, fitted: fitted) }
                baseOffset = offset
            }
    }

    private func toggleZoom(container: CGSize, fitted: CGSize) {
        Haptics.softTap(0.5)
        if scale > 1.01 {
            resetZoom(animated: true)
        } else {
            withAnimation(Motion.standard) {
                scale = 2.5
                offset = .zero
            }
            baseScale = 2.5
            baseOffset = .zero
            setZoomed(true)
        }
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
        setZoomed(false)
    }

    private func setZoomed(_ zoomed: Bool) {
        if isZoomed != zoomed { isZoomed = zoomed }
    }

    private func clamped(_ proposed: CGSize, container: CGSize, fitted: CGSize) -> CGSize {
        let maxX = max(0, (fitted.width * scale - container.width) / 2)
        let maxY = max(0, (fitted.height * scale - container.height) / 2)
        return CGSize(width: LayoutMath.clamp(proposed.width, -maxX, maxX),
                      height: LayoutMath.clamp(proposed.height, -maxY, maxY))
    }

    private func loadOriginal() {
        Task {
            let image = await model.library.originalDisplayImage(for: photo, maxPixel: 2400)
            original = image
        }
    }
}
