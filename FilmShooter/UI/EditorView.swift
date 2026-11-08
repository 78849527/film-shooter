import SwiftUI
import UIKit

/// Main-app darkroom. The image occupies the entire editor canvas; the
/// carousel, paper and print parameters now live in optional side drawers.
/// This keeps the spectral editor model and its revision-safe render pipeline
/// unchanged while making portrait and landscape photos much larger.
struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ObservedObject var editor: EditorModel

    @State private var sent = false
    @State private var isSharing = false
    @State private var shareRequest: DarkroomShareRequest?
    @State private var editingPriorityActive = false

    var body: some View {
        DarkroomWorkspace(editor: editor,
                          settings: model.settings,
                          sent: sent,
                          isSharing: isSharing,
                          onBack: { dismiss() },
                          onDevelop: develop,
                          onShare: developAndShare)
            .background(Color.black.ignoresSafeArea())
            .sheet(item: $shareRequest, onDismiss: { dismiss() }) { request in
                DarkroomActivitySheet(items: [request.url])
            }
            .onAppear {
                // This is the only full-screen view that allows landscape.
                // The camera and other root views remain portrait.
                EditorOrientation.begin()
            }
            .task {
                if !editingPriorityActive {
                    editingPriorityActive = true
                    model.beginPhotoEditing()
                }
                await editor.load(library: model.library)
            }
            .onDisappear {
                EditorOrientation.end()
                editor.close()
                if editingPriorityActive {
                    editingPriorityActive = false
                    model.endPhotoEditing()
                }
            }
    }

    private func develop() {
        guard editor.canDevelop, !sent else { return }
        Haptics.filmAdvance()
        editor.develop(into: model.darkroom, frameNumber: model.frameNumber)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) :
                      .spring(response: 0.45, dampingFraction: 0.86)) {
            sent = true
        }
        model.show("已送进暗房冲洗")
        Task {
            try? await Task.sleep(nanoseconds: 380_000_000)
            dismiss()
        }
    }

    /// Share the ACTUAL developed file, not a 1600px on-screen preview.
    /// Waiting on the exact job UUID avoids accidentally sharing a previous
    /// gallery image when another camera job finishes first.
    private func developAndShare() {
        guard editor.canDevelop, !sent else { return }
        Haptics.filmAdvance()
        let jobID = editor.develop(into: model.darkroom, frameNumber: model.frameNumber)
        sent = true
        isSharing = true

        Task {
            do {
                let photo = try await model.darkroom.waitForCompletion(of: jobID)
                let url = model.library.fileURL(for: photo)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                isSharing = false
                shareRequest = DarkroomShareRequest(url: url)
            } catch {
                isSharing = false
                model.show("冲洗并分享失败：\(error.localizedDescription)", seconds: 4)
                dismiss()
            }
        }
    }
}

/// The share sheet is presented after the darkroom confirms the exact
/// full-resolution print has been committed to the app's photo library.
private struct DarkroomShareRequest: Identifiable {
    let id = UUID()
    let url: URL
}

private struct DarkroomActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}


// MARK: - Film section

/// The editor's film chooser; the only part of the editor that reads the
/// recipe's film, so slider drags don't re-evaluate the whole screen.
struct EditorFilmSection: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        let editor = self.editor
        FilmPicker(style: .compact, groupedByKind: true, committedID: editor.recipe.filmID,
                   onCommit: { id in
                       editor.selectFilm(id)
                   }) {
            EmptyView()
        } trailing: {
            EmptyView()
        }
    }
}

// MARK: - Rendering bar

/// A thin amber light running along the top of the preview while rendering.
struct RenderingBar: View {
    let active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: !active)) { context in
            GeometryReader { geo in
                let period = 1.1
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: period) / period
                let w = geo.size.width * 0.35
                Capsule()
                    .fill(LinearGradient(colors: [Theme.accent.opacity(0), Theme.accent, Theme.accent.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: w, height: 2)
                    .offset(x: -w + (geo.size.width + w) * CGFloat(t))
            }
        }
        .frame(height: 2)
        .clipped()
        .opacity(active ? 1 : 0)
        .animation(.easeInOut(duration: 0.3), value: active)
        .allowsHitTesting(false)
    }
}

// MARK: - Loading

/// "显影中…": a darkroom tray under the safelight, the negative breathing up
/// out of the developer while a slow sheen passes over the liquid.
struct DevelopingLoader: View {
    let original: UIImage?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sweep = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x2B100C), Color(hex: 0x140706)],
                                     startPoint: .top, endPoint: .bottom))
            if let original {
                BreathingNegative(image: original)
                    .padding(28)
                    .transition(.opacity)
            }
            GeometryReader { geo in
                LinearGradient(colors: [Color.white.opacity(0), Color.white.opacity(0.07), Color.white.opacity(0)],
                               startPoint: .leading, endPoint: .trailing)
                    .frame(width: geo.size.width * 0.5)
                    .offset(x: sweep ? geo.size.width : -geo.size.width * 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            .allowsHitTesting(false)
            VStack {
                Spacer()
                HStack(spacing: 8) {
                    Circle()
                        .fill(Theme.lcd)
                        .frame(width: 6, height: 6)
                        .compatiblePulse([0.3, 1.0], duration: 0.7)
                    Text("显影中…")
                        .font(AppFont.ui(13, .medium))
                        .foregroundStyle(Theme.text.opacity(0.85))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.black.opacity(0.4)))
                .padding(.bottom, 16)
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.hairline, lineWidth: 1))
        .animation(.easeOut(duration: 0.5), value: original == nil)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: false)) { sweep = true }
        }
    }
}

struct BreathingNegative: View {
    let image: UIImage
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var up = false

    var body: some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .colorInvert()
            .colorMultiply(Theme.filmBase)
            .opacity(up ? 0.85 : 0.2)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            .onAppear {
                if reduceMotion {
                    up = true
                } else {
                    withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) { up = true }
                }
            }
    }
}
