import SwiftUI
import UniformTypeIdentifiers

enum GradeInputSource: Equatable {
    case original
    case print
}

/// Independent grading path. It can grade a kept camera/import original and
/// return a raster to the existing darkroom, or grade a completed print.
struct IndependentGradeView: View {
    @Environment(\.dismiss) private var dismiss
    let photo: DevelopedPhoto
    let source: GradeInputSource
    let library: PhotoLibrary
    let onSendToDarkroom: (Data, Data, String) -> Void

    @State private var recipe: GradeRecipe
    @State private var preview: UIImage?
    @State private var before: UIImage?
    @State private var isLoading = true
    @State private var isWorking = false
    @State private var comparing = false
    @State private var panel = "预设"
    @State private var selectedChannel = "总RGB"
    @State private var selectedHSL = 0
    @State private var selectedZone = "阴影"
    @State private var presetName = ""
    @State private var showSavePreset = false
    @State private var showLUTImporter = false
    @State private var error: String?
    @State private var previewToken = 0

    private let panels = ["预设", "光影", "曲线", "色彩", "HSL", "分级", "细节", "光学", "LUT"]
    private let hslNames = GradeRecipeConstants.hslBandLabels
    private let zoneNames = GradeRecipeConstants.zoneLabels

    init(photo: DevelopedPhoto, source: GradeInputSource, library: PhotoLibrary,
         onSendToDarkroom: @escaping (Data, Data, String) -> Void) {
        self.photo = photo
        self.source = source
        self.library = library
        self.onSendToDarkroom = onSendToDarkroom
        _recipe = State(initialValue: Self.initialRecipe(for: photo))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            previewPane.frame(maxHeight: .infinity).padding(.horizontal, 14).padding(.vertical, 10)
            panelPicker
            panelContent.frame(maxHeight: 330)
        }
        .background(Theme.background.ignoresSafeArea())
        .task {
            if !recipe.lut.path.isEmpty { recipe.lut.path = resolveLUTPath(recipe.lut.path) }
            await loadPreview()
        }
        .onChange(of: recipe) { _ in schedulePreview() }
        .fileImporter(isPresented: $showLUTImporter, allowedContentTypes: [UTType(filenameExtension: "cube") ?? .data],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first,
                      let entry = try? GradePresetStore.shared.importLUT(from: url) else {
                    error = "LUT 导入失败，仅支持有效的 .cube 文件"; return
                }
                recipe.lut.path = entry.path
                if recipe.lut.strength == 0 { recipe.lut.strength = 100 }
            case .failure:
                error = "LUT 导入失败"
            }
        }
        .alert("调色失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好", role: .cancel) { error = nil }
        } message: { Text(error ?? "") }
        .alert("保存调色预设", isPresented: $showSavePreset) {
            TextField("预设名称", text: $presetName)
            Button("取消", role: .cancel) { }
            Button("保存") {
                _ = GradePresetStore.shared.save(name: presetName, recipe: recipe)
                presetName = ""
            }
        } message: { Text("保存当前调色参数，之后可重复套用。") }
    }

    private var header: some View {
        HStack {
            Button("取消") { dismiss() }.foregroundStyle(Theme.secondary)
            Spacer()
            VStack(spacing: 2) {
                Text("调色台").font(AppFont.ui(17, .semibold)).foregroundStyle(Theme.text)
                Text(source == .original ? "原图调色 · 可继续冲印" : "冲印成片调色")
                    .font(AppFont.ui(10)).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            Button(action: finish) {
                if isWorking { ProgressView().tint(Theme.accent) }
                else { Text(source == .original ? "继续冲印" : "完成")
                    .font(AppFont.ui(14, .semibold)).foregroundStyle(Theme.accent) }
            }
            .frame(minWidth: 64, minHeight: 44)
            .disabled(isWorking || isLoading)
        }
        .padding(.horizontal, 16).frame(height: 52)
    }

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9).fill(Color.black)
            if isLoading { ProgressView().tint(Theme.accent) }
            else if let image = comparing ? before : preview {
                Image(uiImage: image).resizable().scaledToFit().padding(6)
                    .overlay(alignment: .topLeading) {
                        Text(comparing ? "原始输入" : "调色预览")
                            .font(AppFont.ui(10, .medium)).foregroundStyle(.white)
                            .padding(.horizontal, 9).padding(.vertical, 5)
                            .background(Color.black.opacity(0.62), in: Capsule()).padding(10)
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { _ in comparing = true }
                        .onEnded { _ in comparing = false })
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private var panelPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(panels, id: \.self) { item in
                    Button { panel = item } label: {
                        Text(item).font(AppFont.ui(12, panel == item ? .semibold : .regular))
                            .foregroundStyle(panel == item ? Theme.accent : Theme.secondary)
                            .padding(.horizontal, 12).frame(height: 32)
                            .background(Capsule().fill(panel == item ? Theme.accent.opacity(0.14) : Theme.surface))
                    }.buttonStyle(.plain)
                }
            }.padding(.horizontal, 14).padding(.vertical, 7)
        }
    }

    @ViewBuilder private var panelContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch panel {
                case "预设": presetPanel
                case "光影": lightPanel
                case "曲线": curvePanel
                case "色彩": colorPanel
                case "HSL": hslPanel
                case "分级": gradingPanel
                case "细节": detailPanel
                case "光学": opticsPanel
                default: lutPanel
                }
            }
            .padding(.horizontal, 17).padding(.top, 10).padding(.bottom, 26)
        }
        .background(Theme.surface.opacity(0.52))
    }

    private var presetPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            panelHeading("内置与自定义预设", trailing: "\(GradePresetStore.shared.all.count) 个")
            ForEach(GradePresetStore.shared.all) { preset in
                Button {
                    recipe = preset.recipe
                    if !recipe.lut.path.isEmpty { recipe.lut.path = resolveLUTPath(recipe.lut.path) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(preset.name).font(AppFont.ui(13, .medium)).foregroundStyle(Theme.text)
                            Text(presetMeta(preset.recipe)).font(AppFont.ui(10)).foregroundStyle(Theme.tertiary)
                        }
                        Spacer()
                        if preset.recipe == recipe { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent) }
                    }.padding(11).background(Theme.background.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
                }.buttonStyle(.plain)
            }
            Button("保存当前设置为预设") { showSavePreset = true }
                .font(AppFont.ui(12, .medium)).foregroundStyle(Theme.accent).padding(.top, 4)
        }
    }

    private var lightPanel: some View {
        VStack(spacing: 11) {
            panelHeading("光影", trailing: "曝光与影调")
            slider("曝光", value: $recipe.light.exposure, range: -5...5, step: 0.05, suffix: " EV")
            slider("对比度", value: $recipe.light.contrast, range: -100...100)
            slider("高光", value: $recipe.light.highlights, range: -100...100)
            slider("阴影", value: $recipe.light.shadows, range: -100...100)
            slider("白场", value: $recipe.light.whites, range: -100...100)
            slider("黑场", value: $recipe.light.blacks, range: -100...100)
            slider("中间调", value: $recipe.light.midtones, range: -100...100)
            slider("高光滚降", value: $recipe.light.highlightRolloff, range: 0...100)
            slider("曲线·阴影", value: $recipe.light.curveShadows, range: -100...100)
            slider("曲线·暗部", value: $recipe.light.curveDarks, range: -100...100)
            slider("曲线·亮部", value: $recipe.light.curveLights, range: -100...100)
            slider("曲线·高光", value: $recipe.light.curveHighlights, range: -100...100)
        }
    }

    private var curvePanel: some View {
        VStack(spacing: 10) {
            panelHeading("点曲线", trailing: "RGB 与独立通道")
            HStack(spacing: 8) {
                ForEach(["总RGB", "红", "绿", "蓝"], id: \.self) { channel in
                    Button(channel) { selectedChannel = channel }
                        .font(AppFont.ui(11, .medium))
                        .foregroundStyle(selectedChannel == channel ? Theme.accent : Theme.secondary)
                }
                Spacer()
                Button("复位") { curveBinding.wrappedValue = GradeCurves.identity }
                    .font(AppFont.ui(11)).foregroundStyle(Theme.secondary)
            }
            GradeCurveEditor(points: curveBinding).frame(height: 176)
            slider("黑位", value: $recipe.light.curveShadows, range: -100...100)
            slider("暗部", value: $recipe.light.curveDarks, range: -100...100)
            slider("亮部", value: $recipe.light.curveLights, range: -100...100)
            slider("白位", value: $recipe.light.curveHighlights, range: -100...100)
        }
    }

    private var colorPanel: some View {
        VStack(spacing: 11) {
            panelHeading("整体色彩", trailing: "白平衡与浓度")
            slider("色温", value: $recipe.color.temperature, range: -100...100)
            slider("色调", value: $recipe.color.tint, range: -100...100)
            slider("自然饱和度", value: $recipe.color.vibrance, range: -100...100)
            slider("饱和度", value: $recipe.color.saturation, range: -100...100)
            slider("整体色相", value: $recipe.color.hueShift, range: -180...180, suffix: "°")
            slider("色彩浓度", value: $recipe.color.colorDensity, range: 0...100)
            slider("色调通透", value: $recipe.transparency.tonal, range: 0...100)
            slider("色彩通透", value: $recipe.transparency.color, range: 0...100)
        }
    }

    private var hslPanel: some View {
        VStack(spacing: 11) {
            panelHeading("分色 HSL", trailing: "8 个颜色范围")
            bandPicker
            slider("色相", value: hslBinding(\.hue), range: -100...100)
            slider("饱和度", value: hslBinding(\.saturation), range: -100...100)
            slider("明度", value: hslBinding(\.luminance), range: -100...100)
        }
    }

    private var bandPicker: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 7) {
                ForEach(Array(hslNames.enumerated()), id: \.offset) { index, name in
                    Button(name) { selectedHSL = index }
                        .font(AppFont.ui(11, .medium))
                        .foregroundStyle(selectedHSL == index ? Theme.accent : Theme.secondary)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(Capsule().fill(selectedHSL == index ? Theme.accent.opacity(0.14) : Theme.background))
                }
            }
        }
    }

    private var gradingPanel: some View {
        VStack(spacing: 11) {
            panelHeading("三向色彩分级", trailing: "阴影 · 中间调 · 高光")
            HStack(spacing: 8) {
                ForEach(zoneNames, id: \.self) { zone in
                    Button(zone) { selectedZone = zone }
                        .font(AppFont.ui(11, .medium))
                        .foregroundStyle(zone == selectedZone ? Theme.accent : Theme.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            slider("色相", value: zoneBinding(\.hue), range: 0...360, suffix: "°")
            slider("饱和度", value: zoneBinding(\.saturation), range: 0...100)
            slider("明度", value: zoneBinding(\.luminance), range: -100...100)
            slider("混合", value: $recipe.color.grading.blending, range: 0...100)
            slider("平衡", value: $recipe.color.grading.balance, range: -100...100)
        }
    }

    private var detailPanel: some View {
        VStack(spacing: 11) {
            panelHeading("细节", trailing: "纹理、清晰度与降噪")
            slider("清晰度", value: $recipe.quality.clarity, range: -100...100)
            slider("纹理", value: $recipe.quality.texture, range: -100...100)
            slider("去雾", value: $recipe.quality.dehaze, range: -100...100)
            slider("锐化", value: $recipe.quality.sharpenAmount, range: 0...100)
            slider("锐化半径", value: $recipe.quality.sharpenRadius, range: 0.5...3, step: 0.05)
            slider("锐化阈值", value: $recipe.quality.sharpenThreshold, range: 0...100)
            slider("明度降噪", value: $recipe.quality.noiseLuminance, range: 0...100)
            slider("色彩降噪", value: $recipe.quality.noiseColor, range: 0...100)
        }
    }

    private var opticsPanel: some View {
        VStack(spacing: 11) {
            panelHeading("光学效果", trailing: "颗粒、暗角与色差")
            slider("暗角", value: $recipe.optics.vignetteAmount, range: -100...100)
            slider("暗角中点", value: $recipe.optics.vignetteMidpoint, range: 0...100)
            slider("暗角圆度", value: $recipe.optics.vignetteRoundness, range: -100...100)
            slider("暗角羽化", value: $recipe.optics.vignetteFeather, range: 0...100)
            slider("颗粒", value: $recipe.optics.grainAmount, range: 0...100)
            slider("颗粒尺寸", value: $recipe.optics.grainSize, range: 0...100)
            slider("颗粒粗粝", value: $recipe.optics.grainRoughness, range: 0...100)
            slider("色差", value: $recipe.optics.chromaticAberration, range: 0...100)
        }
    }

    private var lutPanel: some View {
        VStack(spacing: 10) {
            HStack {
                panelHeading("LUT 查找表", trailing: recipe.lut.path.isEmpty ? "未套用" : URL(fileURLWithPath: recipe.lut.path).deletingPathExtension().lastPathComponent)
                Spacer(minLength: 4)
                Button("导入") { showLUTImporter = true }.font(AppFont.ui(12, .medium)).foregroundStyle(Theme.accent)
            }
            Button("不使用 LUT") { recipe.lut.path = ""; recipe.lut.strength = 0 }
                .font(AppFont.ui(12)).foregroundStyle(Theme.secondary).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(GradePresetStore.shared.luts()) { lut in
                Button {
                    recipe.lut.path = lut.path
                    if recipe.lut.strength == 0 { recipe.lut.strength = 100 }
                } label: {
                    HStack { Text(lut.name).foregroundStyle(Theme.text); Spacer()
                        if recipe.lut.path == lut.path { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }.font(AppFont.ui(12)).padding(9).background(Theme.background, in: RoundedRectangle(cornerRadius: 7))
                }.buttonStyle(.plain)
            }
            slider("LUT 强度", value: $recipe.lut.strength, range: 0...100)
                .disabled(recipe.lut.path.isEmpty)
        }
    }

    private func panelHeading(_ title: String, trailing: String) -> some View {
        HStack {
            Text(title).font(AppFont.ui(14, .semibold)).foregroundStyle(Theme.text)
            Spacer()
            Text(trailing).font(AppFont.ui(10)).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>,
                        step: Double = 1, suffix: String = "") -> some View {
        VStack(spacing: 3) {
            HStack {
                Text(title).font(AppFont.ui(11)).foregroundStyle(Theme.secondary)
                Spacer()
                Text(step < 1 ? String(format: "%.2f%@", value.wrappedValue, suffix)
                               : String(format: "%.0f%@", value.wrappedValue, suffix))
                    .font(AppFont.mono(10)).foregroundStyle(Theme.text)
            }
            Slider(value: value, in: range, step: step).tint(Theme.accent)
        }
    }

    private var curveBinding: Binding<[GradeCurvePoint]> {
        Binding(get: {
            switch selectedChannel {
            case "红": recipe.curves.red
            case "绿": recipe.curves.green
            case "蓝": recipe.curves.blue
            default: recipe.curves.master
            }
        }, set: { points in
            switch selectedChannel {
            case "红": recipe.curves.red = points
            case "绿": recipe.curves.green = points
            case "蓝": recipe.curves.blue = points
            default: recipe.curves.master = points
            }
        })
    }

    private func hslBinding(_ keyPath: WritableKeyPath<HslBand, Double>) -> Binding<Double> {
        Binding(get: { recipe.color.hsl[selectedHSL][keyPath: keyPath] },
                set: { recipe.color.hsl[selectedHSL][keyPath: keyPath] = $0 })
    }

    private func zoneBinding(_ keyPath: WritableKeyPath<GradeZone, Double>) -> Binding<Double> {
        Binding(get: { selectedGradeZone[keyPath: keyPath] }, set: { selectedGradeZone[keyPath: keyPath] = $0 })
    }

    private var selectedGradeZone: GradeZone {
        get {
            switch selectedZone {
            case "中间调": recipe.color.grading.midtones
            case "高光": recipe.color.grading.highlights
            default: recipe.color.grading.shadows
            }
        }
        nonmutating set {
            switch selectedZone {
            case "中间调": recipe.color.grading.midtones = newValue
            case "高光": recipe.color.grading.highlights = newValue
            default: recipe.color.grading.shadows = newValue
            }
        }
    }

    private func presetMeta(_ value: GradeRecipe) -> String {
        var result: [String] = []
        if value.light.exposure != 0 { result.append(String(format: "曝光 %+.1f", value.light.exposure)) }
        if value.color.temperature != 0 { result.append("色温 \(Int(value.color.temperature))") }
        if value.color.saturation != 0 { result.append("饱和 \(Int(value.color.saturation))") }
        return result.isEmpty ? "中性基准" : result.joined(separator: " · ")
    }

    private func resolveLUTPath(_ path: String) -> String {
        if FileManager.default.fileExists(atPath: path) { return path }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return GradePresetStore.shared.luts().first { URL(fileURLWithPath: $0.path).lastPathComponent == name }?.path ?? ""
    }

    private var inputURL: URL? {
        if source == .original { return library.originalURL(for: photo) }
        if let base = photo.gradeBaseName { return library.url(base) }
        return library.fileURL(for: photo)
    }

    private func loadPreview() async {
        guard let inputURL else { error = "找不到原图文件"; isLoading = false; return }
        let beforeImage = try? await Task.detached(priority: .userInitiated) {
            try GradeImageCodec.render(inputURL: inputURL, recipe: GradeRecipe(), maxLongEdge: 1400)
        }.value
        before = beforeImage
        await refreshPreview()
        isLoading = false
    }

    private func schedulePreview() {
        previewToken += 1
        let token = previewToken
        Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard token == previewToken else { return }
            await refreshPreview()
        }
    }

    private func refreshPreview() async {
        guard let inputURL else { return }
        let token = previewToken
        let selected = recipe
        let image = try? await Task.detached(priority: .userInitiated) {
            try GradeImageCodec.render(inputURL: inputURL, recipe: selected, maxLongEdge: 1400)
        }.value
        guard token == previewToken else { return }
        preview = image
    }

    private func finish() {
        guard !isWorking else { return }
        isWorking = true
        guard let inputURL else { error = "找不到源照片"; isWorking = false; return }
        if source == .print {
            Task {
                do {
                    try await library.applyGrade(recipe, to: photo)
                    dismiss()
                } catch { self.error = error.localizedDescription }
                isWorking = false
            }
            return
        }
        Task {
            do {
                let originalData = try Data(contentsOf: inputURL, options: .mappedIfSafe)
                let raw = PhotoDecoder.isRAW(url: inputURL, data: originalData)
                let output = try await Task.detached(priority: .userInitiated) {
                    try GradeImageCodec.render(data: originalData, isRAW: raw, recipe: recipe)
                }.value
                guard let output, let gradedData = UIImage(cgImage: output).jpegData(compressionQuality: 0.98) else {
                    throw EngineError.decode("原图调色输出失败")
                }
                onSendToDarkroom(gradedData, originalData, inputURL.pathExtension.isEmpty ? (raw ? "dng" : "heic") : inputURL.pathExtension)
                dismiss()
            } catch { self.error = error.localizedDescription }
            isWorking = false
        }
    }

    private static func initialRecipe(for photo: DevelopedPhoto) -> GradeRecipe {
        if let data = photo.gradeRecipeData, let recipe = try? JSONDecoder().decode(GradeRecipe.self, from: data) {
            return recipe
        }
        guard let old = photo.postGrade else { return GradeRecipe() }
        var recipe = GradeRecipe()
        recipe.light.exposure = old.exposure
        recipe.light.contrast = old.contrast
        recipe.light.highlights = old.highlights
        recipe.light.shadows = old.shadows
        recipe.color.saturation = old.saturation
        recipe.color.temperature = old.temperature
        recipe.color.tint = old.tint
        recipe.curves.master = old.masterCurve.map { GradeCurvePoint(x: $0.x, y: $0.y) }
        recipe.curves.red = old.redCurve.map { GradeCurvePoint(x: $0.x, y: $0.y) }
        recipe.curves.green = old.greenCurve.map { GradeCurvePoint(x: $0.x, y: $0.y) }
        recipe.curves.blue = old.blueCurve.map { GradeCurvePoint(x: $0.x, y: $0.y) }
        return recipe
    }
}

private struct GradeCurveEditor: View {
    @Binding var points: [GradeCurvePoint]
    @State private var activeIndex: Int?

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                RoundedRectangle(cornerRadius: 9).fill(Theme.surface)
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
                    path.move(to: CGPoint(x: CGFloat(first.x) * size.width,
                                          y: CGFloat(1 - first.y) * size.height))
                    for point in points.dropFirst() {
                        path.addLine(to: CGPoint(x: CGFloat(point.x) * size.width,
                                                 y: CGFloat(1 - point.y) * size.height))
                    }
                }.stroke(Theme.accent, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                ForEach(Array(points.enumerated()), id: \.offset) { item in
                    Circle().fill(Theme.text).frame(width: 10, height: 10)
                        .position(x: CGFloat(item.element.x) * size.width,
                                  y: CGFloat(1 - item.element.y) * size.height)
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if activeIndex == nil { activeIndex = nearest(value.location, size: size) }
                    guard let index = activeIndex, index > 0, index < points.count - 1 else { return }
                    let x = min(1, max(0, value.location.x / size.width))
                    let y = min(1, max(0, 1 - value.location.y / size.height))
                    let low = points[index - 1].x + 0.03
                    let high = points[index + 1].x - 0.03
                    points[index] = GradeCurvePoint(x: Double(min(high, max(low, x))), y: Double(y))
                }
                .onEnded { _ in activeIndex = nil })
        }
    }

    private func nearest(_ location: CGPoint, size: CGSize) -> Int? {
        var best: (Int, CGFloat)?
        for (index, point) in points.enumerated() {
            let distance = hypot(CGFloat(point.x) * size.width - location.x,
                                 CGFloat(1 - point.y) * size.height - location.y)
            if distance < 34, best == nil || distance < best!.1 { best = (index, distance) }
        }
        return best?.0
    }
}
