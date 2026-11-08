import SwiftUI
import UIKit

/// The darkroom editor: one photo held open in the engine while films,
/// papers and print settings are tried on it. The preview sits like a print
/// on the table; the film chooser is pinned under it and only the print
/// controls scroll.
struct EditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ObservedObject var editor: EditorModel

    @GestureState private var showingOriginal = false
    @State private var sent = false
    @State private var showHint = true

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                header
                preview
                    .frame(height: max(200, geo.size.height * 0.4))
                    .padding(.horizontal, 24)
                    .padding(.top, 4)
                    .padding(.bottom, 12)
                EditorFilmSection(editor: editor)
                    .padding(.bottom, 8)
                    .disabled(sent)
                controls
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await editor.load(library: model.library) }
        .task {
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            withAnimation(.easeOut(duration: 0.5)) { showHint = false }
        }
        .onDisappear { editor.close() }
    }

    // MARK: header

    private var header: some View {
        ZStack {
            VStack(spacing: 1) {
                Text("暗房")
                    .font(AppFont.ui(17, .semibold))
                    .foregroundStyle(Theme.text)
                if editor.isLoading {
                    Text("显影中")
                        .font(AppFont.ui(11))
                        .foregroundStyle(Theme.secondary)
                        .transition(.opacity)
                }
            }
            .animation(Motion.fade, value: editor.isLoading)

            HStack(spacing: 12) {
                Button {
                    dismiss()
                } label: {
                    Text("取消")
                        .font(AppFont.ui(15))
                        .foregroundStyle(Theme.secondary)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)

                Spacer(minLength: 0)

                Button {
                    develop()
                } label: {
                    PrimaryCapsule(title: "冲洗", systemImage: "drop.fill", isEnabled: editor.canDevelop, height: 34)
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
                .disabled(!editor.canDevelop || sent)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .frame(height: 50)
    }

    // MARK: preview

    private var preview: some View {
        ZStack {
            if editor.isLoading {
                DevelopingLoader(original: editor.original)
                    .transition(.opacity)
            } else if editor.preview == nil, let error = editor.error {
                errorCard(error)
                    .transition(.opacity)
            } else {
                printView
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).updating($showingOriginal) { _, state, _ in state = true },
                 including: editor.preview != nil && editor.original != nil ? .all : .subviews)
        .overlay(alignment: .top) {
            RenderingBar(active: editor.isRendering && !editor.isLoading)
                .padding(.horizontal, 40)
        }
        .overlay(alignment: .top) {
            if showingOriginal {
                Text("原图")
                    .font(AppFont.ui(13, .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.6)))
                    .padding(.top, 12)
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
            }
        }
        .overlay(alignment: .bottom) {
            if let error = editor.error, editor.preview != nil {
                Text(error)
                    .font(AppFont.ui(12))
                    .foregroundStyle(Theme.text)
                    .lineLimit(2)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(Theme.danger.opacity(0.85)))
                    .padding(.bottom, 10)
                    .transition(.opacity)
            } else if showHint && editor.preview != nil && !showingOriginal {
                Text("按住对比原图")
                    .font(AppFont.ui(12))
                    .foregroundStyle(Theme.text.opacity(0.85))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.black.opacity(0.5)))
                    .padding(.bottom, 10)
                    .transition(.opacity)
            }
        }
        .scaleEffect(sent ? (reduceMotion ? 1 : 0.84) : 1)
        .offset(y: sent && !reduceMotion ? 60 : 0)
        .opacity(sent ? 0 : 1)
        .animation(.easeOut(duration: 0.35), value: editor.isLoading)
        .animation(.easeOut(duration: 0.14), value: showingOriginal)
        .animation(Motion.fade, value: editor.error)
        .compatibleOnChange(of: showingOriginal) { _, on in if on { Haptics.softTap(0.4) } }
    }

    /// The preview as a print: its own aspect, small rounded corners, and a
    /// soft shadow cast by a static shape (so cross-fades don't re-render it).
    private var printView: some View {
        let aspect: CGFloat = editor.preview.map { $0.size.width / max(1, $0.size.height) } ?? (2.0 / 3.0)
        let corner = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return ZStack {
            Color.black
            CrossfadeImage(image: editor.preview, duration: 0.18)
            if showingOriginal, let original = editor.original {
                ZStack {
                    Color.black
                    Image(uiImage: original)
                        .resizable()
                        .scaledToFit()
                }
                .transition(.opacity)
            }
        }
        .aspectRatio(aspect, contentMode: .fit)
        .clipShape(corner)
        .background(
            corner
                .fill(Color.black)
                .shadow(color: .black.opacity(0.55), radius: 14, y: 8)
        )
        .animation(.easeOut(duration: 0.2), value: aspect)
    }

    private func errorCard(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.lcd)
            Text("这张照片没能显影")
                .font(AppFont.ui(17, .semibold))
                .foregroundStyle(Theme.text)
            Text(message)
                .font(AppFont.ui(13))
                .foregroundStyle(Theme.secondary)
                .multilineTextAlignment(.center)
            Button {
                Task { await editor.load(library: model.library) }
            } label: {
                PrimaryCapsule(title: "再试一次", systemImage: "arrow.clockwise", height: 34)
            }
            .buttonStyle(.pressable)
            .padding(.top, 4)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .surfaceCard(radius: 18)
    }

    // MARK: controls

    private var controls: some View {
        ScrollView {
            RecipeControls(recipe: $editor.recipe, showsExposure: true)
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 30)
        }
        .scrollIndicators(.hidden)
        .background(
            UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                .fill(Theme.surface.opacity(0.6))
                .overlay(
                    UnevenRoundedRectangle(topLeadingRadius: 26, topTrailingRadius: 26, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                )
                .ignoresSafeArea(edges: .bottom)
        )
        .disabled(sent)
    }

    // MARK: develop

    private func develop() {
        guard editor.canDevelop, !sent else { return }
        Haptics.filmAdvance()
        editor.develop(into: model.darkroom, frameNumber: model.frameNumber)
        withAnimation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.45, dampingFraction: 0.86)) {
            sent = true
        }
        model.show("已送进暗房冲洗")
        Task {
            try? await Task.sleep(nanoseconds: 380_000_000)
            dismiss()
        }
    }
}

// MARK: - Film section

/// The editor's film chooser; the only part of the editor that reads the
/// recipe's film, so slider drags don't re-evaluate the whole screen.
struct EditorFilmSection: View {
    let editor: EditorModel

    var body: some View {
        let editor = self.editor
        FilmPicker(style: .compact, committedID: editor.recipe.filmID,
                   onCommit: { id in
                       guard id != editor.recipe.filmID else { return }
                       editor.recipe.selectFilm(id)
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
