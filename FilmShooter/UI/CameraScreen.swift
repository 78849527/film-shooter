import SwiftUI
import AVKit

// MARK: - Presentation requests

/// Item-based presentations: everything a presented screen needs travels in
/// the item, so it is read when the item is set -- never from side state the
/// root body doesn't read (which SwiftUI may hand to the cover stale).
struct GalleryRequest: Identifiable {
    let id = UUID()
    /// Open straight into this print.
    var initialPhotoID: UUID?
}

struct SettingsRequest: Identifiable {
    let id = UUID()
    var startAtAbout: Bool = false
}

struct LibraryRequest: Identifiable {
    let id = UUID()
    var filter: FilmLibraryFilter = .all
}

// MARK: - Camera screen

/// The root screen: top bar, viewfinder, film chooser, shutter deck. Holds only
/// presentation state; everything that changes often is read by subviews.
struct CameraScreen: View {
    @EnvironmentObject private var model: AppModel
    @Namespace private var namespace

    @StateObject private var fx = ShutterFX()
    @State private var galleryRequest: GalleryRequest?
    @State private var settingsRequest: SettingsRequest?
    @State private var libraryRequest: LibraryRequest?
    @State private var showPrint = false
    @State private var showAspect = false
    @State private var editor: EditorModel?
    @State private var permissionDismissed = false
    @State private var didOpenScene = false

    /// The hardware shutter (Camera Control / volume buttons) only fires
    /// while the camera screen itself is in front.
    private var captureEventsEnabled: Bool {
        galleryRequest == nil && settingsRequest == nil && libraryRequest == nil
            && !showPrint && editor == nil && !showAspect
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(showAspectPicker: $showAspect, openSettings: {
                settingsRequest = SettingsRequest(startAtAbout: false)
            })

            ViewfinderPanel(fx: fx)
                .padding(.horizontal, 8)
                .frame(maxHeight: .infinity)

            EngineStatusCard()

            CameraFilmSection(openPrint: { showPrint = true }, openLibrary: openLibrary)
                .padding(.top, 10)

            ControlDeck(namespace: namespace, editor: $editor, openGallery: {
                galleryRequest = GalleryRequest(initialPhotoID: nil)
            })
            .padding(.top, 4)
            .padding(.bottom, 2)
        }
        .background(Theme.background.ignoresSafeArea())
        .overlay { aspectOverlay }
        .overlay { BannerOverlay(topPadding: 52) }
        .overlay { PermissionGate(dismissed: $permissionDismissed) }
        .modifier(CompatibleCaptureEventModifier(isEnabled: captureEventsEnabled, shoot: {
            Task { await model.shoot() }
        }))
        .sheet(isPresented: $showPrint) {
            PrintSettingsSheet()
                .environmentObject(model)
        }
        .sheet(item: $libraryRequest) { request in
            FilmLibrarySheet(initialFilter: request.filter)
                .environmentObject(model)
        }
        .sheet(item: $settingsRequest) { request in
            SettingsView(startAtAbout: request.startAtAbout)
                .environmentObject(model)
        }
        .fullScreenCover(item: $galleryRequest) { request in
            GalleryView(initialPhotoID: request.initialPhotoID)
                .compatibleGalleryTransition(namespace: namespace)
                .environmentObject(model)
        }
        .fullScreenCover(item: $editor) { editor in
            EditorView(editor: editor)
                .environmentObject(model)
        }
        .onAppear {
            let fx = self.fx
            model.camera.onShutter = { MainActor.assumeIsolated { fx.fire() } }
            Haptics.prepareShutter()
        }
        .compatibleOnChange(of: editor != nil) { _, open in pauseCameraForEditor(open) }
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
                    .padding(.top, 48)
                    .transition(.scale(scale: 0.94, anchor: .top).combined(with: .opacity))
            }
        }
    }

    private func closeAspect() {
        withAnimation(Motion.standard) { showAspect = false }
    }

    // MARK: actions

    private func openLibrary() {
        libraryRequest = LibraryRequest(filter: model.isFavorite(model.filmID) ? .favorites : .all)
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
        case "gallery":
            try? await Task.sleep(nanoseconds: 400_000_000)
            galleryRequest = GalleryRequest(initialPhotoID: nil)
        case "detail":
            var waited = 0
            while model.library.photos.isEmpty && waited < 200 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 1
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let first = model.library.photos.first else {
                ScreenshotMode.log("detail: no photos in the library after \(waited / 10) s")
                return
            }
            ScreenshotMode.log("detail: presenting gallery with photo \(first.id) pushed")
            galleryRequest = GalleryRequest(initialPhotoID: first.id)
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
        case "library":
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            libraryRequest = LibraryRequest(filter: .all)
        case "settings":
            settingsRequest = SettingsRequest(startAtAbout: false)
        case "about":
            ScreenshotMode.log("about: presenting settings with About pushed")
            settingsRequest = SettingsRequest(startAtAbout: true)
        default:
            break
        }
    }
}

// MARK: - Engine status

/// Shown above the film chooser when the developing engine could not start
/// (the camera keeps working). Takes no space otherwise.
struct EngineStatusCard: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        let message: String? = {
            if case .failed(let m) = model.engineState { return m }
            return nil
        }()
        VStack(spacing: 0) {
            if let message {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 15))
                        .foregroundStyle(Theme.lcd)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("冲洗引擎启动失败")
                            .font(AppFont.ui(13, .semibold))
                            .foregroundStyle(Theme.text)
                        Text(message)
                            .font(AppFont.ui(11))
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
                            .foregroundStyle(Theme.text)
                            .padding(.horizontal, 12)
                            .frame(height: 30)
                            .background(Capsule().fill(Color.white.opacity(0.1)))
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.pressable)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .surfaceCard(radius: 14)
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(Motion.standard, value: message)
    }
}

// MARK: - Permission

struct PermissionGate: View {
    @EnvironmentObject private var model: AppModel
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
                    .font(AppFont.ui(28, .semibold))
                    .foregroundStyle(Theme.text)
                    .padding(.top, 30)
                Text("取景和拍摄需要使用相机。\n照片只保存在这台手机上，不会上传到任何地方。")
                    .font(AppFont.ui(15))
                    .foregroundStyle(Theme.secondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(5)
                    .padding(.top, 12)
                Spacer()
                Button {
                    if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                } label: {
                    PrimaryCapsule(title: "前往设置开启相机", systemImage: "gearshape")
                }
                .buttonStyle(.pressable)
                Button {
                    onBrowse()
                } label: {
                    Text("先看看底片，或导入照片冲洗")
                        .font(AppFont.ui(15))
                        .foregroundStyle(Theme.secondary)
                        .frame(minHeight: 44)
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
