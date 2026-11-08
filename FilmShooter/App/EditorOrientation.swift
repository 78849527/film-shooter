import Foundation
import UIKit

/// The camera stays portrait. Only the full-screen darkroom editor may rotate.
/// Keep supported directions in a process-wide delegate because iOS 16 does
/// not allow a SwiftUI view to override app-level supported orientations.
@MainActor
final class FilmShooterOrientationDelegate: NSObject, UIApplicationDelegate {
    static var supported: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        Self.supported
    }
}

@MainActor
enum EditorOrientation {
    static func begin() {
        FilmShooterOrientationDelegate.supported = .allButUpsideDown
        notifySupportedOrientationsChanged()
    }

    static func rotateToLandscape() {
        // Do not change the delegate's allowed mask to a single direction.
        // Keeping both directions allowed supports ordinary device rotation.
        request(.landscapeRight)
    }

    static func rotateToPortrait() {
        request(.portrait)
    }

    static func end() {
        FilmShooterOrientationDelegate.supported = .portrait
        notifySupportedOrientationsChanged()
        request(.portrait)
    }

    private static func notifySupportedOrientationsChanged() {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows where window.isKeyWindow {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                window.rootViewController?.presentedViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }

    private static func request(_ mask: UIInterfaceOrientationMask) {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            guard scene.activationState == .foregroundActive else { continue }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: mask)) { error in
                // Unsupported transitions are harmless: user can still rotate
                // the device after opening the darkroom.
                NSLog("FilmShooter editor orientation request: %@", error.localizedDescription)
            }
        }
    }
}
