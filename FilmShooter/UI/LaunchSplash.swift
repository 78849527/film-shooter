import SwiftUI

/// A brief launch card: a length of film gliding across, the wordmark rising
/// in. Shown at most ~1 s while the engine starts.
struct LaunchSplash: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            VStack(spacing: 28) {
                SplashFilmStrip()
                    .frame(height: 64)
                    .offset(x: appeared || reduceMotion ? 0 : 60)
                    .opacity(appeared ? 1 : 0)
                VStack(spacing: 8) {
                    Text("胶片机")
                        .font(AppFont.ui(34, .semibold))
                        .foregroundStyle(Theme.text)
                    Text("FILM SHOOTER")
                        .font(AppFont.mono(11, .semibold))
                        .tracking(6)
                        .foregroundStyle(Theme.accent)
                }
                .offset(y: appeared || reduceMotion ? 0 : 10)
                .opacity(appeared ? 1 : 0)
            }
        }
        .onAppear {
            withAnimation(.spring(response: 0.7, dampingFraction: 0.9)) { appeared = true }
        }
    }
}

/// A strip of 135 film with sprocket holes and a few warm frames.
private struct SplashFilmStrip: View {
    var body: some View {
        Canvas { context, size in
            let stripRect = CGRect(x: -20, y: 0, width: size.width + 40, height: size.height)
            context.fill(Path(stripRect), with: .color(Color(hex: 0x23170F)))
            let rail = size.height * 0.2
            let holeH = rail * 0.5
            let holeW = holeH * 1.35
            var x: CGFloat = -10
            while x < size.width + 20 {
                for y in [rail / 2 - holeH / 2, size.height - rail / 2 - holeH / 2] {
                    context.fill(Path(roundedRect: CGRect(x: x, y: y, width: holeW, height: holeH),
                                      cornerRadius: holeH * 0.25),
                                 with: .color(Theme.background))
                }
                x += holeW * 2.2
            }
            let frameH = size.height - rail * 2 - 4
            let frameW = frameH * 1.5
            let tints: [Color] = [Color(hex: 0x5A3A22), Color(hex: 0x8A5A2E), Color(hex: 0xB9793A),
                                  Color(hex: 0x8A5A2E), Color(hex: 0x5A3A22)]
            let total = CGFloat(tints.count) * frameW + CGFloat(tints.count - 1) * 6
            var fx = (size.width - total) / 2
            for tint in tints {
                let rect = CGRect(x: fx, y: rail + 2, width: frameW, height: frameH)
                context.fill(Path(roundedRect: rect, cornerRadius: 2),
                             with: .linearGradient(Gradient(colors: [tint.opacity(0.9), tint.opacity(0.55)]),
                                                   startPoint: CGPoint(x: rect.minX, y: rect.minY),
                                                   endPoint: CGPoint(x: rect.maxX, y: rect.maxY)))
                fx += frameW + 6
            }
        }
    }
}
