import SwiftUI

@main
struct FilmShooterApp: App {
    @UIApplicationDelegateAdaptor(FilmShooterOrientationDelegate.self) private var orientationDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .preferredColorScheme(.dark)
                .statusBarHidden()
                .tint(Theme.accent)
        }
    }
}

/// Starts the engine and the camera, follows the scene phase, and shows the
/// launch splash until the engine is ready (at most ~1 s).
struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    @State private var showSplash = !ScreenshotMode.isActive
    @State private var launched = false

    var body: some View {
        ZStack {
            CameraScreen()
            if showSplash {
                LaunchSplash()
                    .transition(.opacity.combined(with: .scale(scale: 1.03)))
                    .zIndex(1)
            }
        }
        .background(Theme.background.ignoresSafeArea())
        .task { await launch() }
        .compatibleOnChange(of: scenePhase) { _, phase in
            guard launched else { return }
            model.setActive(phase == .active)
        }
        .compatibleOnChange(of: model.settings.haptics, initial: true) { _, enabled in
            Haptics.isEnabled = enabled
        }
    }

    private func launch() async {
        guard !launched else { return }
        launched = true
        let started = Date()
        let model = self.model

        // The camera does not need the engine: start both at once so the
        // viewfinder is live as early as possible.
        Task { await model.camera.start() }
        Task {
            await model.boot()
            if ScreenshotMode.scene == "seed" {
                ScreenshotMode.seed(model: model)
            }
        }

        guard showSplash else { return }
        while model.engineState == .starting && Date().timeIntervalSince(started) < 1.0 {
            try? await Task.sleep(nanoseconds: 40_000_000)
        }
        // Never just flash: keep the card up for a beat.
        let remaining = 0.45 - Date().timeIntervalSince(started)
        if remaining > 0 {
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
        }
        withAnimation(.easeOut(duration: 0.5)) { showSplash = false }
    }
}
