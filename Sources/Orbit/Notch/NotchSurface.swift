import SwiftUI

// Orbit's notch language (Milestone 6, direction B: "hardware extension").
// Surfaces attached to the notch are pure black and grow out of it: concave
// shoulders where they meet the menu bar, generous bottom corners, a single
// rim of light along the lower edge so they read on dark wallpapers, and a
// soft shadow on light ones. Floating satellites (Music Island, volume HUD)
// use the same black, rim and shadow as capsules. Colour comes only from
// content: artwork, agent identity, state.

/// A rectangle whose top corners curve outwards into the edge it hangs from
/// (concave "shoulders"), with rounded bottom corners. The shoulders sit
/// inside the frame, so the body is `2 × shoulder` narrower than the frame.
struct NotchShape: Shape {
    var shoulder: CGFloat
    var bottomRadius: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(shoulder, bottomRadius) }
        set { shoulder = newValue.first; bottomRadius = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        let s = max(0, min(shoulder, rect.width / 4, rect.height / 2))
        let r = max(0, min(bottomRadius, (rect.width - 2 * s) / 2, rect.height - s))
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s), control: CGPoint(x: rect.minX + s, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + s + r, y: rect.maxY), control: CGPoint(x: rect.minX + s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s - r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - r), control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control: CGPoint(x: rect.maxX - s, y: rect.minY))
        path.closeSubpath()
        return path
    }
}

enum NotchStyle {
    /// Matches the hardware notch: true black, so surface and camera housing read as one object.
    static let fill = Color.black
    /// The rim: nothing at the top (that's the notch), a little light at the bottom.
    static let rim = LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                            .init(color: .white.opacity(0.05), location: 0.55),
                                            .init(color: .white.opacity(0.17), location: 1)],
                                    startPoint: .top, endPoint: .bottom)
    static let shadow = Color.black.opacity(0.45)
    static let attachedShoulder: CGFloat = 8
}

extension View {
    /// An attached surface: black body with shoulders and a lower rim light.
    /// `opacity` < 1 lets the user's dashboard transparency through, over
    /// Liquid Glass so it stays legible.
    func notchSurface(bottomRadius: CGFloat, shoulder: CGFloat = NotchStyle.attachedShoulder, opacity: Double = 1) -> some View {
        let shape = NotchShape(shoulder: shoulder, bottomRadius: bottomRadius)
        return background {
            ZStack {
                if opacity < 1 { Color.clear.glassEffect(.regular.tint(.black.opacity(0.55)), in: shape) }
                shape.fill(NotchStyle.fill.opacity(opacity))
            }
        }
        .overlay(shape.stroke(NotchStyle.rim, lineWidth: 1).allowsHitTesting(false))
    }

    /// A floating satellite below the notch (Music Island, volume HUD).
    func islandSurface(in shape: some InsettableShape) -> some View {
        background(NotchStyle.fill.opacity(0.94), in: shape)
            .overlay(shape.strokeBorder(NotchStyle.rim, lineWidth: 1).allowsHitTesting(false))
            .overlay(shape.strokeBorder(.white.opacity(0.06), lineWidth: 0.5).allowsHitTesting(false))
    }
}
