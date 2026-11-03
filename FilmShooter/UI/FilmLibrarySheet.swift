import SwiftUI
import UIKit

enum FilmLibraryFilter: Hashable {
    case favorites
    case all
    case kind(FilmKind)

    static let ordered: [FilmLibraryFilter] = {
        var list: [FilmLibraryFilter] = [.favorites, .all]
        for kind in FilmKind.allCases { list.append(FilmLibraryFilter.kind(kind)) }
        return list
    }()

    var title: String {
        switch self {
        case .favorites: return "常用"
        case .all: return "全部"
        case .kind(let k): return k.title
        }
    }
}

/// "胶片库": every stock as a card with a live preview of the current scene
/// through that film, favourites, and a filter bar.
struct FilmLibrarySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    @State private var filter: FilmLibraryFilter
    @State private var previews: [String: UIImage] = [:]
    @State private var isClosing = false

    @Namespace private var filterNamespace

    init(initialFilter: FilmLibraryFilter = .all) {
        _filter = State(initialValue: initialFilter)
    }

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            header
            filterBar
                .padding(.bottom, 4)
            ScrollView {
                content
                    .id(filter)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 28)
            }
            .scrollIndicators(.hidden)
        }
        .task { await refreshPreviews() }
        .presentationDetents([.fraction(0.62), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(28)
        .presentationBackground {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Theme.background.opacity(0.55)
            }
        }
    }

    // MARK: parts

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("胶片库")
                    .font(AppFont.ui(22, .semibold))
                    .foregroundStyle(Theme.text)
                Text("\(FilmCatalog.films.count) 款胶片 · 实时取景预览")
                    .font(AppFont.ui(12))
                    .foregroundStyle(Theme.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                RoundIcon(systemName: "xmark", size: 32, iconSize: 12, tint: Theme.secondary, fill: Theme.surfaceHigh)
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("关闭"))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 12)
    }

    private var filterBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 6) {
                ForEach(FilmLibraryFilter.ordered, id: \.self) { f in
                    let selected = f == filter
                    Button {
                        guard f != filter else { return }
                        Haptics.selection()
                        withAnimation(Motion.snappy) { filter = f }
                    } label: {
                        HStack(spacing: 4) {
                            if f == .favorites {
                                Image(systemName: "star.fill").font(.system(size: 10, weight: .semibold))
                            }
                            Text(f.title).font(AppFont.ui(13, selected ? .semibold : .medium))
                        }
                        .foregroundStyle(selected ? Theme.background : Theme.text.opacity(0.85))
                        .padding(.horizontal, 13)
                        .padding(.vertical, 7)
                        .background {
                            if selected {
                                Capsule().fill(Theme.accent)
                                    .matchedGeometryEffect(id: "filter", in: filterNamespace)
                            } else {
                                Capsule().fill(Color.white.opacity(0.07))
                            }
                        }
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.pressable(scale: 0.95))
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollIndicators(.hidden)
    }

    @ViewBuilder
    private var content: some View {
        switch filter {
        case .favorites:
            let favorites = model.favoriteFilms
            let favoriteIDs = Set(favorites.map(\.id))
            let recent = model.recentFilms.filter { !favoriteIDs.contains($0.id) }
            VStack(alignment: .leading, spacing: 18) {
                if favorites.isEmpty {
                    emptyFavorites
                } else {
                    grid(favorites, startIndex: 0)
                }
                if !recent.isEmpty {
                    Text("最近使用")
                        .font(AppFont.ui(12, .semibold))
                        .tracking(1)
                        .foregroundStyle(Theme.secondary)
                        .padding(.top, 4)
                    grid(recent, startIndex: favorites.count)
                }
            }
        case .all:
            grid(FilmCatalog.films, startIndex: 0)
        case .kind(let kind):
            grid(FilmCatalog.films(of: kind), startIndex: 0)
        }
    }

    private func grid(_ films: [FilmStock], startIndex: Int) -> some View {
        let selectedID = model.recipe.filmID
        return LazyVGrid(columns: columns, spacing: 16) {
            ForEach(Array(films.enumerated()), id: \.element.id) { index, film in
                FilmLibraryCard(film: film,
                                preview: previews[film.id],
                                isSelected: film.id == selectedID,
                                isFavorite: model.isFavorite(film.id),
                                index: startIndex + index,
                                onSelect: { select(film) },
                                onToggleFavorite: {
                                    Haptics.softTap()
                                    withAnimation(Motion.snappy) { model.toggleFavorite(film.id) }
                                })
            }
        }
    }

    private var emptyFavorites: some View {
        VStack(spacing: 10) {
            Image(systemName: "star")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(Theme.accent)
            Text("还没有常用胶片")
                .font(AppFont.ui(15, .semibold))
                .foregroundStyle(Theme.text)
            Text("点卡片右上角的星标，把喜欢的胶片收进这里")
                .font(AppFont.ui(12))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .surfaceCard(radius: 18)
    }

    // MARK: actions

    private func select(_ film: FilmStock) {
        guard !isClosing else { return }
        isClosing = true
        Haptics.selection()
        withAnimation(Motion.standard) { model.selectFilm(film.id) }
        Task {
            try? await Task.sleep(nanoseconds: 220_000_000)
            dismiss()
        }
    }

    /// Live previews: now, then every 1.5 s while the sheet is open.
    private func refreshPreviews() async {
        while !Task.isCancelled {
            let fresh = await model.filmPreviews()
            if !fresh.isEmpty {
                previews.merge(fresh) { _, new in new }
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
}

// MARK: - Card

struct FilmLibraryCard: View {
    let film: FilmStock
    let preview: UIImage?
    let isSelected: Bool
    let isFavorite: Bool
    let index: Int
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                picture
                VStack(alignment: .leading, spacing: 2) {
                    Text(film.name)
                        .font(AppFont.ui(13, .semibold))
                        .foregroundStyle(isSelected ? Theme.accent : Theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                    HStack(spacing: 4) {
                        Text("ISO \(film.iso)")
                            .font(AppFont.mono(9.5, .medium))
                            .foregroundStyle(Theme.text.opacity(0.75))
                        Text(film.kind.shortTitle)
                            .font(AppFont.mono(8.5, .semibold))
                            .foregroundStyle(Theme.secondary)
                    }
                    Text(film.tagline)
                        .font(AppFont.ui(10))
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 2)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable(scale: 0.96))
        .overlay(alignment: .topTrailing) { star }
        .contextMenu {
            Button(action: onSelect) {
                Label("使用这款胶片", systemImage: "checkmark.circle")
            }
            Button(action: onToggleFavorite) {
                Label(isFavorite ? "移出常用" : "加入常用", systemImage: isFavorite ? "star.slash" : "star")
            }
        } preview: {
            contextPreview
        }
        .opacity(shown ? 1 : 0)
        .offset(y: shown || reduceMotion ? 0 : 14)
        .onAppear {
            guard !shown else { return }
            let delay = reduceMotion ? 0 : Double(min(index, 12)) * 0.025
            withAnimation(Motion.standard.delay(delay)) { shown = true }
        }
    }

    private var picture: some View {
        Color.clear
            .aspectRatio(0.8, contentMode: .fit)
            .overlay {
                ZStack {
                    LinearGradient(colors: [film.body.opacity(0.28), film.band.opacity(0.16)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    if let preview {
                        Image(uiImage: preview)
                            .resizable()
                            .scaledToFill()
                            .transition(.opacity)
                    } else {
                        FilmCanister(film: film, height: 40)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.35), value: preview == nil)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(isSelected ? Theme.accent : Theme.hairline, lineWidth: isSelected ? 2 : 1)
            }
            .overlay(alignment: .bottomLeading) {
                if isSelected {
                    HStack(spacing: 4) {
                        Circle().fill(Theme.accent).frame(width: 5, height: 5)
                        Text("使用中").font(AppFont.ui(9.5, .semibold))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.black.opacity(0.55)))
                    .padding(6)
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .animation(Motion.snappy, value: isSelected)
    }

    private var star: some View {
        Button(action: onToggleFavorite) {
            Image(systemName: isFavorite ? "star.fill" : "star")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(isFavorite ? Theme.accent : Color.white.opacity(0.85))
                .symbolEffect(.bounce, value: isFavorite)
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.black.opacity(0.42)))
                .contentShape(Circle())
        }
        .buttonStyle(.pressable(scale: 0.85))
        .padding(5)
        .accessibilityLabel(Text(isFavorite ? "移出常用" : "加入常用"))
    }

    private var contextPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            ZStack {
                LinearGradient(colors: [film.body.opacity(0.3), film.band.opacity(0.2)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFill()
                } else {
                    FilmCanister(film: film, height: 90)
                }
            }
            .frame(width: 260, height: 300)
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(film.displayName).font(AppFont.ui(17, .semibold)).foregroundStyle(Theme.text)
                Text("\(film.isoLabel) · \(film.kind.title)").font(AppFont.mono(11)).foregroundStyle(Theme.accent)
                Text(film.tagline).font(AppFont.ui(13)).foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 4)
        }
        .padding(14)
        .background(Theme.surface)
    }
}
