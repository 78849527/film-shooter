import SwiftUI

/// The contact sheet: frames in the developing tray on top, then every print
/// as a square crop. Opens from the gallery button with a zoom transition;
/// each print opens the same way into the detail pager.
struct GalleryView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var opensFirstPhoto: Bool = false

    @Namespace private var namespace
    @State private var openedID: UUID?
    @State private var currentID: UUID?
    @State private var pendingDelete: DevelopedPhoto?

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 3)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    VStack(spacing: 0) {
                        let jobs = model.darkroom.jobs
                        if !jobs.isEmpty {
                            DevelopingTray(jobs: jobs)
                                .padding(.bottom, 14)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        let photos = model.library.photos
                        if photos.isEmpty {
                            if jobs.isEmpty {
                                EmptyRollView()
                                    .padding(.top, 70)
                                    .transition(.opacity)
                            }
                        } else {
                            grid(photos)
                        }
                    }
                    .animation(Motion.standard, value: model.darkroom.jobs.map(\.id))
                    .animation(Motion.standard, value: model.library.photos.map(\.id))
                }
                .scrollIndicators(.hidden)
            }
            .background(Theme.background.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(item: $openedID) { id in
                PhotoDetailView(startID: id, currentID: $currentID)
                    .navigationTransition(.zoom(sourceID: currentID ?? id, in: namespace))
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
        .task {
            guard opensFirstPhoto else { return }
            var waited = 0
            while model.library.photos.isEmpty && waited < 200 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            // Let the cover's zoom transition finish before pushing.
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let first = model.library.photos.first {
                currentID = first.id
                openedID = first.id
            }
        }
    }

    // MARK: parts

    private var header: some View {
        let count = model.library.photos.count
        return HStack(alignment: .center, spacing: 12) {
            Button {
                dismiss()
            } label: {
                RoundIcon(systemName: "chevron.down", size: 36, iconSize: 14, fill: Theme.surface)
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
                    .contentTransition(.numericText(value: Double(count)))
            }
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(
            LinearGradient(colors: [Theme.background, Theme.background.opacity(0.92), Theme.background.opacity(0)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea(edges: .top)
        )
        .animation(Motion.snappy, value: count)
    }

    private func grid(_ photos: [DevelopedPhoto]) -> some View {
        LazyVGrid(columns: columns, spacing: 2) {
            ForEach(photos) { photo in
                Button {
                    Haptics.tap()
                    currentID = photo.id
                    openedID = photo.id
                } label: {
                    ContactCell(photo: photo)
                }
                .buttonStyle(.pressable(scale: 0.97))
                .matchedTransitionSource(id: photo.id, in: namespace)
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
                .transition(.scale(scale: 0.9).combined(with: .opacity))
            }
        }
    }
}

// MARK: - Cell

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
                        .font(AppFont.mono(9, .semibold))
                        .foregroundStyle(Theme.lcd)
                    Text(photo.film.name)
                        .font(AppFont.ui(9, .medium))
                        .foregroundStyle(Color.white.opacity(0.88))
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

// MARK: - Developing tray

/// Frames still in the darkroom: negatives turning into prints, with progress;
/// failed ones offer retry / remove.
struct DevelopingTray: View {
    @Environment(AppModel.self) private var model
    let jobs: [DevelopJob]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle().fill(Theme.lcd).frame(width: 6, height: 6)
                    .phaseAnimator([0.3, 1.0]) { content, phase in
                        content.opacity(phase)
                    } animation: { _ in
                        .easeInOut(duration: 0.8)
                    }
                Text("暗房 · 正在冲洗 \(model.darkroom.pendingCount) 张")
                    .font(AppFont.ui(12, .semibold))
                    .tracking(0.5)
                    .foregroundStyle(Theme.secondary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal) {
                HStack(spacing: 10) {
                    ForEach(jobs) { job in
                        TrayCard(job: job)
                            .transition(.scale(scale: 0.85).combined(with: .opacity))
                    }
                }
                .padding(.horizontal, 16)
            }
            .scrollIndicators(.hidden)
        }
    }
}

struct TrayCard: View {
    @Environment(AppModel.self) private var model
    let job: DevelopJob

    var body: some View {
        let failure: String? = {
            if case .failed(let m) = job.phase { return m }
            return nil
        }()
        VStack(alignment: .leading, spacing: 6) {
            DevelopingJobImage(job: job) { progress in
                ZStack {
                    if job.phase == .developing {
                        ProgressBorder(progress: progress, cornerRadius: 10, lineWidth: 2.5)
                    }
                    if failure != nil {
                        Color.black.opacity(0.5)
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 20))
                            .foregroundStyle(Theme.danger)
                    }
                }
            }
            .frame(width: 100, height: 100)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))

            if let failure {
                Text(failure)
                    .font(AppFont.ui(10))
                    .foregroundStyle(Theme.danger)
                    .lineLimit(1)
                    .frame(width: 100, alignment: .leading)
                HStack(spacing: 6) {
                    Button {
                        Haptics.tap()
                        withAnimation(Motion.standard) { model.darkroom.retry(job) }
                    } label: {
                        Text("重试")
                            .font(AppFont.ui(11, .semibold))
                            .foregroundStyle(Theme.background)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Theme.accent))
                    }
                    Button {
                        Haptics.tap()
                        withAnimation(Motion.standard) { model.darkroom.dismissFailed(job) }
                    } label: {
                        Text("移除")
                            .font(AppFont.ui(11, .semibold))
                            .foregroundStyle(Theme.text)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Theme.surfaceHigh))
                    }
                }
                .buttonStyle(.pressable)
                .frame(width: 100)
            } else {
                TimelineView(.animation(minimumInterval: 0.25, paused: job.phase != .developing)) { context in
                    let p = DevelopProgress.estimate(job, now: context.date)
                    HStack(spacing: 4) {
                        Text(job.phase == .developing ? "显影中" : "排队中")
                            .font(AppFont.ui(11, .medium))
                            .foregroundStyle(Theme.text.opacity(0.85))
                        if job.phase == .developing {
                            Text("\(Int(p * 100))%")
                                .font(AppFont.mono(10, .medium))
                                .foregroundStyle(Theme.accent)
                        }
                    }
                }
                Text(job.recipe.film.name)
                    .font(AppFont.ui(10))
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
        .frame(width: 100, alignment: .leading)
    }
}

// MARK: - Empty state

/// A strip of unexposed film and a gentle prompt.
struct EmptyRollView: View {
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
                            .foregroundStyle(Theme.accent.opacity(0.55)),
                         at: CGPoint(x: size.width * 0.28, y: rail / 2 + 0.5))
        }
    }
}
