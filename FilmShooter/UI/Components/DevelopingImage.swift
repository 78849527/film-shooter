import SwiftUI
import UIKit

// MARK: - Cross-fading image

/// Shows `image`; when it changes, the new picture fades in *over* the old one
/// (which stays fully opaque underneath until the fade ends), so successive
/// renders never dip through the background or flicker.
struct CrossfadeImage: View {
    let image: UIImage?
    var contentMode: ContentMode = .fit
    var duration: Double = 0.22

    private struct Layer: Identifiable {
        let id: Int
        let image: UIImage
    }

    @State private var layers: [Layer] = []
    @State private var counter = 0

    var body: some View {
        ZStack {
            ForEach(layers) { layer in
                Image(uiImage: layer.image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .onAppear {
            if layers.isEmpty, let image {
                layers = [Layer(id: 0, image: image)]
            }
        }
        .compatibleOnChange(of: image.map { ObjectIdentifier($0) }) { _, _ in
            push(image)
        }
    }

    private func push(_ new: UIImage?) {
        guard let new else {
            withAnimation(.easeOut(duration: duration)) { layers.removeAll() }
            return
        }
        counter += 1
        let layer = Layer(id: counter, image: new)
        withAnimation(.easeOut(duration: duration)) {
            layers.append(layer)
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            // The new picture is opaque now: drop what is underneath.
            layers.removeAll { $0.id < layer.id }
        }
    }
}

// MARK: - Negative -> positive

/// A frame in the developing tray: an inverted, orange-masked negative that
/// turns into the positive print as `progress` goes 0 -> 1.
struct NegativePositive: View {
    let image: UIImage?
    let progress: Double
    var isMonochrome: Bool = false

    var body: some View {
        // The print only starts to show once the negative has been seen.
        let t = LayoutMath.clamp((progress - 0.3) / 0.7, 0, 1)
        let reveal = t * t * (3 - 2 * t)
        ZStack {
            Theme.safelight
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .grayscale(isMonochrome ? 1 : 0)
                    .colorInvert()
                    .colorMultiply(isMonochrome ? Color(white: 0.9) : Theme.filmBase)
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
                    .grayscale(isMonochrome ? 1 : 0)
                    .opacity(reveal)
            }
        }
    }
}

// MARK: - Progress estimate

enum DevelopProgress {
    /// A smooth estimate from the job's start time and expected duration,
    /// held at 95 % until the print actually arrives.
    static func estimate(_ job: DevelopJob, now: Date) -> Double {
        guard job.phase == .developing, let start = job.startedAt else { return 0 }
        let t = max(0, now.timeIntervalSince(start)) / max(0.5, job.expectedSeconds)
        let eased = 1 - pow(1 - min(t, 1), 2.2)
        return min(0.95, 0.95 * eased)
    }
}

/// A job's picture with its progress. The progress is an animated state
/// (one long ease-out towards 95 % per development) rather than a timeline,
/// so the view is not re-evaluated every frame.
struct DevelopingJobImage<Overlay: View>: View {
    let job: DevelopJob
    @ViewBuilder var overlay: (Double) -> Overlay

    @State private var progress: Double
    @State private var animationTask: Task<Void, Never>?

    init(job: DevelopJob, @ViewBuilder overlay: @escaping (Double) -> Overlay) {
        self.job = job
        self.overlay = overlay
        _progress = State(initialValue: DevelopProgress.estimate(job, now: Date()))
    }

    var body: some View {
        ZStack {
            NegativePositive(image: job.preview, progress: progress,
                             isMonochrome: job.recipe.film.kind == .blackWhite)
            overlay(progress)
        }
        .onAppear { run() }
        .compatibleOnChange(of: job.phase) { _, _ in run() }
        .compatibleOnChange(of: job.startedAt) { _, _ in run() }
        .onDisappear { animationTask?.cancel() }
    }

    private func run() {
        animationTask?.cancel()
        let current = DevelopProgress.estimate(job, now: Date())
        var still = Transaction()
        still.disablesAnimations = true
        withTransaction(still) { progress = current }
        guard job.phase == .developing, let start = job.startedAt else { return }
        let remaining = max(0.4, job.expectedSeconds - Date().timeIntervalSince(start))
        animationTask = Task {
            // Let the current value render before animating away from it.
            try? await Task.sleep(nanoseconds: 20_000_000)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: remaining)) { progress = 0.95 }
        }
    }
}

/// A thin progress line traced around a rounded rectangle.
struct ProgressBorder: View {
    let progress: Double
    var cornerRadius: CGFloat
    var lineWidth: CGFloat = 2.5
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.black.opacity(0.35), lineWidth: lineWidth)
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
        }
        .padding(lineWidth / 2)
    }
}

/// A thin circular progress ring.
struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 2.5
    var color: Color = Theme.accent

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, progress))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

// MARK: - Library thumbnail

/// A developed print's contact-sheet thumbnail: from the memory cache when
/// it is there, otherwise decoded off the main thread and faded in.
struct LibraryThumbnail: View {
    @Environment(AppModel.self) private var model
    let photo: DevelopedPhoto
    var contentMode: ContentMode = .fill

    @State private var image: UIImage?

    var body: some View {
        let shown = image ?? model.library.cachedThumbnail(for: photo)
        ZStack {
            Theme.surfaceHigh
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .transition(.opacity)
            }
        }
        .task(id: photo.thumbName) {
            if let cached = model.library.cachedThumbnail(for: photo) {
                image = cached
                return
            }
            let loaded = await model.library.loadThumbnail(for: photo)
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.2)) { image = loaded }
        }
    }
}
