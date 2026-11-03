import SwiftUI

/// A 135 film cartridge lying on its side, drawn entirely in SwiftUI: metal
/// caps, the film leader poking out by the felt lip, the stock's body colour
/// and band, brand in tracked small caps, the name in rounded semibold, ISO and
/// process badge, cylinder shading and a soft specular line. Rasterised once
/// (`drawingGroup`) so carousels only move a texture around.
struct FilmCanister: View {
    let film: FilmStock
    /// Overall height; the width follows (`width(forHeight:)`).
    var height: CGFloat = 80

    static let aspect: CGFloat = 147.5 / 84.0
    static func width(forHeight height: CGFloat) -> CGFloat { height * aspect }

    var body: some View {
        let s = height / 84
        HStack(spacing: 0) {
            leader(s)
                .offset(y: 6 * s)
            MetalCap(width: 7 * s, height: 84 * s, corner: 2.4 * s)
            label(s)
                .frame(width: 116 * s, height: 77 * s)
            MetalCap(width: 7 * s, height: 84 * s, corner: 2.4 * s)
            // Spool end.
            MetalCap(width: 7.5 * s, height: 30 * s, corner: 2 * s)
        }
        .frame(width: 147.5 * s, height: 84 * s)
        .drawingGroup()
        .accessibilityElement()
        .accessibilityLabel(Text("\(film.displayName)，ISO \(film.iso)，\(film.kind.title)"))
    }

    private func label(_ s: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(film.body)

            // The band along the bottom, and a thin pinstripe near the top.
            VStack(spacing: 0) {
                Spacer(minLength: 0)
                Rectangle().fill(film.band).frame(height: 23 * s)
            }
            Rectangle()
                .fill(film.band.opacity(0.85))
                .frame(height: 2 * s)
                .offset(y: 6.5 * s)

            VStack(alignment: .leading, spacing: 0.5 * s) {
                Text(film.brand.uppercased())
                    .font(.system(size: 7 * s, weight: .bold, design: .rounded))
                    .tracking(1.8 * s)
                    .opacity(0.72)
                Text(film.name)
                    .font(.system(size: 15 * s, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            .foregroundStyle(film.ink)
            .padding(.top, 13 * s)
            .padding(.horizontal, 8 * s)

            HStack(alignment: .lastTextBaseline, spacing: 2 * s) {
                Text("ISO")
                    .font(.system(size: 6 * s, weight: .bold, design: .rounded))
                    .opacity(0.8)
                Text("\(film.iso)")
                    .font(.system(size: 12 * s, weight: .heavy, design: .rounded))
                    .monospacedDigit()
                Spacer(minLength: 2 * s)
                Text(film.kind.shortTitle)
                    .font(.system(size: 6.5 * s, weight: .bold, design: .rounded))
                    .tracking(0.4 * s)
                    .padding(.horizontal, 3.5 * s)
                    .padding(.vertical, 1.2 * s)
                    .overlay(Capsule().strokeBorder(film.body.opacity(0.85), lineWidth: 0.8 * s))
            }
            .foregroundStyle(film.body)
            .padding(.horizontal, 8 * s)
            .frame(height: 23 * s)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            // Cylinder shading: lit from above, falling off underneath.
            LinearGradient(stops: [
                .init(color: .white.opacity(0.26), location: 0),
                .init(color: .white.opacity(0.05), location: 0.2),
                .init(color: .clear, location: 0.42),
                .init(color: .black.opacity(0.08), location: 0.72),
                .init(color: .black.opacity(0.26), location: 1),
            ], startPoint: .top, endPoint: .bottom)

            // Specular line.
            LinearGradient(colors: [.white.opacity(0), .white.opacity(0.42), .white.opacity(0.42), .white.opacity(0)],
                           startPoint: .leading, endPoint: .trailing)
                .frame(height: 1.4 * s)
                .offset(y: 4 * s)

            // The black felt light-trap the film comes out of.
            HStack(spacing: 0) {
                Rectangle()
                    .fill(Color.black.opacity(0.55))
                    .frame(width: 3 * s)
                Rectangle()
                    .fill(Color.white.opacity(0.12))
                    .frame(width: 0.6 * s)
                Spacer(minLength: 0)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 2 * s, style: .continuous))
    }

    /// The brown film leader with a rounded tongue and a few perforations.
    private func leader(_ s: CGFloat) -> some View {
        ZStack {
            UnevenRoundedRectangle(topLeadingRadius: 4.5 * s, bottomLeadingRadius: 4.5 * s,
                                   bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous)
                .fill(LinearGradient(colors: [Color(hex: 0x5A3317), Color(hex: 0x2E1A0B)],
                                     startPoint: .top, endPoint: .bottom))
            VStack {
                HStack(spacing: 2 * s) {
                    perforation(s)
                    perforation(s)
                }
                Spacer(minLength: 0)
                HStack(spacing: 2 * s) {
                    perforation(s)
                    perforation(s)
                }
            }
            .padding(.vertical, 2.5 * s)
            .padding(.leading, 3 * s)
        }
        .frame(width: 10 * s, height: 30 * s)
    }

    private func perforation(_ s: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: 0.5 * s, style: .continuous)
            .fill(Color.black.opacity(0.55))
            .frame(width: 2 * s, height: 1.6 * s)
    }
}

/// A brushed-metal end cap.
struct MetalCap: View {
    let width: CGFloat
    let height: CGFloat
    let corner: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(LinearGradient(stops: [
                .init(color: Color(white: 0.30), location: 0),
                .init(color: Color(white: 0.88), location: 0.16),
                .init(color: Color(white: 0.64), location: 0.4),
                .init(color: Color(white: 0.36), location: 0.74),
                .init(color: Color(white: 0.55), location: 1),
            ], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(Color.black.opacity(0.28), lineWidth: max(0.5, width * 0.07))
            )
            .frame(width: width, height: height)
    }
}

/// A soft contact shadow under a canister (a squashed radial gradient: no blur).
struct CanisterShadow: View {
    var width: CGFloat

    var body: some View {
        Circle()
            .fill(RadialGradient(colors: [Color.black.opacity(0.55), Color.black.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: width / 2))
            .frame(width: width, height: width)
            .scaleEffect(x: 1, y: 0.12)
            .frame(width: width, height: width * 0.12)
    }
}
