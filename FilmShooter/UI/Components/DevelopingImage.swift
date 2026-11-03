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
        .onChange(of: image.map { ObjectIdentifier($0) }) { _, _ in
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
        } completion: {
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

/// A job's picture with its live progress (only the developing job ticks;
/// queued and failed jobs are static, so their timelines are paused).
struct DevelopingJobImage<Overlay: View>: View {
    let job: DevelopJob
    @ViewBuilder var overlay: (Double) -> Overlay

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: job.phase != .developing)) { context in
            let p = DevelopProgress.estimate(job, now: context.date)
            ZStack {
                NegativePositive(image: job.preview, progress: p,
                                 isMonochrome: job.recipe.film.kind == .blackWhite)
                overlay(p)
            }
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

/// A developed print's cached contact-sheet thumbnail.
struct LibraryThumbnail: View {
    @Environment(AppModel.self) private var model
    let photo: DevelopedPhoto
    var contentMode: ContentMode = .fill

    var body: some View {
        if let image = model.library.thumbnail(for: photo) {
            Image(uiImage: image)
                .resizable()
                .aspectRatio(contentMode: contentMode)
        } else {
            Theme.surfaceHigh
        }
    }
}
