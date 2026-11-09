import SwiftUI
import UIKit

/// Compact Photos extension editor. The two-row dock stays visible while each
/// tool opens a translucent, independently scrollable control panel.
struct PhotoEditingScreen: View {
    @ObservedObject var model: PhotoEditingModel
    @State private var visibleKind: FilmKind? = nil
    @State private var activePanel: Panel? = nil

    private let background = Color(red: 0.055, green: 0.052, blue: 0.05)
    private let accent = Color(red: 0.95, green: 0.66, blue: 0.31)

    private enum Panel: String, Identifiable {
        case film = "胶片", exposure = "曝光", texture = "质感", print = "冲印"
        var id: String { rawValue }
    }

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
                    .overlay(alignment: .leading) {
                        if activePanel == nil {
                            sideRail.padding(.leading, 8)
                        }
                    }
                if let error = model.error {
                    Text(error).font(.system(size: 11)).foregroundStyle(.red)
                        .lineLimit(2).padding(.horizontal, 12).padding(.vertical, 4)
                }
                bottomTools
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if let activePanel {
                    panel(activePanel)
                        .frame(maxHeight: min(geometry.size.height * 0.48, 340))
                        .padding(.horizontal, 8)
                        .padding(.bottom, 102)
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
                withAnimation(.easeOut(duration: 0.18)) { activePanel = .film }
            } label: {
                railItem("胶片", symbol: "camera.filters", selected: activePanel == .film)
            }.buttonStyle(.plain)
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    activePanel = activePanel == .exposure ? nil : .exposure
                }
            } label: { railItem("曝光", symbol: "sun.max", selected: activePanel == .exposure) }
                .buttonStyle(.plain)
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    activePanel = activePanel == .texture ? nil : .texture
                }
            } label: { railItem("质感", symbol: "circle.lefthalf.filled", selected: activePanel == .texture) }
                .buttonStyle(.plain)
            Button {
                withAnimation(.easeOut(duration: 0.18)) {
                    activePanel = activePanel == .print ? nil : .print
                }
            } label: { railItem("冲印", symbol: "drop.fill", selected: activePanel == .print) }
                .buttonStyle(.plain)
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

    @ViewBuilder
    private func panel(_ item: Panel) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(item.rawValue).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button { withAnimation(.easeOut(duration: 0.16)) { activePanel = nil } } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 17)).foregroundStyle(.white.opacity(0.65))
                }.buttonStyle(.plain)
            }.padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 9) {
                    switch item {
                    case .film: filmControls
                    case .exposure: exposureControls
                    case .texture: textureControls
                    case .print: printControls
                    }
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
                                Text(paper.name).font(.system(size: 10)).lineLimit(1)
                                    .padding(.horizontal, 9).frame(height: 27)
                                    .background(selected ? accent.opacity(0.22) : .white.opacity(0.07), in: Capsule())
                                    .overlay(Capsule().strokeBorder(selected ? accent : .white.opacity(0.1), lineWidth: 0.8))
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
        VStack(spacing: 7) {
            slider("曝光补偿", value: Binding(get: { model.recipe.exposureEV }, set: { v in model.change { $0.exposureEV = v } }), range: -3...3)
        }
    }

    private var textureControls: some View {
        VStack(spacing: 7) {
            slider("颗粒", value: Binding(get: { model.recipe.grain }, set: { v in model.change { $0.grain = v } }), range: 0...2)
            slider("光晕", value: Binding(get: { model.recipe.halation }, set: { v in model.change { $0.halation = v } }), range: 0...3)
            toggle("胶片边框", value: Binding(get: { model.recipe.filmEdge }, set: { on in model.change { $0.filmEdge = on } }))
        }
    }

    private var printControls: some View {
        VStack(spacing: 7) {
            if model.recipe.film.kind.usesPrintPaper {
                slider("冲印亮度", value: Binding(get: { model.recipe.printBrightness }, set: { v in model.change { $0.printBrightness = v } }), range: -2...2)
                slider("暖调", value: Binding(get: { model.recipe.warmth }, set: { v in model.change { $0.warmth = v } }), range: -1...1)
                slider("色调", value: Binding(get: { model.recipe.tint }, set: { v in model.change { $0.tint = v } }), range: -1...1)
            }
            toggle("日期印", value: Binding(get: { model.recipe.dateStamp }, set: { on in model.change { $0.dateStamp = on } }))
        }
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
