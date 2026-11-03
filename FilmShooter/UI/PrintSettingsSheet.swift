import SwiftUI

// MARK: - Recipe controls (shared by the print sheet and the editor)

/// Paper, enlarger, texture, format and print options for a recipe.
struct RecipeControls: View {
    @Binding var recipe: DevelopRecipe
    /// The editor exposes film exposure; the camera uses its own compensation.
    var showsExposure: Bool = false

    var body: some View {
        let film = recipe.film
        VStack(alignment: .leading, spacing: 22) {
            if showsExposure {
                ControlSection(title: "曝光") {
                    FilmSlider(title: "曝光补偿", value: $recipe.exposureEV, range: -3...3,
                               defaultValue: 0, format: FilmSlider.ev)
                    SettingToggle(title: "自动测光", subtitle: "让引擎为这张照片测光，再叠加上面的补偿",
                                  isOn: $recipe.autoExposure)
                }
            }

            if film.kind.usesPrintPaper {
                ControlSection(title: "相纸", trailing: film.kind == .blackWhite ? "黑白相纸" : "彩色相纸") {
                    PaperPicker(film: film, selection: Binding(
                        get: { recipe.resolvedPaperID },
                        set: { recipe.paperID = $0 }))
                }
                ControlSection(title: "放大机") {
                    FilmSlider(title: "亮度", value: $recipe.printBrightness, range: -2...2,
                               defaultValue: 0, leadingLabel: "暗", trailingLabel: "亮", format: FilmSlider.ev)
                    FilmSlider(title: "冷暖", value: $recipe.warmth, range: -1...1,
                               defaultValue: 0, leadingLabel: "冷", trailingLabel: "暖", format: FilmSlider.signed)
                    FilmSlider(title: "品绿", value: $recipe.tint, range: -1...1,
                               defaultValue: 0, leadingLabel: "绿", trailingLabel: "品", format: FilmSlider.signed)
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "sun.max")
                        .foregroundStyle(Theme.accent)
                    Text("反转片直接观看，没有相纸和放大机这一步")
                        .font(AppFont.ui(12.5))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 4)
            }

            ControlSection(title: "质感") {
                FilmSlider(title: "颗粒", value: $recipe.grain, range: 0...2,
                           defaultValue: 1, leadingLabel: "细腻", trailingLabel: "粗犷", format: FilmSlider.times)
                FilmSlider(title: "光晕", value: $recipe.halation, range: 0...3,
                           defaultValue: 1, leadingLabel: "无", trailingLabel: "浓", format: FilmSlider.times)
                VStack(alignment: .leading, spacing: 8) {
                    Text("底片尺寸")
                        .font(AppFont.ui(14, .medium))
                        .foregroundStyle(Theme.text)
                    PillSegmented(options: FilmFormat.allCases, selection: $recipe.format,
                                  title: { $0.title }, subtitle: { $0.subtitle })
                }
            }

            ControlSection(title: "冲印") {
                SettingToggle(title: "胶片边框", subtitle: "连同片基、齿孔和边缘字一起印出来",
                              systemImage: "film", isOn: $recipe.filmEdge)
                SettingToggle(title: "日期印", subtitle: "像日期后背一样，在角落印上拍摄日期",
                              systemImage: "calendar", isOn: $recipe.dateStamp)
            }
        }
        .animation(Motion.standard, value: film.kind)
    }
}

/// Horizontal cards of the papers that suit the film.
struct PaperPicker: View {
    let film: FilmStock
    @Binding var selection: String

    var body: some View {
        let papers = FilmCatalog.papers(for: film)
        ScrollViewReader { proxy in
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(papers) { paper in
                        let selected = paper.id == selection
                        Button {
                            guard paper.id != selection else { return }
                            Haptics.selection()
                            withAnimation(Motion.snappy) { selection = paper.id }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(selected ? Theme.accent : Theme.tertiary.opacity(0.6))
                                        .frame(width: 6, height: 6)
                                    Text(paper.name.replacingOccurrences(of: "Kodak ", with: "")
                                        .replacingOccurrences(of: "Fujifilm ", with: "")
                                        .replacingOccurrences(of: "Ilford ", with: ""))
                                        .font(AppFont.ui(13, .semibold))
                                        .foregroundStyle(selected ? Theme.text : Theme.text.opacity(0.8))
                                        .lineLimit(1)
                                }
                                Text(paper.tagline)
                                    .font(AppFont.ui(11))
                                    .foregroundStyle(Theme.secondary)
                                    .lineLimit(1)
                                if paper.id == film.defaultPaper {
                                    Text("原配相纸")
                                        .font(AppFont.ui(9.5, .semibold))
                                        .foregroundStyle(Theme.accent.opacity(0.9))
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .frame(minWidth: 128, minHeight: 66, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selected ? Theme.accent.opacity(0.12) : Color.white.opacity(0.04)))
                            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .strokeBorder(selected ? Theme.accent.opacity(0.7) : Theme.hairline, lineWidth: 1))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.pressable(scale: 0.96))
                        .id(paper.id)
                    }
                }
                .padding(.vertical, 1)
            }
            .scrollIndicators(.hidden)
            .onAppear { proxy.scrollTo(selection, anchor: .center) }
        }
    }
}

// MARK: - Sheet

/// "冲印": how the camera's frames are developed and printed. Edits go
/// straight to `model.recipe` (the viewfinder follows live above the sheet).
struct PrintSettingsSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            header
            ScrollView {
                RecipeControls(recipe: $model.recipe, showsExposure: false)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                    .padding(.bottom, 30)
            }
            .scrollIndicators(.hidden)
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.background.opacity(0.55)
            }
        }
        .presentationBackgroundInteraction(.enabled(upThrough: .medium))
    }

    private var header: some View {
        let film = model.film
        return HStack(alignment: .center, spacing: 12) {
            FilmCanister(film: film, height: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("冲印设置")
                    .font(AppFont.ui(20, .semibold))
                    .foregroundStyle(Theme.text)
                Text(model.paper.map { "\(film.name) · \($0.name)" } ?? "\(film.name) · 反转片")
                    .font(AppFont.ui(12))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 8)
            Button {
                Haptics.softTap()
                withAnimation(Motion.standard) {
                    var r = model.recipe
                    let defaults = DevelopRecipe()
                    r.printBrightness = defaults.printBrightness
                    r.warmth = defaults.warmth
                    r.tint = defaults.tint
                    r.grain = defaults.grain
                    r.halation = defaults.halation
                    model.recipe = r
                }
            } label: {
                Text("复位")
                    .font(AppFont.ui(13, .semibold))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Theme.accent.opacity(0.12)))
            }
            .buttonStyle(.pressable)
            Button {
                dismiss()
            } label: {
                RoundIcon(systemName: "xmark", size: 30, iconSize: 11, tint: Theme.secondary, fill: Theme.surfaceHigh)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("完成"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .animation(Motion.fade, value: film.id)
    }
}
