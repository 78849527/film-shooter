import SwiftUI
import UIKit

/// Photos extension darkroom: one film menu contains the same ordered controls
/// as the main editor, in a compact translucent panel.
struct PhotoEditingScreen: View {
    @ObservedObject var model: PhotoEditingModel
    @State private var visibleKind: FilmKind? = nil
    @State private var activePanel = false

    private let background = Color(red: 0.055, green: 0.052, blue: 0.05)
    private let accent = Color(red: 0.95, green: 0.66, blue: 0.31)

    private var visibleFilms: [FilmStock] {
        if let visibleKind { return FilmCatalog.films(of: visibleKind) }
        return FilmCatalog.films
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                photograph
                    .frame(maxHeight: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.top, 4)
                    .overlay(alignment: .leading) { sideRail.padding(.leading, 8) }
                if let error = model.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                        .lineLimit(2).padding(.horizontal, 12).padding(.vertical, 4)
                }
                bottomTools
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if activePanel {
                    let landscape = geometry.size.width > geometry.size.height
                    panel
                        .frame(width: landscape
                               ? min(400, geometry.size.width * 0.46)
                               : min(350, geometry.size.width * 0.84),
                               height: landscape
                               ? min(geometry.size.height * 0.57, 520)
                               : min(geometry.size.height / 3, 360))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 7)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                        .zIndex(2)
                }
            }
        }
        .background(background.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .disabled(model.isFinishing)
    }

    private var photograph: some View {
        ZStack {
            Color.black
            if model.previewMatchesSelection, let frame = model.rendered {
                Image(uiImage: frame.image).resizable().scaledToFit()
            } else if let original = model.original {
                Image(uiImage: original).resizable().scaledToFit().blur(radius: 4).opacity(0.55)
                ProgressView()
            } else { ProgressView() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Text("FilmShooter").font(.system(size: 12, weight: .semibold))
                Text("·").foregroundStyle(.white.opacity(0.55))
                Text(model.recipe.film.displayName).font(.system(size: 12))
                Spacer(minLength: 4)
                if model.isFinishing || model.isRendering || model.isLoading {
                    ProgressView().controlSize(.small)
                    Text(model.isFinishing ? (model.exportStage.isEmpty ? "正在导出" : model.exportStage) : "显影中")
                        .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.7)
                } else if model.previewMatchesSelection {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule()).padding(8)
        }
    }

    private var sideRail: some View {
        VStack(spacing: 5) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { activePanel.toggle() }
            } label: {
                railItem("胶片", symbol: "camera.filters", selected: activePanel)
            }.buttonStyle(.plain)
        }
        .padding(.vertical, 6)
        .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 14))
    }

    private func railItem(_ title: String, symbol: String, selected: Bool) -> some View {
        VStack(spacing: 3) {
            Image(systemName: symbol).font(.system(size: 15, weight: .medium)).frame(height: 20)
            Text(title).font(.system(size: 9, weight: .semibold))
        }
        .foregroundStyle(selected ? accent : .white.opacity(0.82))
        .frame(width: 47, height: 43)
        .contentShape(Rectangle())
    }

    private var bottomTools: some View {
        HStack(spacing: 8) {
            Text("系统照片负责取消与保存")
                .font(.system(size: 10)).lineLimit(1).foregroundStyle(.white.opacity(0.72))
            Spacer(minLength: 4)
            if model.isFinishing {
                ProgressView().controlSize(.small)
                Text(model.exportStage.isEmpty ? "正在导出" : model.exportStage)
                    .font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.75)
            } else {
                Text("调整自动预览")
                    .font(.system(size: 10)).foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(.black.opacity(0.5))
    }

    private var panel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("胶片").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 6)
                Text(model.recipe.film.displayName).font(.system(size: 10)).foregroundStyle(.white.opacity(0.58))
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.16)) { activePanel = false } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.white.opacity(0.65))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    filmControls
                    exposureControls
                    enlargerControls
                    textureControls
                    formatControls
                    printControls
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(.white.opacity(0.11), lineWidth: 0.7))
        .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
    }

    private var filmControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                category("全部", kind: nil)
                ForEach(FilmKind.allCases) { kind in category(kind.chipTitle, kind: kind) }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 7) {
                    ForEach(visibleFilms) { film in
                        let selected = film.id == model.recipe.filmID
                        Button { model.selectFilm(film.id) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(film.brand).font(.system(size: 9)).foregroundStyle(.white.opacity(0.58))
                                Text(film.name).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                                Text("ISO \(film.iso)").font(.system(size: 9, design: .monospaced)).foregroundStyle(.white.opacity(0.58))
                            }
                            .frame(width: 110, alignment: .leading).padding(8)
                            .background(selected ? accent.opacity(0.2) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? accent : .white.opacity(0.1), lineWidth: 0.8))
                        }.buttonStyle(.plain)
                    }
                }
            }
            if model.recipe.film.kind.usesPrintPaper {
                Text("相纸").font(.system(size: 10, weight: .medium)).foregroundStyle(.white.opacity(0.7))
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(FilmCatalog.papers(for: model.recipe.film)) { paper in
                            let selected = model.recipe.resolvedPaperID == paper.id
                            Button { model.selectPaper(paper.id) } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(paper.name
                                        .replacingOccurrences(of: "Kodak ", with: "")
                                        .replacingOccurrences(of: "Fujifilm ", with: "")
                                        .replacingOccurrences(of: "Ilford ", with: ""))
                                        .font(.system(size: 10, weight: .semibold)).lineLimit(1)
                                    Text(paper.tagline).font(.system(size: 9))
                                        .foregroundStyle(.white.opacity(0.58)).lineLimit(1)
                                    if paper.id == model.recipe.film.defaultPaper {
                                        Text("原配相纸").font(.system(size: 8)).foregroundStyle(accent)
                                    }
                                }
                                .padding(.horizontal, 9).padding(.vertical, 7)
                                .frame(minWidth: 112, alignment: .leading)
                                .background(selected ? accent.opacity(0.22) : .white.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
                                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(selected ? accent : .white.opacity(0.1), lineWidth: 0.8))
                            }.buttonStyle(.plain)
                        }
                    }
                }
            } else {
                Text("反转片直出，不使用冲印相纸").font(.system(size: 10)).foregroundStyle(.white.opacity(0.55))
            }
        }
    }

    private func category(_ title: String, kind: FilmKind?) -> some View {
        let selected = visibleKind == kind
        return Button {
            guard visibleKind != kind else { return }
            visibleKind = kind
            if let kind, let first = FilmCatalog.films(of: kind).first { model.selectFilm(first.id) }
        } label: {
            Text(title).font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? .black : .white.opacity(0.76))
                .frame(maxWidth: .infinity, minHeight: 27)
                .background(selected ? accent : .white.opacity(0.1), in: Capsule())
        }.buttonStyle(.plain)
    }

    private var exposureControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("曝光")
            slider("曝光补偿", value: Binding(get: { model.recipe.exposureEV }, set: { v in model.change { $0.exposureEV = v } }), range: -3...3)
            Toggle("自动测光", isOn: Binding(get: { model.recipe.autoExposure }, set: { on in model.change { $0.autoExposure = on } }))
                .font(.system(size: 11)).tint(accent)
        }
    }

    private var enlargerControls: some View {
        Group {
            if model.recipe.film.kind.usesPrintPaper {
                VStack(alignment: .leading, spacing: 5) {
                    sectionTitle("放大机")
                    slider("亮度", value: Binding(get: { model.recipe.printBrightness }, set: { v in model.change { $0.printBrightness = v } }), range: -2...2)
                    slider("冷暖", value: Binding(get: { model.recipe.warmth }, set: { v in model.change { $0.warmth = v } }), range: -1...1)
                    slider("品绿", value: Binding(get: { model.recipe.tint }, set: { v in model.change { $0.tint = v } }), range: -1...1)
                }
            }
        }
    }

    private var textureControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("质感")
            slider("颗粒", value: Binding(get: { model.recipe.grain }, set: { v in model.change { $0.grain = v } }), range: 0...2)
            slider("光晕", value: Binding(get: { model.recipe.halation }, set: { v in model.change { $0.halation = v } }), range: 0...3)
        }
    }

    private var formatControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("底片")
            HStack(spacing: 6) {
                ForEach(FilmFormat.allCases, id: \.self) { format in
                    Button { model.change { $0.format = format } } label: {
                        VStack(spacing: 2) {
                            Text(format.title).font(.system(size: 10, weight: .semibold))
                            Text(format.subtitle).font(.system(size: 8)).lineLimit(1)
                        }.frame(maxWidth: .infinity, minHeight: 34)
                            .foregroundStyle(model.recipe.format == format ? accent : .white.opacity(0.75))
                            .background(.white.opacity(model.recipe.format == format ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain)
                }
            }
        }
    }

    private var printControls: some View {
        VStack(alignment: .leading, spacing: 5) {
            sectionTitle("冲印")
            if model.recipe.film.kind.usesPrintPaper {
                toggle("胶片边框", value: Binding(get: { model.recipe.filmEdge }, set: { on in model.change { $0.filmEdge = on } }))
            }
            toggle("日期印", value: Binding(get: { model.recipe.dateStamp }, set: { on in model.change { $0.dateStamp = on } }))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.74))
            .padding(.top, 4)
    }

    private func toggle(_ title: String, value: Binding<Bool>) -> some View {
        Toggle(title, isOn: value).font(.system(size: 11)).tint(accent)
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(spacing: 1) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: "%.1f", value.wrappedValue)).monospacedDigit().foregroundStyle(.white.opacity(0.58))
            }.font(.system(size: 10))
            Slider(value: value, in: range).tint(accent).frame(height: 25)
        }
    }
}
