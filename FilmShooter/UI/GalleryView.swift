import SwiftUI

/// The contact sheet: frames still in the darkroom as the first cells (a
/// negative turning into a print, traced by a progress line), then every print
/// as a square crop. Opens from the gallery button with a zoom transition;
/// each print opens the same way into the detail pager.
struct GalleryView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss

    @Namespace private var namespace
    /// The navigation path (photo ids). Initialised with the photo to open,
    /// so a requested push is part of the first render -- no timing involved.
    @State private var path: [UUID]
    @State private var currentID: UUID?
    @State private var pendingDelete: DevelopedPhoto?
    @State private var showImporter = false
    @State private var editor: EditorModel?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    init(initialPhotoID: UUID? = nil) {
        _path = State(initialValue: initialPhotoID.map { [$0] } ?? [])
        _currentID = State(initialValue: initialPhotoID)
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                ScrollView {
                    content
                        .padding(.bottom, 24)
                }
                .scrollIndicators(.hidden)
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: UUID.self) { id in
                PhotoDetailView(startID: id, currentID: $currentID)
                    .compatibleDetailTransition(id: currentID ?? id, namespace: namespace)
            }
        }
        .overlay { BannerOverlay(topPadding: 8) }
        .confirmationDialog("删除这张照片？", isPresented: Binding(
            get: { pendingDelete != nil },
            set: { if !$0 { pendingDelete = nil } }), titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                if let photo = pendingDelete {
                    Haptics.warning()
                    withAnimation(Motion.standard) { model.library.delete(photo) }
                }
                pendingDelete = nil
            }
            Button("取消", role: .cancel) { pendingDelete = nil }
        } message: {
            Text("冲好的照片和保留的原图都会被删除，无法恢复。")
        }
        .photoImporter(isPresented: $showImporter) { newEditor in
            editor = newEditor
        }
        .fullScreenCover(item: $editor) { editor in
            EditorView(editor: editor)
                .environmentObject(model)
        }
        .onAppear {
            ScreenshotMode.log("gallery appeared, path \(path.count), \(model.library.photos.count) photos")
        }
        .compatibleOnChange(of: path) { old, new in
            ScreenshotMode.log("gallery path \(old.count) -> \(new.count)")
        }
    }

    // MARK: parts

    private var header: some View {
        let count = model.library.photos.count
        return HStack(alignment: .center, spacing: 10) {
            Button {
                dismiss()
            } label: {
                RoundIcon(systemName: "chevron.down", size: 36, iconSize: 14, fill: Theme.surface)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            .accessibilityLabel(Text("返回相机"))

            VStack(alignment: .leading, spacing: 1) {
                Text("底片册")
                    .font(AppFont.ui(20, .semibold))
                    .foregroundStyle(Theme.text)
                Text(count == 0 ? "还没有照片" : "共 \(count) 张")
                    .font(AppFont.ui(12))
                    .foregroundStyle(Theme.secondary)
                    .compatibleNumericText(Double(count))
            }
            Spacer()
            Button {
                showImporter = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 13, weight: .semibold))
                    Text("导入冲洗")
                        .font(AppFont.ui(13, .semibold))
                }
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 13)
                .frame(height: 34)
                .background(Capsule().fill(Theme.surfaceHigh))
                .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
        }
        .padding(.leading, 8)
        .padding(.trailing, 16)
        .padding(.top, 2)
        .padding(.bottom, 8)
        .background(
            Rectangle()
                .fill(.ultraThinMaterial)
                .overlay(Theme.background.opacity(0.6))
                .ignoresSafeArea(edges: .top)
        )
        .animation(Motion.snappy, value: count)
    }

    @ViewBuilder
    private var content: some View {
        let jobs = model.darkroom.jobs
        let photos = model.library.photos
        if jobs.isEmpty && photos.isEmpty {
            EmptyRollView(onImport: { showImporter = true })
                .padding(.top, 70)
                .transition(.opacity)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                if !jobs.isEmpty {
                    darkroomLine
                        .transition(.opacity)
                }
                LazyVGrid(columns: columns, spacing: 2) {
                    ForEach(jobs) { job in
                        JobCell(job: job)
                            .transition(.opacity)
                    }
                    ForEach(photos) { photo in
                        photoCell(photo)
                            .transition(.opacity)
                    }
                }
            }
            .animation(Motion.standard, value: jobs.map(\.id))
            .animation(Motion.standard, value: photos.map(\.id))
        }
    }

    private var darkroomLine: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(Theme.lcd)
                .frame(width: 6, height: 6)
                .compatiblePulse([0.3, 1.0], duration: 0.8)
            Text("暗房 · 正在冲洗 \(model.darkroom.pendingCount) 张")
                .font(AppFont.ui(13, .medium))
                .foregroundStyle(Theme.secondary)
                .compatibleNumericText(Double(model.darkroom.pendingCount))
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func photoCell(_ photo: DevelopedPhoto) -> some View {
        Button {
            currentID = photo.id
            ScreenshotMode.log("gallery: open photo \(photo.id)")
            path.append(photo.id)
        } label: {
            ContactCell(photo: photo)
        }
        .buttonStyle(.pressable(scale: 0.97))
        .compatibleMatchedTransitionSource(id: photo.id, in: namespace)
        .contextMenu {
            ShareLink(item: model.library.fileURL(for: photo)) {
                Label("分享", systemImage: "square.and.arrow.up")
            }
            Button(role: .destructive) {
                pendingDelete = photo
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
    }
}

// MARK: - Cells

struct ContactCell: View {
    let photo: DevelopedPhoto

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LibraryThumbnail(photo: photo)
            }
            .clipped()
            .overlay(alignment: .bottom) {
                HStack(spacing: 4) {
                    Text(String(format: "%02ld", photo.frameNumber))
                        .font(AppFont.mono(10, .semibold))
                        .foregroundStyle(Theme.lcd)
                    Text(photo.film.name)
                        .font(AppFont.ui(11, .medium))
                        .foregroundStyle(Color.white.opacity(0.9))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 6)
                .padding(.top, 14)
                .padding(.bottom, 5)
                .background(LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                                           startPoint: .top, endPoint: .bottom))
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("第 \(photo.frameNumber) 张，\(photo.film.displayName)"))
    }
}

/// A frame still in the darkroom, as a contact-sheet cell: the negative
/// turning into the print, traced by a progress line; retry / remove when it
/// failed.
struct JobCell: View {
    @EnvironmentObject private var model: AppModel
    let job: DevelopJob

    var body: some View {
        let failure: String? = {
            if case .failed(let m) = job.phase { return m }
            return nil
        }()
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                DevelopingJobImage(job: job) { progress in
                    if job.phase == .developing {
                        ProgressBorder(progress: progress, cornerRadius: 0, lineWidth: 3)
                    }
                }
            }
            .clipped()
            .overlay(alignment: .bottom) {
                if failure == nil {
                    HStack(spacing: 4) {
                        Text(job.phase == .developing ? "显影中" : "排队中")
                            .font(AppFont.ui(11, .medium))
                            .foregroundStyle(Color.white.opacity(0.9))
                        Text(job.recipe.film.name)
                            .font(AppFont.ui(11))
                            .foregroundStyle(Color.white.opacity(0.7))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 6)
                    .padding(.top, 14)
                    .padding(.bottom, 5)
                    .background(LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.55)],
                                               startPoint: .top, endPoint: .bottom))
                }
            }
            .overlay {
                if let failure {
                    ZStack {
                        Color.black.opacity(0.6)
                        VStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.system(size: 17))
                                .foregroundStyle(Theme.danger)
                            Text(failure)
                                .font(AppFont.ui(11))
                                .foregroundStyle(Theme.text.opacity(0.85))
                                .lineLimit(2)
                                .multilineTextAlignment(.center)
                            HStack(spacing: 6) {
                                Button {
                                    Haptics.tap()
                                    withAnimation(Motion.standard) { model.darkroom.retry(job) }
                                } label: {
                                    Text("重试")
                                        .font(AppFont.ui(11, .semibold))
                                        .foregroundStyle(Theme.background)
                                        .padding(.horizontal, 10)
                                        .frame(height: 26)
                                        .background(Capsule().fill(Theme.accent))
                                }
                                Button {
                                    Haptics.tap()
                                    withAnimation(Motion.standard) { model.darkroom.dismissFailed(job) }
                                } label: {
                                    Text("移除")
                                        .font(AppFont.ui(11, .semibold))
                                        .foregroundStyle(Theme.text)
                                        .padding(.horizontal, 10)
                                        .frame(height: 26)
                                        .background(Capsule().fill(Color.white.opacity(0.14)))
                                }
                            }
                            .buttonStyle(.pressable)
                        }
                        .padding(8)
                    }
                    .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: failure)
            .accessibilityElement(children: .contain)
    }
}

// MARK: - Empty state

/// A strip of unexposed film and a gentle prompt.
struct EmptyRollView: View {
    var onImport: (() -> Void)? = nil

    @State private var drift = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 22) {
            FilmStripArt()
                .frame(width: 250, height: 92)
                .rotationEffect(.degrees(-6))
                .offset(y: drift ? -4 : 4)
            VStack(spacing: 8) {
                Text("还没有冲洗好的照片")
                    .font(AppFont.ui(17, .semibold))
                    .foregroundStyle(Theme.text)
                Text("按下快门，照片会在暗房里慢慢显影")
                    .font(AppFont.ui(13))
                    .foregroundStyle(Theme.secondary)
            }
            if let onImport {
                Button(action: onImport) {
                    HStack(spacing: 5) {
                        Image(systemName: "photo.badge.plus")
                            .font(.system(size: 13, weight: .semibold))
                        Text("从相册导入一张")
                            .font(AppFont.ui(13, .semibold))
                    }
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 16)
                    .frame(height: 36)
                    .background(Capsule().fill(Theme.surfaceHigh))
                    .overlay(Capsule().strokeBorder(Theme.hairlineStrong, lineWidth: 1))
                }
                .buttonStyle(.pressable)
            }
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.6).repeatForever(autoreverses: true)) { drift = true }
        }
    }
}

/// A short length of 135 film: rebate, sprocket holes, three empty frames.
struct FilmStripArt: View {
    var body: some View {
        Canvas { context, size in
            let base = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 4)
            context.fill(base, with: .color(Color(hex: 0x2A1E16)))
            let holeH = size.height * 0.11
            let holeW = holeH * 1.3
            let rail = size.height * 0.17
            var x: CGFloat = holeW * 0.6
            while x < size.width - holeW {
                for y in [rail / 2 - holeH / 2, size.height - rail / 2 - holeH / 2] {
                    let hole = Path(roundedRect: CGRect(x: x, y: y, width: holeW, height: holeH), cornerRadius: holeH * 0.25)
                    context.fill(hole, with: .color(Theme.background))
                }
                x += holeW * 2.1
            }
            let frameH = size.height - rail * 2 - 4
            let frameW = (size.width - 4 * 6) / 3
            for i in 0..<3 {
                let rect = CGRect(x: 6 + CGFloat(i) * (frameW + 6), y: rail + 2, width: frameW, height: frameH)
                let frame = Path(roundedRect: rect, cornerRadius: 2)
                context.fill(frame, with: .color(Color(hex: 0x3B2B20)))
                context.stroke(frame, with: .color(Theme.accent.opacity(0.18)), lineWidth: 0.6)
            }
            context.draw(Text("FILMSHOOTER  135").font(.system(size: 6, weight: .bold, design: .monospaced))
                            .foregroundColor(Theme.accent.opacity(0.55)),
                         at: CGPoint(x: size.width * 0.28, y: rail / 2 + 0.5))
        }
    }
}
