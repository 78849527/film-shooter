import SwiftUI
import UIKit

/// Compact photo-extension interface. Apple's Photos editor supplies its own
/// brilliance, exposure, highlights, shadows, crop and straightening tools.
struct PhotoEditingScreen: View {
    @ObservedObject var model: PhotoEditingModel
    @State private var visibleKind: FilmKind? = nil

    private let background = Color(red: 0.055, green: 0.052, blue: 0.05)
    private let accent = Color(red: 0.95, green: 0.66, blue: 0.31)

    private var visibleFilms: [FilmStock] {
        if let visibleKind { return FilmCatalog.films(of: visibleKind) }
        return FilmCatalog.films
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 15) {
                heading
                photograph
                filmTypes
                filmStocks
                paperOptions
                adjustments
                if let error = model.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(10)
                }
                Text("完成后可继续使用系统照片的鲜明度、曝光、裁剪等工具")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.46))
                    .padding(.bottom, 20)
            }
            .padding(.horizontal, 14)
            .padding(.top, 8)
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .disabled(model.isFinishing)
    }

    private var heading: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("FilmShooter")
                    .font(.system(size: 18, weight: .semibold))
                Text("光谱胶片 · 相纸冲印")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.58))
            }
            Spacer()
            if model.isFinishing {
                ProgressView()
                Text("正在导出")
                    .font(.system(size: 12))
            } else if model.isRendering || model.isLoading {
                ProgressView()
                Text("显影中")
                    .font(.system(size: 12))
            } else if model.previewMatchesSelection {
                Image(systemName: "checkmark.circle")
                    .foregroundStyle(accent)
            }
        }
    }

    private var photograph: some View {
        ZStack {
            Color.black
            if model.previewMatchesSelection, let frame = model.rendered {
                Image(uiImage: frame.image)
                    .resizable()
                    .scaledToFit()
            } else if let original = model.original {
                Image(uiImage: original)
                    .resizable()
                    .scaledToFit()
                    .blur(radius: 4)
                    .opacity(0.55)
                ProgressView()
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 260)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(alignment: .bottom) {
            Text(model.recipe.film.displayName)
                .font(.system(size: 13, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.black.opacity(0.72), in: Capsule())
                .padding(.bottom, 8)
        }
    }

    private var filmTypes: some View {
        HStack(spacing: 5) {
            category("全部", kind: nil)
            ForEach(FilmKind.allCases) { kind in
                category(kind.chipTitle, kind: kind)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func category(_ title: String, kind: FilmKind?) -> some View {
        let selected = visibleKind == kind
        return Button {
            guard visibleKind != kind else { return }
            visibleKind = kind
            if let kind, let first = FilmCatalog.films(of: kind).first {
                model.selectFilm(first.id)
            }
        } label: {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(selected ? Color.black : Color.white.opacity(0.75))
                .frame(maxWidth: .infinity, minHeight: 32)
                .background(selected ? accent : Color.white.opacity(0.1), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var filmStocks: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(visibleFilms) { film in
                    let selected = film.id == model.recipe.filmID
                    Button {
                        model.selectFilm(film.id)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(film.brand)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.58))
                            Text(film.name)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(1)
                            Text("ISO \(film.iso)")
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.58))
                        }
                        .frame(width: 135, alignment: .leading)
                        .padding(12)
                        .background(selected ? accent.opacity(0.18) : Color.white.opacity(0.07),
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9)
                            .strokeBorder(selected ? accent : .white.opacity(0.1), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private var paperOptions: some View {
        if model.recipe.film.kind.usesPrintPaper {
            VStack(alignment: .leading, spacing: 9) {
                Text("相纸")
                    .font(.system(size: 14, weight: .semibold))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(FilmCatalog.papers(for: model.recipe.film)) { paper in
                            let selected = model.recipe.resolvedPaperID == paper.id
                            Button {
                                model.selectPaper(paper.id)
                            } label: {
                                Text(paper.name)
                                    .font(.system(size: 12))
                                    .lineLimit(1)
                                    .padding(.horizontal, 10)
                                    .frame(height: 34)
                                    .background(selected ? accent.opacity(0.2) : Color.white.opacity(0.07),
                                                in: Capsule())
                                    .overlay(Capsule().strokeBorder(
                                        selected ? accent : .white.opacity(0.1), lineWidth: 1
                                    ))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            Text("反转片直接观看 · 不使用冲印相纸")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var adjustments: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("胶片参数")
                .font(.system(size: 14, weight: .semibold))

            Toggle("自动测光", isOn: Binding(
                get: { model.recipe.autoExposure },
                set: { on in model.change { $0.autoExposure = on } }
            ))
            .tint(accent)

            slider("曝光补偿", value: Binding(
                get: { model.recipe.exposureEV },
                set: { v in model.change { $0.exposureEV = v } }
            ), range: -3...3)

            if model.recipe.film.kind.usesPrintPaper {
                slider("相纸亮度", value: Binding(
                    get: { model.recipe.printBrightness },
                    set: { v in model.change { $0.printBrightness = v } }
                ), range: -2...2)
            }

            slider("颗粒", value: Binding(
                get: { model.recipe.grain },
                set: { v in model.change { $0.grain = v } }
            ), range: 0...2)

            slider("光晕", value: Binding(
                get: { model.recipe.halation },
                set: { v in model.change { $0.halation = v } }
            ), range: 0...3)

            Toggle("胶片边框", isOn: Binding(
                get: { model.recipe.filmEdge },
                set: { on in model.change { $0.filmEdge = on } }
            ))
            .tint(accent)

            Toggle("日期印", isOn: Binding(
                get: { model.recipe.dateStamp },
                set: { on in model.change { $0.dateStamp = on } }
            ))
            .tint(accent)
        }
        .font(.system(size: 13))
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
    }

    private func slider(_ title: String, value: Binding<Double>,
                        range: ClosedRange<Double>) -> some View {
        VStack(spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f", value.wrappedValue))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.6))
            }
            Slider(value: value, in: range)
                .tint(accent)
        }
    }
}
