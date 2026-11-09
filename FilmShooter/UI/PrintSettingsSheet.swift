import SwiftUI

// MARK: - Recipe controls (shared by the print sheet and the editor)

/// Paper, enlarger, texture, format and print options for a recipe.
struct RecipeControls: View {
    @Binding var recipe: DevelopRecipe
    /// The editor exposes film exposure; the camera uses its own compensation.
    var showsExposure: Bool = false
    /// The darkroom workspace places paper selection directly under the film list.
    var showsPaper: Bool = true
    /// Use the editor's shared translucent surface for every adjustment group.
    var frostedSections: Bool = false
    var compact: Bool = false
    /// Forwarded from every slider (true while dragging). The camera's print
    /// sheet uses it to hold the viewfinder re-bake until the drag ends.
    var onEditingChanged: (Bool) -> Void = { _ in }

    var body: some View {
        let film = recipe.film
        VStack(alignment: .leading, spacing: compact ? 8 : 16) {
            if showsExposure {
                ControlSection(title: "曝光", spacing: compact ? 8 : 14,
                               compact: compact, frosted: frostedSections) {
                    FilmSlider(title: "曝光补偿", value: $recipe.exposureEV, range: -3...3,
                               defaultValue: 0, format: FilmSlider.ev, compact: compact, onEditingChanged: onEditingChanged)
                    SettingToggle(title: "自动测光", subtitle: compact ? nil : "让引擎为这张照片测光，再叠加上面的补偿",
                                  isOn: $recipe.autoExposure)
                }
            }

            if film.kind.usesPrintPaper {
                if showsPaper {
                    ControlSection(title: "相纸", trailing: film.kind == .blackWhite ? "黑白相纸" : "彩色相纸",
                                   spacing: compact ? 8 : 14, compact: compact,
                                   frosted: frostedSections) {
                        PaperPicker(film: film, selection: Binding(
                            get: { recipe.resolvedPaperID },
                            set: { recipe.paperID = $0 }))
                            .id(film.id)
                    }
                }
                ControlSection(title: "放大机", spacing: compact ? 8 : 14,
                               compact: compact, frosted: frostedSections) {
                    FilmSlider(title: "亮度", value: $recipe.printBrightness, range: -2...2,
                               defaultValue: 0, leadingLabel: "暗", trailingLabel: "亮", format: FilmSlider.ev, compact: compact,
                               onEditingChanged: onEditingChanged)
                    FilmSlider(title: "冷暖", value: $recipe.warmth, range: -1...1,
                               defaultValue: 0, leadingLabel: "冷", trailingLabel: "暖", format: FilmSlider.signed, compact: compact,
                               onEditingChanged: onEditingChanged)
                    FilmSlider(title: "品绿", value: $recipe.tint, range: -1...1,
                               defaultValue: 0, leadingLabel: "绿", trailingLabel: "品", format: FilmSlider.signed, compact: compact,
                               onEditingChanged: onEditingChanged)
                }
            } else if !film.kind.usesPrintPaper && showsPaper {
                HStack(spacing: 10) {
                    Image(systemName: "sun.max")
                        .foregroundStyle(Theme.secondary)
                    Text("反转片直接观看，没有相纸和放大机这一步")
                        .font(AppFont.ui(compact ? 11 : 13))
                        .foregroundStyle(Theme.secondary)
                }
                .padding(.horizontal, 4)
            }

            ControlSection(title: "质感", spacing: compact ? 8 : 14,
                           compact: compact, frosted: frostedSections) {
                FilmSlider(title: "颗粒", value: $recipe.grain, range: 0...2,
                           defaultValue: 1, leadingLabel: "细腻", trailingLabel: "粗犷", format: FilmSlider.times, compact: compact,
                           onEditingChanged: onEditingChanged)
                FilmSlider(title: "光晕", value: $recipe.halation, range: 0...3,
                           defaultValue: 1, leadingLabel: "无", trailingLabel: "浓", format: FilmSlider.times, compact: compact,
                           onEditingChanged: onEditingChanged)
                HStack(spacing: compact ? 6 : 12) {
                    Text("底片")
                        .font(AppFont.ui(compact ? 12 : 15, .medium))
                        .foregroundStyle(Theme.text)
                    Spacer(minLength: 8)
                    PillSegmented(options: FilmFormat.allCases, selection: $recipe.format,
                                  title: { $0.title }, subtitle: { $0.subtitle })
                        .frame(width: compact ? 160 : 200)
                }
            }

            ControlSection(title: "冲印", spacing: compact ? 8 : 14,
                           compact: compact, frosted: frostedSections) {
                SettingToggle(title: "胶片边框", subtitle: compact ? nil : "连同片基、齿孔和边缘字一起印出来",
                              systemImage: "film", isOn: $recipe.filmEdge)
                RowDivider(inset: 34)
                SettingToggle(title: "日期印", subtitle: compact ? nil : "像日期后背一样，在角落印上拍摄日期",
                              systemImage: "calendar", isOn: $recipe.dateStamp)
            }
        }
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
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(selected ? Theme.text : Theme.tertiary.opacity(0.6))
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
                                        .font(AppFont.ui(11, .medium))
                                        .foregroundStyle(Theme.tertiary)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .frame(minWidth: 124, minHeight: 60, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(selected ? Color.white.opacity(0.08) : Color.white.opacity(0.03)))
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
/// straight to `model.recipe`; the viewfinder re-bakes once a slider is let go.
struct PrintSettingsSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private static let compact = PresentationDetent.height(360)

    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                RecipeControls(recipe: $model.recipe, showsExposure: false,
                               onEditingChanged: { editing in
                                   if model.isAdjustingPrint != editing { model.isAdjustingPrint = editing }
                               })
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .onDisappear {
            if model.isAdjustingPrint { model.isAdjustingPrint = false }
        }
        .presentationDetents([Self.compact, .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground { SheetBackground() }
        .presentationBackgroundInteraction(.enabled(upThrough: Self.compact))
    }

    private var isModified: Bool {
        let r = model.recipe
        let d = DevelopRecipe()
        return r.printBrightness != d.printBrightness || r.warmth != d.warmth || r.tint != d.tint
            || r.grain != d.grain || r.halation != d.halation
    }

    private var header: some View {
        let film = model.film
        let modified = isModified
        return HStack(alignment: .center, spacing: 12) {
            FilmCanister(film: film, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text("冲印设置")
                    .font(AppFont.ui(17, .semibold))
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
                    .foregroundStyle(modified ? Theme.accent : Theme.secondary)
                    .frame(minWidth: 44, minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .disabled(!modified)
            Button {
                dismiss()
            } label: {
                RoundIcon(systemName: "xmark", size: 30, iconSize: 11, tint: Theme.secondary, fill: Theme.surfaceHigh)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("完成"))
        }
        .padding(.leading, 20)
        .padding(.trailing, 10)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .animation(Motion.fade, value: film.id)
        .animation(Motion.fade, value: modified)
    }
}
