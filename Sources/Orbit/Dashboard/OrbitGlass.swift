import SwiftUI

// Orbit Glass: the dashboard's visual language. Cards are lit translucent
// layers made of static gradients (no blur, no offscreen work), sitting on the
// panel's own Liquid Glass. Real Liquid Glass is used only for interactive
// controls, so glass is never stacked under more glass.

enum OrbitGlass {
    static let cardRadius: CGFloat = 18
    static let innerRadius: CGFloat = 12
    static let cardPadding: CGFloat = 14

    // Built once, shared by every card.
    static let cardFill = LinearGradient(
        colors: [.white.opacity(0.075), .white.opacity(0.028)], startPoint: .top, endPoint: .bottom)
    /// The specular rim: bright along the top edge, gone by 40% of the height.
    static let rim = LinearGradient(
        stops: [.init(color: .white.opacity(0.26), location: 0), .init(color: .white.opacity(0.06), location: 0.4),
                .init(color: .clear, location: 1)],
        startPoint: .top, endPoint: .bottom)
    /// A soft reflection near the upper-left corner.
    static let sheen = RadialGradient(
        colors: [.white.opacity(0.055), .clear], center: UnitPoint(x: 0.12, y: 0), startRadius: 0, endRadius: 170)
    static let litSheen = RadialGradient(
        colors: [.white.opacity(0.09), .clear], center: UnitPoint(x: 0.12, y: 0), startRadius: 0, endRadius: 200)
    static let hairline = Color.white.opacity(0.075)
    static let shadow = Color.black.opacity(0.32)

    static let surfaceFill = Color.white.opacity(0.05)
    static let surfaceStroke = Color.white.opacity(0.06)

    /// Semantic colors, used sparingly; Orbit's accent stays `Theme.accent`.
    static let warning = Color(red: 1, green: 0.74, blue: 0.36)
    static let critical = Color(red: 1, green: 0.48, blue: 0.42)
    /// Daily goals' progress, so it never reads as task progress (indigo).
    static let goal = Color(red: 0.42, green: 0.84, blue: 0.70)
}

/// SF Pro hierarchy. Numbers that change use tabular digits.
enum OrbitType {
    static let eyebrow = Font.system(size: 10, weight: .semibold)
    static let hero = Font.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit()
    static let metric = Font.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit()
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 10.5, weight: .medium)
}

// MARK: Motion

extension Animation {
    /// State changes: restrained, barely any bounce.
    static let orbitSpring = Animation.spring(duration: 0.35, bounce: 0.12)
    static let orbitHover = Animation.easeOut(duration: 0.18)
}

private struct ReduceMotionKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Orbit's Reduce Motion setting or the system's (set by `DashboardView`).
    var orbitReduceMotion: Bool {
        get { self[ReduceMotionKey.self] }
        set { self[ReduceMotionKey.self] = newValue }
    }
}

enum OrbitMotion {
    /// The animation to use, or nil (no animation) when motion is reduced.
    static func animation(_ animation: Animation, reduced: Bool) -> Animation? { reduced ? nil : animation }
}

/// Which card the pointer is over. (Views can't hold `@State` with this
/// toolchain, so hover lives here; only the two cards involved redraw.)
@MainActor @Observable
final class OrbitHover {
    static let shared = OrbitHover()
    private(set) var card: String?

    func pointer(inside: Bool, card id: String) {
        if inside { card = id } else if card == id { card = nil }
    }
}

// MARK: Card

/// Every widget's container: header, content, lit glass layers, 18 pt corners.
struct OrbitGlassCard<Content: View>: View {
    let id: String
    let title: String
    let symbol: String
    var badge: String?
    @ViewBuilder let content: Content
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        let lit = OrbitHover.shared.card == id
        let shape = RoundedRectangle(cornerRadius: OrbitGlass.cardRadius, style: .continuous)
        let hover = OrbitMotion.animation(.orbitHover, reduced: reduceMotion)
        VStack(alignment: .leading, spacing: 10) {
            OrbitWidgetHeader(title: title, symbol: symbol, badge: badge)
            content
        }
        .padding(OrbitGlass.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background {
            ZStack {
                shape.fill(OrbitGlass.cardFill)
                    .shadow(color: OrbitGlass.shadow, radius: 8, y: 3)
                shape.fill(lit ? OrbitGlass.litSheen : OrbitGlass.sheen)
                    .animation(hover, value: lit)
            }
        }
        .overlay {
            ZStack {
                shape.strokeBorder(OrbitGlass.hairline, lineWidth: 0.5)
                shape.strokeBorder(OrbitGlass.rim, lineWidth: 1)
                    .opacity(lit ? 1 : 0.78)
                    .animation(hover, value: lit)
            }
            .allowsHitTesting(false)
        }
        .contentShape(shape)
        .onHover { OrbitHover.shared.pointer(inside: $0, card: id) }
    }
}

/// Icon, small-caps title and an optional badge.
struct OrbitWidgetHeader: View {
    let title: String
    let symbol: String
    var badge: String?

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
            Text(title.uppercased())
                .tracking(0.7)
            Spacer(minLength: 4)
            if let badge { OrbitGlassChip(text: badge) }
        }
        .font(OrbitType.eyebrow)
        .foregroundStyle(Theme.secondary)
        .lineLimit(1)
    }
}

/// A small static label (SAMPLE). Not interactive, so not Liquid Glass.
struct OrbitGlassChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .padding(.horizontal, 7)
            .padding(.vertical, 2.5)
            .background(Color.white.opacity(0.09), in: .capsule)
            .overlay(Capsule().strokeBorder(OrbitGlass.hairline, lineWidth: 0.5))
            .foregroundStyle(Theme.secondary)
    }
}

extension View {
    /// An inner surface: rows, tiles, fields (12 pt corners by default).
    func orbitSurface(radius: CGFloat = OrbitGlass.innerRadius) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return background(OrbitGlass.surfaceFill, in: shape)
            .overlay(shape.strokeBorder(OrbitGlass.surfaceStroke, lineWidth: 0.5).allowsHitTesting(false))
    }
}

// MARK: Controls

/// Interactive Liquid Glass. Deliberately not `.buttonStyle(.glass)`: native
/// bordered styles take their inactive look while the panel isn't key (which
/// it isn't while hovering), so this draws the glass itself and only dims
/// while pressed.
struct OrbitGlassButtonStyle: ButtonStyle {
    var prominent = false
    var shape = AnyShape(Capsule())

    func makeBody(configuration: Configuration) -> some View {
        let glass: Glass = prominent ? .regular.tint(Theme.accent.opacity(0.45)).interactive() : .regular.interactive()
        configuration.label
            .contentShape(shape)
            .glassEffect(glass, in: shape)
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

/// A glass pill: icon and title.
struct OrbitGlassButton: View {
    let title: String
    let symbol: String
    var prominent = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 11, weight: .semibold))
                .padding(.horizontal, 11)
                .padding(.vertical, 5)
        }
        .buttonStyle(OrbitGlassButtonStyle(prominent: prominent))
    }
}

/// One of a set of choices (AI provider, task priority): the selected one is
/// a glass capsule, the others plain text.
struct OrbitSelectableStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        if isSelected {
            OrbitGlassButtonStyle().makeBody(configuration: configuration)
        } else {
            DashboardButtonStyle().makeBody(configuration: configuration)
        }
    }
}

/// Plain, compact button look for dashboard rows; dims while pressed.
struct DashboardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(.rect)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

// MARK: Data display

/// A large changing number (time, percentage). Rolls digits on change unless
/// motion is reduced.
struct OrbitGlassMetric: View {
    let value: String
    var unit: String?
    var font = OrbitType.hero
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(font)
                .contentTransition(reduceMotion ? .identity : .numericText())
            if let unit {
                Text(unit).font(OrbitType.title).foregroundStyle(Theme.secondary)
            }
        }
        .animation(OrbitMotion.animation(.orbitSpring, reduced: reduceMotion), value: value)
        .lineLimit(1)
    }
}

/// A glossy progress bar. Not `ProgressView`: that greys out whenever the
/// panel isn't key, which is always the case while hovering.
struct MeterBar: View {
    let fraction: Double
    var tint = Theme.accent
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        let clamped = min(max(fraction, 0), 1)
        Capsule()
            .fill(Color.white.opacity(0.08))
            .overlay(Capsule().strokeBorder(Color.black.opacity(0.28), lineWidth: 0.5))
            .frame(height: 6)
            .overlay(alignment: .leading) {
                GeometryReader { geometry in
                    Capsule()
                        .fill(LinearGradient(colors: [tint, tint.opacity(0.72)], startPoint: .top, endPoint: .bottom))
                        .overlay(alignment: .top) {
                            Capsule().fill(Color.white.opacity(0.38)).frame(height: 1).padding(.horizontal, 3).padding(.top, 0.5)
                        }
                        .frame(width: clamped == 0 ? 0 : max(6, geometry.size.width * clamped))
                }
            }
            .animation(OrbitMotion.animation(.orbitSpring, reduced: reduceMotion), value: clamped)
    }
}

/// "Done of total" as a ring. Never shows a percentage; with nothing to do
/// it's an empty track. Animates changes unless motion is reduced.
struct OrbitProgressRing: View {
    let done: Int
    let total: Int
    var tint = Theme.accent
    var size: CGFloat = 32
    var lineWidth: CGFloat = 4
    @Environment(\.orbitReduceMotion) private var reduceMotion

    static func fraction(done: Int, total: Int) -> Double {
        total > 0 ? min(max(Double(done) / Double(total), 0), 1) : 0
    }

    var body: some View {
        let fraction = Self.fraction(done: done, total: total)
        ZStack {
            Circle().stroke(Color.white.opacity(0.09), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(LinearGradient(colors: [tint, tint.opacity(0.7)], startPoint: .top, endPoint: .bottom),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text("\(done)")
                .font(.system(size: size * 0.36, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(reduceMotion ? .identity : .numericText())
                .foregroundStyle(total > 0 ? .white : Theme.tertiary)
        }
        .frame(width: size, height: size)
        .animation(OrbitMotion.animation(.orbitSpring, reduced: reduceMotion), value: fraction)
        .accessibilityLabel("\(done) of \(total) done")
    }
}

// MARK: States

/// Empty, error and unavailable states (and short messages inside widgets).
struct StatusMessage: View {
    enum Tone { case neutral, warning }

    let text: String
    let symbol: String
    var tone = Tone.neutral

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tone == .warning ? OrbitGlass.warning : Theme.secondary)
                .frame(width: 32, height: 32)
                .orbitSurface(radius: 16)
            Text(text)
                .font(OrbitType.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Loading: a static outline of content (no spinner: `ProgressView` greys out
/// in the non-key panel; no shimmer: nothing loops).
struct OrbitLoadingView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach([0.55, 0.85, 0.4], id: \.self) { width in
                GeometryReader { geometry in
                    Capsule().fill(Color.white.opacity(0.07)).frame(width: geometry.size.width * width)
                }
                .frame(height: 8)
            }
            Spacer(minLength: 0)
        }
        .accessibilityLabel("Loading")
    }
}
