import SwiftUI
import UIKit

/// Simple after-print grading screen: light/color controls plus a draggable
/// master and per-channel curve. It only edits the already developed print.
struct PostGradeView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: DevelopedPhoto
    let library: PhotoLibrary

    @State private var recipe: PostGradeRecipe
    @State private var preview: UIImage?
    @State private var isLoading = true
    @State private var isSaving = false
    @State private var showingOriginal = false
    @State private var selectedChannel = "RGB"
    @State private var error: String?
    @State private var previewToken = 0

    init(photo: DevelopedPhoto, library: PhotoLibrary) {
        self.photo = photo
        self.library = library
        _recipe = State(initialValue: photo.postGrade ?? PostGradeRecipe())
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            previewPane
                .frame(maxHeight: .infinity)
                .padding(.horizontal, 18)
                .padding(.vertical, 12)
            controls
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await loadPreview() }
        .onChange(of: recipe) { _ in schedulePreview() }
        .alert("调色失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
    }

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }
                .font(AppFont.ui(15)).foregroundStyle(Theme.secondary)
            Spacer()
            VStack(spacing: 2) {
                Text("调色").font(AppFont.ui(17, .semibold)).foregroundStyle(Theme.text)
                Text("冲印完成后的后期调整").font(AppFont.ui(10)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Button(action: save) {
                if isSaving { ProgressView().tint(Theme.text) }
                else { Text("完成").font(AppFont.ui(15, .semibold)).foregroundStyle(Theme.accent) }
            }
            .frame(minWidth: 48, minHeight: 44)
            .disabled(isSaving || isLoading)
        }
        .padding(.horizontal, 18)
        .frame(height: 52)
    }

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8).fill(Color.black)
            if isLoading {
                ProgressView().tint(Theme.accent)
            } else if let preview {
                Image(uiImage: preview).resizable().scaledToFit()
                    .padding(8)
                    .overlay(alignment: .topLeading) {
                        Text(showingOriginal ? "冲印原图" : "调色预览")
                            .font(AppFont.ui(11, .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(12)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in showingOriginal = true }
                        .onEnded { _ in showingOriginal = false })
                    .overlay {
                        if showingOriginal, let base = originalPreview {
                            Image(uiImage: base).resizable().scaledToFit().padding(8)
                        }
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @State private var originalPreview: UIImage?

    private var controls: some View {
        ScrollView {
            VStack(spacing: 18) {
                sectionTitle("光影与色彩")
                slider("曝光", keyPath: \.exposure, range: -5...5, step: 0.05, suffix: " EV")
                slider("对比度", keyPath: \.contrast, range: -100...100)
                slider("高光", keyPath: \.highlights, range: -100...100)
                slider("阴影", keyPath: \.shadows, range: -100...100)
                slider("饱和度", keyPath: \.saturation, range: -100...100)
                slider("色温", keyPath: \.temperature, range: -100...100)
                slider("色调", keyPath: \.tint, range: -100...100)

                sectionTitle("曲线")
                Picker("曲线通道", selection: $selectedChannel) {
                    ForEach(["RGB", "R", "G", "B"], id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
                CurveEditor(points: curveBinding)
                    .frame(height: 190)
                Button("重置当前曲线") { curveBinding.wrappedValue = PostGradeRecipe.identity }
                    .font(AppFont.ui(13)).foregroundStyle(Theme.secondary)
                Button("重置全部调色") { recipe = PostGradeRecipe() }
                    .font(AppFont.ui(13)).foregroundStyle(Theme.danger)
                    .padding(.top, 4)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            .padding(.bottom, 30)
        }
        .frame(maxHeight: 330)
        .background(Theme.surface.opacity(0.65))
    }

    private var curveBinding: Binding<[GradePoint]> {
        switch selectedChannel {
        case "R": return $recipe.redCurve
        case "G": return $recipe.greenCurve
        case "B": return $recipe.blueCurve
        default: return $recipe.masterCurve
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        HStack {
            Text(title).font(AppFont.ui(14, .semibold)).foregroundStyle(Theme.text)
            Spacer()
        }
    }

    private func slider(_ title: String, keyPath: WritableKeyPath<PostGradeRecipe, Double>,
                        range: ClosedRange<Double>, step: Double = 1, suffix: String = "") -> some View {
        let binding = Binding(get: { recipe[keyPath: keyPath] }, set: { recipe[keyPath: keyPath] = $0 })
        return VStack(spacing: 5) {
            HStack {
                Text(title).font(AppFont.ui(12)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(step < 1
                     ? String(format: "%.2f%@", binding.wrappedValue, suffix)
                     : String(format: "%.0f%@", binding.wrappedValue, suffix))
                    .font(AppFont.mono(11)).foregroundStyle(Theme.text)
            }
            Slider(value: binding, in: range, step: step).tint(Theme.accent)
        }
    }

    private func loadPreview() async {
        preview = await library.displayImage(for: photo, maxPixel: 1800)
        if let baseName = photo.gradeBaseName {
            let url = library.url(baseName)
            originalPreview = await Task.detached(priority: .userInitiated) {
                PhotoDecoder.displayImage(at: url, maxPixel: 1800)
            }.value
        } else {
            originalPreview = preview
        }
        isLoading = false
        await refreshPreview()
    }

    private func refreshPreview() async {
        let token = previewToken
        let rendered: UIImage?
        guard let baseName = photo.gradeBaseName else {
            let url = library.fileURL(for: photo)
            rendered = try? await Task.detached(priority: .userInitiated) {
                try PostGradeRenderer.render(inputURL: url, recipe: recipe, maxLongEdge: 1400)
            }.value
            guard token == previewToken else { return }
            preview = rendered
            return
        }
        let url = library.url(baseName)
        rendered = try? await Task.detached(priority: .userInitiated) {
            try PostGradeRenderer.render(inputURL: url, recipe: recipe, maxLongEdge: 1400)
        }.value
        guard token == previewToken else { return }
        preview = rendered
    }

    private func schedulePreview() {
        previewToken += 1
        let token = previewToken
        Task {
            try? await Task.sleep(nanoseconds: 150_000_000)
            guard token == previewToken else { return }
            await refreshPreview()
        }
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await library.applyPostGrade(recipe, to: photo)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct CurveEditor: View {
    @Binding var points: [GradePoint]
    @State private var activeIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Theme.surface)
                Path { path in
                    for index in 1...3 {
                        let value = CGFloat(index) / 4
                        path.move(to: CGPoint(x: size.width * value, y: 0))
                        path.addLine(to: CGPoint(x: size.width * value, y: size.height))
                        path.move(to: CGPoint(x: 0, y: size.height * value))
                        path.addLine(to: CGPoint(x: size.width, y: size.height * value))
                    }
                }.stroke(Theme.hairline, lineWidth: 1)
                Path { path in
                    guard let first = points.first else { return }
                    path.move(to: CGPoint(x: CGFloat(first.x) * size.width, y: CGFloat(1 - first.y) * size.height))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: CGFloat(point.x) * size.width, y: CGFloat(1 - point.y) * size.height))
                    }
                }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { item in
                    Circle().fill(Theme.text).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Theme.accent, lineWidth: activeIndex == item.offset ? 2 : 1))
                        .position(x: CGFloat(item.element.x) * size.width, y: CGFloat(1 - item.element.y) * size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if activeIndex == nil { activeIndex = nearest(value.location, size: size) }
                    guard let index = activeIndex, index > 0, index < points.count - 1 else { return }
                    let x = min(1, max(0, value.location.x / size.width))
                    let y = min(1, max(0, 1 - value.location.y / size.height))
                    let lower = CGFloat(points[index - 1].x) + 0.03
                    let upper = CGFloat(points[index + 1].x) - 0.03
                    points[index] = GradePoint(x: Double(min(upper, max(lower, x))), y: Double(y))
                }
                .onEnded { _ in activeIndex = nil })
        }
    }

    private func nearest(_ location: CGPoint, size: CGSize) -> Int? {
        var best: (index: Int, distance: CGFloat)?
        for (index, point) in points.enumerated() {
            let dx = CGFloat(point.x) * size.width - location.x
            let dy = CGFloat(1 - point.y) * size.height - location.y
            let distance = hypot(dx, dy)
            if distance < 36 && (best == nil || distance < best!.distance) { best = (index, distance) }
        }
        return best?.index
    }
}
