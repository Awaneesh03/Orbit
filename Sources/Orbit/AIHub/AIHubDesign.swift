import AppKit
import SwiftUI

// AI Hub design system (AI Hub 2.0). Built on Orbit Glass (the dashboard
// stays dark so it blends with the notch), with a denser, calmer layer for a
// developer workspace: graphite surfaces instead of glass on glass, one
// accent, colour reserved for agent identity and state, and every state shown
// with an icon and words as well as colour. Sized for the dashboard's real
// content area, about 708 × 330 pt.

/// System accessibility settings the AI Hub follows (observable, so views redraw when they change).
@MainActor @Observable
final class HubAppearance {
    static let shared = HubAppearance()
    /// macOS › Accessibility › Display › Increase contrast.
    var increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
}

@MainActor
enum HubTokens {
    private static var high: Bool { HubAppearance.shared.increasedContrast }

    // Surfaces: graphite steps, not flat black. Increase Contrast: stronger steps and borders.
    static let canvas = Color(red: 0.075, green: 0.078, blue: 0.09)
    static var surface: Color { .white.opacity(high ? 0.09 : 0.045) }
    static var surfaceRaised: Color { .white.opacity(high ? 0.13 : 0.075) }
    static var surfaceHover: Color { .white.opacity(high ? 0.17 : 0.10) }
    static var surfaceSelected: Color { Theme.accent.opacity(high ? 0.32 : 0.18) }
    static var border: Color { .white.opacity(high ? 0.32 : 0.08) }
    static var borderStrong: Color { .white.opacity(high ? 0.5 : 0.16) }

    // Text (≥ 4.5:1 on every surface; Increase Contrast: ≥ 7:1).
    static var textPrimary: Color { .white.opacity(high ? 1 : 0.94) }
    static var textSecondary: Color { .white.opacity(high ? 0.86 : 0.64) }
    static var textTertiary: Color { .white.opacity(high ? 0.74 : 0.56) }

    // State.
    static let running = Color(red: 0.36, green: 0.84, blue: 0.56)
    static let attention = Color(red: 1, green: 0.70, blue: 0.30)
    static var failure: Color { high ? Color(red: 1, green: 0.62, blue: 0.6) : Color(red: 1, green: 0.52, blue: 0.49) }
    static var quiet: Color { .white.opacity(high ? 0.74 : 0.56) }

    // Spacing (4-pt grid) and radii (concentric: outer = inner + padding).
    static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16
    static let radiusSmall: CGFloat = 6
    static let radius: CGFloat = 10
    static let radiusLarge: CGFloat = 14

    // Type.
    static let display = Font.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit()
    static let title = Font.system(size: 13, weight: .semibold)
    static let body = Font.system(size: 12, weight: .regular)
    static let bodyStrong = Font.system(size: 12, weight: .medium)
    static let caption = Font.system(size: 10.5, weight: .medium)
    static let micro = Font.system(size: 9.5, weight: .semibold)
    static let mono = Font.system(size: 10.5, weight: .regular, design: .monospaced)

    // Motion: short, interruptible; nothing loops.
    static let quick = Animation.easeOut(duration: 0.15)
    static let move = Animation.spring(duration: 0.3, bounce: 0.08)
}

// MARK: Agent identity

/// Each agent's colour and symbol, so a glance tells them apart (and words always say which).
@MainActor
enum AgentStyle {
    static func color(_ agent: AgentID) -> Color {
        if agent.isDemo { return Color(red: 0.62, green: 0.58, blue: 0.85) }
        switch agent.rawValue {
        case "claude-code": return Color(red: 0.85, green: 0.47, blue: 0.34)
        case "codex": return Color(red: 0.38, green: 0.78, blue: 0.70)
        case "copilot-cli": return Color(red: 0.70, green: 0.55, blue: 0.95)
        case "cursor": return Color(red: 0.78, green: 0.80, blue: 0.86)
        case "gemini-cli": return Color(red: 0.40, green: 0.62, blue: 1)
        case "antigravity": return Color(red: 0.50, green: 0.55, blue: 1)
        case "opencode": return Color(red: 0.95, green: 0.74, blue: 0.36)
        default:
            let hue = Double(agent.rawValue.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % 360) / 360
            return Color(hue: hue, saturation: 0.45, brightness: 0.9)
        }
    }

    /// An original glyph per agent, used when the vendor's app isn't on this
    /// Mac (SF Symbols; no vendor artwork is bundled with Orbit).
    static func glyph(_ agent: AgentID) -> String {
        if agent.isDemo { return "theatermasks" }
        switch agent.rawValue {
        case "claude-code": return "asterisk"
        case "codex": return "curlybraces"
        case "copilot-cli": return "airplane"
        case "cursor": return "cursorarrow.rays"
        case "gemini-cli": return "sparkle"
        case "antigravity": return "arrow.up.circle"
        case "opencode": return "terminal"
        default: return "cpu"
        }
    }

    /// The vendor app whose icon identifies each agent, most specific first.
    /// The icon is read from the installed app (as Finder shows it), so Orbit
    /// never ships or alters anyone's logo.
    static func vendorApps(_ agent: AgentID) -> [String] {
        switch agent.rawValue {
        case "claude-code": ["com.anthropic.claudefordesktop"]
        case "codex": ["com.openai.codex", "com.openai.chat"]
        case "copilot-cli": ["com.github.GitHubClient"]
        case "cursor": ["com.todesktop.230313mzl4w4u92"]
        case "gemini-cli": ["com.google.GeminiMacOS", "com.google.gemini"]
        case "antigravity": ["com.google.antigravity-ide", "com.google.antigravity"]
        default: []
        }
    }
}

/// Vendor app icons, looked up once per agent (a miss is remembered too).
@MainActor
enum AgentIcons {
    private static var cache: [String: NSImage?] = [:]
    /// Where an app with that bundle ID is installed (tests pass their own).
    static var locate: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }

    static func icon(for agent: AgentID) -> NSImage? {
        if let cached = cache[agent.rawValue] { return cached }
        var image: NSImage?
        for bundleID in AgentStyle.vendorApps(agent) {  // a loop: each app is looked up once
            if let url = locate(bundleID) {
                image = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
                break
            }
        }
        cache[agent.rawValue] = image
        return image
    }

    static func reset() { cache = [:] }
}

/// A session's state as shown: words, a symbol and a colour, never colour alone.
@MainActor
struct HubStatus: Equatable {
    let label: String
    let symbol: String
    let color: Color

    /// `waiting`: where a waiting Claude Code session is answered ("Answer in Coucou" / "Waiting in terminal").
    static func of(_ status: AgentSession.Status, bridgeUp: Bool = true, waiting: WaitingPlace? = nil) -> HubStatus {
        if status.isActive, !bridgeUp { return HubStatus(label: "Disconnected", symbol: "bolt.horizontal.circle", color: HubTokens.quiet) }
        switch status {
        case .running: return HubStatus(label: "Working", symbol: "circle.dotted.circle", color: HubTokens.running)
        case .idle: return HubStatus(label: "Idle", symbol: "pause.circle", color: Theme.accent)
        case .waiting: return HubStatus(label: waiting?.label ?? "Needs you · inferred", symbol: "hand.raised", color: HubTokens.attention)
        case .completed: return HubStatus(label: "Completed", symbol: "checkmark.circle", color: HubTokens.quiet)
        case .failed: return HubStatus(label: "Failed", symbol: "xmark.octagon", color: HubTokens.failure)
        case .ended: return HubStatus(label: "Ended", symbol: "stop.circle", color: HubTokens.quiet)
        case .stale: return HubStatus(label: "Quiet", symbol: "moon.zzz", color: HubTokens.quiet)
        }
    }
}

// MARK: Components

/// The agent's identity mark: the vendor's own app icon when that app is on
/// this Mac, otherwise an original glyph on the agent's colour. Simulated
/// agents always get the glyph with a dashed ring, so they never pass for real.
struct AgentAvatar: View {
    let agent: AgentID
    var size: CGFloat = 26

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
        Group {
            if !agent.isDemo, let icon = AgentIcons.icon(for: agent) {
                // App icons carry their own shape and margin: scale past the margin.
                Image(nsImage: icon).resizable().interpolation(.high).scaledToFit()
                    .frame(width: size * 1.2, height: size * 1.2)
                    .frame(width: size, height: size)
            } else {
                let color = AgentStyle.color(agent)
                shape.fill(LinearGradient(colors: [color.opacity(0.34), color.opacity(0.16)], startPoint: .top, endPoint: .bottom))
                    .overlay {
                        shape.strokeBorder(color.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: agent.isDemo ? [2.5, 2] : []))
                    }
                    .overlay {
                        Image(systemName: AgentStyle.glyph(agent))
                            .font(.system(size: size * 0.48, weight: .semibold))
                            .foregroundStyle(color)
                    }
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement()
        .accessibilityLabel(AgentDiscovery.displayName(for: agent))
    }
}

/// State as a small pill: symbol + words.
struct StatusPill: View {
    let status: HubStatus

    var body: some View {
        Label(status.label, systemImage: status.symbol)
            .labelStyle(.titleAndIcon)
            .font(HubTokens.micro)
            .foregroundStyle(status.color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2.5)
            .background(status.color.opacity(0.13), in: .capsule)
            .lineLimit(1)
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Status: \(status.label)")
    }
}

/// A small static tag, e.g. SIMULATED or a count.
struct HubTag: View {
    let text: String
    var tint: Color = HubTokens.textSecondary

    var body: some View {
        Text(text).font(HubTokens.micro).tracking(0.4).foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .overlay(Capsule().strokeBorder(tint.opacity(0.45), lineWidth: 0.75))
            .fixedSize()
    }
}

/// A raised panel: graphite, a hairline, concentric corners.
struct HubPanel<Content: View>: View {
    var padding: CGFloat = HubTokens.s3
    var tint: Color?
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(HubTokens.surface, in: .rect(cornerRadius: HubTokens.radiusLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HubTokens.radiusLarge, style: .continuous)
                    .strokeBorder(tint?.opacity(0.45) ?? HubTokens.border, lineWidth: tint == nil ? 0.75 : 1)
            }
    }
}

/// Section title with an optional trailing accessory.
struct HubSectionHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased()).font(HubTokens.micro).tracking(0.8).foregroundStyle(HubTokens.textTertiary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 4)
            accessory
        }
    }
}

extension HubSectionHeader where Accessory == EmptyView {
    init(title: String) { self.init(title: title) { EmptyView() } }
}

/// One figure that matters, with its meaning.
struct HubMetric: View {
    let value: String
    let label: String
    var symbol: String
    var tint: Color = HubTokens.textPrimary

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(label, systemImage: symbol).font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary).lineLimit(1)
            Text(value).font(HubTokens.display).foregroundStyle(tint).contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, HubTokens.s3)
        .padding(.vertical, 5)
        .background(HubTokens.surface, in: .rect(cornerRadius: HubTokens.radiusLarge, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: HubTokens.radiusLarge, style: .continuous).strokeBorder(HubTokens.border, lineWidth: 0.75) }
        .accessibilityElement(children: .combine)
    }
}

/// An empty state that says what's missing and offers the next step.
struct HubEmptyState: View {
    let symbol: String
    let title: String
    let message: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        VStack(spacing: HubTokens.s2) {
            Image(systemName: symbol).font(.system(size: 20, weight: .light)).foregroundStyle(HubTokens.textTertiary)
                .frame(width: 40, height: 40).background(HubTokens.surface, in: .circle)
            Text(title).font(HubTokens.title).foregroundStyle(HubTokens.textPrimary)
            Text(message).font(HubTokens.body).foregroundStyle(HubTokens.textSecondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 320)
            if let action { Button(action.title, action: action.run).buttonStyle(HubButtonStyle(kind: .primary)).padding(.top, 2) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Buttons: primary (accent), secondary (graphite), destructive; hover, press, focus, disabled.
struct HubButtonStyle: ButtonStyle {
    enum Kind { case primary, secondary, destructive, quiet }
    var kind = Kind.secondary
    var font = HubTokens.bodyStrong
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.orbitReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        HubButtonBody(configuration: configuration, kind: kind, font: font, isEnabled: isEnabled, reduceMotion: reduceMotion)
    }
}

private struct HubButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let kind: HubButtonStyle.Kind
    let font: Font
    let isEnabled: Bool
    let reduceMotion: Bool
    /// `State` without the @State macro (its plugin isn't in the Command Line Tools); SwiftUI still finds it.
    private let hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        let (fill, text): (Color, Color) = switch kind {
        case .primary: (Theme.accent.opacity(hovering ? 0.95 : 0.82), .black.opacity(0.85))
        case .secondary: (hovering ? HubTokens.surfaceHover : HubTokens.surfaceRaised, HubTokens.textPrimary)
        case .destructive: (HubTokens.failure.opacity(hovering ? 0.30 : 0.20), HubTokens.failure)
        case .quiet: (hovering ? HubTokens.surface : .clear, HubTokens.textSecondary)
        }
        configuration.label
            .font(font)
            .foregroundStyle(text)
            .padding(.horizontal, kind == .quiet ? 6 : 10)
            .frame(minHeight: 24)
            .background(fill, in: .rect(cornerRadius: HubTokens.radiusSmall, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: HubTokens.radiusSmall, style: .continuous)
                    .strokeBorder(kind == .secondary ? HubTokens.border : .clear, lineWidth: 0.75)
            }
            .contentShape(.rect)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .animation(HubTokens.quick, value: configuration.isPressed)
            .animation(HubTokens.quick, value: hovering)
            .onHover { hover.wrappedValue = $0 }
    }
}

/// A row that highlights on hover and when selected.
struct HubRowStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        HubRowBody(configuration: configuration, isSelected: isSelected)
    }
}

private struct HubRowBody: View {
    let configuration: ButtonStyle.Configuration
    let isSelected: Bool
    /// `State` without the @State macro (its plugin isn't in the Command Line Tools); SwiftUI still finds it.
    private let hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        configuration.label
            .contentShape(.rect)
            .background(isSelected ? HubTokens.surfaceSelected : hovering ? HubTokens.surface : .clear,
                        in: .rect(cornerRadius: HubTokens.radiusSmall, style: .continuous))  // concentric inside a panel's 8 pt padding
            .opacity(configuration.isPressed ? 0.75 : 1)
            .animation(HubTokens.quick, value: hovering)
            .onHover { hover.wrappedValue = $0 }
    }
}

/// "3 min", "1 h 20 min": short durations for sessions.
enum HubFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds) / 60)
        if minutes < 1 { return "under a minute" }
        if minutes < 60 { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
    }

    /// The folder a project lives in, home as ~ (e.g. "~/Developer").
    static func parent(_ path: String?) -> String? {
        guard let path, path.hasPrefix("/") else { return nil }
        return project((path as NSString).deletingLastPathComponent)
    }

    /// A path with the home folder as ~ and only its last two parts if long.
    static func project(_ path: String?) -> String? {
        guard let path else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path(percentEncoded: false)
        let short = path.hasPrefix(home) ? "~" + path.dropFirst(home.count - (home.hasSuffix("/") ? 1 : 0)) : path
        let parts = short.split(separator: "/")
        return parts.count > 3 ? "…/" + parts.suffix(2).joined(separator: "/") : short
    }
}

// MARK: Render checks

/// True only while rendering for visual QA (ImageRenderer can't draw scroll
/// views or text fields): scroll areas become plain stacks, fields static text.
private struct HubStaticRenderKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    var hubStaticRender: Bool {
        get { self[HubStaticRenderKey.self] }
        set { self[HubStaticRenderKey.self] = newValue }
    }
}

/// A vertical scroll area (a plain stack when rendering for QA).
struct HubScroll<Content: View>: View {
    var axes: Axis.Set = .vertical
    var indicators: ScrollIndicatorVisibility = .automatic
    @ViewBuilder let content: Content
    @Environment(\.hubStaticRender) private var staticRender

    var body: some View {
        if staticRender {
            // minHeight 0: takes the space it's given like a ScrollView, so long content is cut at the bottom, not centred.
            content.fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading).clipped()
        } else {
            ScrollView(axes) { content }.scrollIndicators(indicators)  // overlay scrollers: visible when scrolling
        }
    }
}

/// A text field (its placeholder or text as plain text when rendering for QA).
struct HubField: View {
    let placeholder: String
    let text: Binding<String>
    var onSubmit: () -> Void = {}
    @Environment(\.hubStaticRender) private var staticRender

    var body: some View {
        if staticRender {
            Text(text.wrappedValue.isEmpty ? placeholder : text.wrappedValue).font(HubTokens.body)
                .foregroundStyle(text.wrappedValue.isEmpty ? HubTokens.textTertiary : HubTokens.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading).lineLimit(1)
        } else {
            TextField(placeholder, text: text).textFieldStyle(.plain).font(HubTokens.body).onSubmit(onSubmit)
        }
    }
}

/// Structured questions (§23): each question's choices as buttons — one per
/// question, or several when it says so — and Send once every question is
/// answered (`ApprovalQuestion.valid`). VoiceOver reads each choice with its
/// question and whether it's chosen.
struct QuestionForm: View {
    let questions: [ApprovalQuestion]
    var enabled = true
    var compact = false
    let send: ([String: [String]]) -> Void
    /// `State` without the @State macro (its plugin isn't in the Command Line Tools); SwiftUI still finds it.
    private let chosen = State(initialValue: [String: [String]]())

    init(questions: [ApprovalQuestion], enabled: Bool = true, compact: Bool = false, send: @escaping ([String: [String]]) -> Void) {
        self.questions = questions
        self.enabled = enabled
        self.compact = compact
        self.send = send
    }

    var body: some View {
        let answers = chosen.wrappedValue
        VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            ForEach(questions, id: \.header) { question in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        HubTag(text: question.header.uppercased(), tint: HubTokens.attention)
                        Text(question.prompt).font(HubTokens.bodyStrong).foregroundStyle(HubTokens.textPrimary).lineLimit(2)
                        if question.multiSelect { Text("any").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary) }
                    }
                    HStack(spacing: 4) {
                        ForEach(question.options, id: \.label) { option in
                            let on = answers[question.header]?.contains(option.label) == true
                            Button { toggle(question, option.label) } label: {
                                Label(option.label, systemImage: question.multiSelect ? (on ? "checkmark.square.fill" : "square")
                                                                                     : (on ? "largecircle.fill.circle" : "circle"))
                            }
                            .buttonStyle(HubButtonStyle(kind: on ? .primary : .secondary, font: HubTokens.caption))
                            .help(option.detail ?? option.label)
                            .accessibilityLabel("\(question.header): \(option.label)" + (option.detail.map { ", \($0)" } ?? ""))
                            .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("Send Answers") { send(answers) }
                    .buttonStyle(HubButtonStyle(kind: .primary, font: compact ? HubTokens.caption : HubTokens.bodyStrong))
                    .disabled(!enabled || !ApprovalQuestion.valid(answers, for: questions))
            }
        }
        .disabled(!enabled)
    }

    private func toggle(_ question: ApprovalQuestion, _ label: String) {
        var current = chosen.wrappedValue[question.header] ?? []
        if question.multiSelect {
            if let index = current.firstIndex(of: label) { current.remove(at: index) } else { current.append(label) }
        } else {
            current = current == [label] ? [] : [label]
        }
        chosen.wrappedValue[question.header] = current.isEmpty ? nil : current
    }
}
