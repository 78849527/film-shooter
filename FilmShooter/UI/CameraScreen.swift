import SwiftUI

/// The root screen: top bar, viewfinder, film chooser, shutter deck. Holds only
/// presentation state; everything that changes often is read by subviews.
struct CameraScreen: View {
    @Environment(AppModel.self) private var model
    @Namespace private var namespace

    @State private var fx = ShutterFX()
    @State private var showGallery = false
    @State private var galleryOpensFirstPhoto = false
    @State private var showSettings = false
    @State private var settingsAtAbout = false
    @State private var showPrint = false
    @State private var showLibrary = false
    @State private var libraryFilter: FilmLibraryFilter = .all
    @State private var showAspect = false
    @State private var editor: EditorModel?
    @State private var permissionDismissed = false
    @State private var didOpenScene = false

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showAspectPicker: $showAspect, openSettings: {
                settingsAtAbout = false
                showSettings = true
            })

            ViewfinderPanel(fx: fx)
                .padding(.horizontal, 10)
                .padding(.top, 2)
                .frame(maxHeight: .infinity)

            EngineStatusCard()
                .padding(.top, 8)

            CameraFilmSection(openPrint: { showPrint = true }, openLibrary: openLibrary)
                .padding(.top, 12)

            ControlDeck(namespace: namespace, editor: $editor, openGallery: {
                galleryOpensFirstPhoto = false
                showGallery = true
            })
            .padding(.top, 8)
            .padding(.bottom, 6)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay { aspectOverlay }
        .overlay { BannerOverlay(topPadding: 58) }
        .overlay { PermissionGate(dismissed: $permissionDismissed) }
        .sheet(isPresented: $showPrint) {
            PrintSettingsSheet()
                .environment(model)
        }
        .sheet(isPresented: $showLibrary) {
            FilmLibrarySheet(initialFilter: libraryFilter)
                .environment(model)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(startAtAbout: settingsAtAbout)
                .environment(model)
        }
        .fullScreenCover(isPresented: $showGallery) {
            GalleryView(opensFirstPhoto: galleryOpensFirstPhoto)
                .navigationTransition(.zoom(sourceID: "gallery", in: namespace))
                .environment(model)
        }
        .fullScreenCover(item: $editor) { editor in
            EditorView(editor: editor)
                .environment(model)
        }
        .onAppear {
            let fx = self.fx
            model.camera.onShutter = { MainActor.assumeIsolated { fx.fire() } }
            Haptics.prepareShutter()
        }
        .onChange(of: editor != nil) { _, open in pauseCameraForEditor(open) }
        .task { await openScreenshotScene() }
    }

    // MARK: aspect picker

    private var aspectOverlay: some View {
        ZStack(alignment: .top) {
            if showAspect {
                Color.black.opacity(0.28)
                    .ignoresSafeArea()
                    .contentShape(Rectangle())
                    .onTapGesture { closeAspect() }
                    .transition(.opacity)
                AspectPickerPanel(close: closeAspect)
                    .padding(.top, 54)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
    }

    private func closeAspect() {
        withAnimation(Motion.standard) { showAspect = false }
    }

    // MARK: actions

    private func openLibrary() {
        libraryFilter = model.isFavorite(model.recipe.filmID) ? .favorites : .all
        showLibrary = true
    }

    /// The editor works the GPU hard; the hidden viewfinder should not compete.
    private func pauseCameraForEditor(_ open: Bool) {
        if open {
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                if editor != nil { model.camera.stop() }
            }
        } else {
            Task { await model.camera.start() }
        }
    }

    // MARK: screenshot scenes

    private func openScreenshotScene() async {
        guard let scene = ScreenshotMode.scene, !didOpenScene else { return }
        didOpenScene = true
        ScreenshotMode.log("open scene \(scene)")
        switch scene {
        case "camera-film":
            try? await Task.sleep(nanoseconds: 700_000_000)
            model.selectFilm("fujifilm_velvia_100")
        case "print":
            try? await Task.sleep(nanoseconds: 500_000_000)
            showPrint = true
        case "gallery", "detail":
            try? await Task.sleep(nanoseconds: 400_000_000)
            galleryOpensFirstPhoto = scene == "detail"
            showGallery = true
        case "editor":
            var waited = 0
            while model.engineState == .starting && waited < 150 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            guard let data = ScreenshotMode.sampleData() else {
                ScreenshotMode.log("editor: no sample image")
                return
            }
            editor = EditorModel(source: .imported(data: data, isRAW: false), recipe: model.recipe,
                                 outputLongEdge: model.settings.outputQuality.longEdge)
        case "settings":
            showSettings = true
        case "about":
            settingsAtAbout = true
            showSettings = true
        default:
            break
        }
    }
}

// MARK: - Engine status

/// Shown above the film chooser when the developing engine could not start
/// (the camera keeps working).
struct EngineStatusCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let message: String? = {
            if case .failed(let m) = model.engineState { return m }
            return nil
        }()
        VStack(spacing: 0) {
            if let message {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16))
                        .foregroundStyle(Theme.lcd)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("冲洗引擎启动失败")
                            .font(AppFont.ui(14, .semibold))
                            .foregroundStyle(Theme.text)
                        Text(message)
                            .font(AppFont.ui(11.5))
                            .foregroundStyle(Theme.secondary)
                            .lineLimit(2)
                    }
                    Spacer(minLength: 8)
                    Button {
                        Haptics.tap()
                        Task { await model.boot() }
                    } label: {
                        Text("重试")
                            .font(AppFont.ui(13, .semibold))
                            .foregroundStyle(Theme.accent)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Theme.accent.opacity(0.12)))
                    }
                    .buttonStyle(.pressable)
                }
                .padding(12)
                .surfaceCard(radius: 14)
                .padding(.horizontal, 16)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: message)
    }
}

// MARK: - Permission

struct PermissionGate: View {
    @Environment(AppModel.self) private var model
    @Binding var dismissed: Bool

    var body: some View {
        let show = model.camera.state == .unauthorized && !dismissed && !ScreenshotMode.isActive
        ZStack {
            if show {
                CameraPermissionView {
                    withAnimation(Motion.standard) { dismissed = true }
                }
                .transition(.opacity)
            }
        }
        .animation(Motion.standard, value: show)
    }
}

/// Full-screen explanation when camera access was denied.
struct CameraPermissionView: View {
    @Environment(\.openURL) private var openURL
    let onBrowse: () -> Void

    @State private var appeared = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 0) {
                Spacer()
                ZStack {
                    Circle()
                        .strokeBorder(Theme.accent.opacity(0.25), lineWidth: 1)
                        .frame(width: 132, height: 132)
                        .scaleEffect(appeared ? 1 : 0.85)
                    Circle()
                        .fill(Theme.surface)
                        .overlay(Circle().strokeBorder(Theme.hairline, lineWidth: 1))
                        .frame(width: 100, height: 100)
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 42, weight: .light))
                        .foregroundStyle(Theme.accent)
                        .rotationEffect(.degrees(appeared ? 0 : -60))
                }
                Text("让胶片机看见世界")
                    .font(AppFont.ui(24, .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 30)
                Text("取景和拍摄需要使用相机。\n照片只保存在这台手机上，不会上传到任何地方。")
                    .font(AppFont.ui(14))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.top, 12)
                Spacer()
                Button {
                    Haptics.tap()
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    PrimaryCapsule(title: "前往设置开启相机", systemImage: "gearshape")
                }
                .buttonStyle(.pressable)
                Button {
                    onBrowse()
                } label: {
                    Text("先看看底片，或导入照片冲洗")
                        .font(AppFont.ui(14))
                        .foregroundStyle(Theme.secondary)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.pressable)
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
            .padding(.bottom, 26)
            .opacity(appeared ? 1 : 0)
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.85)) { appeared = true }
        }
    }
}
