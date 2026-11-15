import AppKit
import SwiftUI

// The Notch Companion's window and views (docs/AI_HUB_SPEC.md §22, §23). Same
// rules as the music island's panel: borderless, non-activating, sized to
// what's on screen, key only while expanded, not on full-screen Spaces. One
// cat view for every phase, so the rig is never in two places.
//
// Keys while expanded: ← → session, 1–6 session by position, ↑ ↓ changed
// file, Return opens the session's app, Escape closes.

enum CompanionGeometry {
    static let idleSize = CGSize(width: 76, height: 34)
    static let compactSize = CGSize(width: 320, height: 42)
    static let expandedSize = CGSize(width: 500, height: 300)
    static let catSize: CGFloat = 40

    static func size(_ phase: NotchCompanion.Phase) -> CGSize {
        switch phase {
        case .hidden, .idle: idleSize
        case .compact: compactSize
        case .expanded: expandedSize
        }
    }

    /// Below the notch (or the menu bar's top centre without one), centred, kept on screen.
    static func rect(_ phase: NotchCompanion.Phase, trigger: CGRect, screen: CGRect) -> CGRect {
        MusicIslandGeometry.rect(size(phase), trigger: trigger, screen: screen)
    }
}

/// What the island's controls do (the app wires them to the AI Hub's own actions).
struct CompanionActions {
    var openApp: (AgentSession) -> Void = { _ in }
    var showProject: (AgentSession) -> Void = { _ in }
    var openInHub: (AgentSession) -> Void = { _ in }
    /// Files dropped on a session (§23: their quoted paths go to the clipboard; nothing is read or sent).
    var attach: ([URL], AgentSession) -> Void = { _, _ in }
}

/// A hosting view that takes the first click, and leaves drops to SwiftUI.
final class CompanionHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class NotchCompanionPanel: NSPanel {
    let companion: NotchCompanion
    private let actions: CompanionActions
    private var outsideClickMonitor: Any?
    private var trigger = CGRect.zero
    private var screenFrame = CGRect.zero
    private var settleTask: Task<Void, Never>?

    /// Number keys 1–6 (kVK_ANSI_1 … kVK_ANSI_6).
    static let positionKeys: [UInt16: Int] = [18: 0, 19: 1, 20: 2, 21: 3, 23: 4, 22: 5]

    init(companion: NotchCompanion, hub: AIHubService, rig: PetRig, actions: CompanionActions) {
        self.companion = companion
        self.actions = actions
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]  // no .fullScreenAuxiliary
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        animationBehavior = .none
        let host = CompanionHostingView(rootView: NotchCompanionView(companion: companion, hub: hub, rig: rig, actions: actions))
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .darkAqua)
        contentView = host
        companion.onPhaseChange = { [weak self] _, new in self?.phaseChanged(to: new) }
        reposition()
    }

    override var canBecomeKey: Bool { companion.phase == .expanded }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.modifierFlags.intersection([.command, .control, .option]).isEmpty {
            switch event.keyCode {
            case 53: return companion.collapse()  // Escape
            case 123: return companion.selectNext(-1)  // ←
            case 124: return companion.selectNext(1)  // →
            case 126: return companion.selectFile(-1)  // ↑
            case 125: return companion.selectFile(1)  // ↓
            case 36, 76: if let session = companion.selectedRow?.session, !session.isDemo { return actions.openApp(session) }  // Return
            default: if let position = Self.positionKeys[event.keyCode] { return companion.select(at: position) }
            }
        }
        super.sendEvent(event)
    }

    // ponytail: primary display only, like the dashboard and the music island.
    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        trigger = NotchGeometry.triggerRect(screen: screen.frame, visible: screen.visibleFrame,
                                            left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        screenFrame = screen.frame
        setFrame(CompanionGeometry.rect(companion.phase, trigger: trigger, screen: screenFrame), display: isVisible)
    }

    /// Orbit quitting: nothing on screen, nothing monitored.
    func stop() {
        settleTask?.cancel()
        removeMonitor()
        orderOut(nil)
    }

    private func phaseChanged(to phase: NotchCompanion.Phase) {
        log.notice("notch companion: \(phase.rawValue, privacy: .public)")
        removeMonitor()
        settleTask?.cancel()
        guard phase != .hidden else { return orderOut(nil) }
        let target = CompanionGeometry.rect(phase, trigger: trigger, screen: screenFrame)
        if isVisible, target.width < frame.width || target.height < frame.height {
            // Shrinking: let the content's collapse play in the larger window, then fit it.
            settleTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard let self, !Task.isCancelled, self.companion.phase == phase else { return }
                self.setFrame(target, display: true)
            }
        } else {
            setFrame(target, display: true)
        }
        orderFrontRegardless()
        guard phase == .expanded else { return }
        makeKey()  // the user clicked it; the keys above need key status (as the music island does)
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.companion.collapse() }
        }
    }

    private func removeMonitor() {
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
    }
}

// MARK: Views

/// The cat: the live rig, or a still of it when rendering for QA.
struct CompanionCat: View {
    let rig: PetRig
    @Environment(\.hubStaticRender) private var staticRender

    var body: some View {
        Group {
            if staticRender, let still = rig.still() {
                Image(decorative: still, scale: 2)
            } else {
                CompanionRigView(rig: rig)
            }
        }
        .frame(width: CompanionGeometry.catSize, height: CompanionGeometry.catSize * 100 / 120)
        .accessibilityHidden(true)
    }
}

private struct CompanionRigView: NSViewRepresentable {
    let rig: PetRig
    func makeNSView(context: Context) -> PetRigView { PetRigView(rig: rig) }
    func updateNSView(_ view: PetRigView, context: Context) {}
}

extension View {
    /// Files dropped here go to `session` through `attach` (file URLs only; §23).
    func attachDrop(_ session: AgentSession?, _ attach: @escaping ([URL], AgentSession) -> Void) -> some View {
        modifier(AttachDrop(session: session, attach: attach))
    }
}

private struct AttachDrop: ViewModifier {
    let session: AgentSession?
    let attach: ([URL], AgentSession) -> Void
    @Environment(\.hubStaticRender) private var staticRender

    func body(content: Content) -> some View {
        if staticRender {
            content  // ImageRenderer can't draw drop targets; QA renders skip them
        } else {
            content.onDrop(of: [.fileURL], isTargeted: nil) { providers in
                guard let session else { return false }
                Task { @MainActor in attach(await SessionAttachment.urls(from: providers), session) }
                return true
            }
        }
    }
}

struct NotchCompanionView: View {
    let companion: NotchCompanion
    let hub: AIHubService
    let rig: PetRig
    let actions: CompanionActions
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    @Environment(\.orbitReduceMotion) private var orbitReduceMotion

    var body: some View {
        let phase = companion.phase
        let reduce = systemReduceMotion || orbitReduceMotion
        let size = CompanionGeometry.size(phase)
        let radius = phase == .expanded ? 24 : size.height / 2
        let shoulder: CGFloat = phase == .expanded ? NotchStyle.attachedShoulder : 6
        ZStack(alignment: .topLeading) {
            if phase != .hidden {
                Color.clear.notchSurface(bottomRadius: radius, shoulder: shoulder)
                Group {
                    switch phase {
                    case .expanded: ExpandedCompanion(companion: companion, hub: hub, rig: rig, actions: actions)
                    case .compact: CompactCompanion(companion: companion, rig: rig, actions: actions)
                    default: IdleCompanion(companion: companion, rig: rig)
                    }
                }
                .padding(.horizontal, shoulder)
                .transition(reduce ? AnyTransition.opacity : AnyTransition.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
            }
        }
        .frame(width: size.width, height: size.height, alignment: .top)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduce ? .easeOut(duration: 0.12) : .spring(duration: 0.32, bounce: 0.12), value: phase)
    }
}

/// The cat peeking out; a click opens the sessions.
private struct IdleCompanion: View {
    let companion: NotchCompanion
    let rig: PetRig

    var body: some View {
        Button(action: companion.tap) { CompanionCat(rig: rig).frame(maxWidth: .infinity, maxHeight: .infinity) }
            .buttonStyle(.plain)
            .accessibilityLabel("Orbit companion. No agent needs you.")
            .accessibilityHint("Shows your agent sessions")
            .help("Agent sessions")
    }
}

/// One line of live activity: the cat, who, what; the other sessions' marks to jump to them.
private struct CompactCompanion: View {
    let companion: NotchCompanion
    let rig: PetRig
    let actions: CompanionActions

    var body: some View {
        let lead = companion.lead
        let tone = companion.flash?.tone ?? lead?.tone ?? .quiet
        let headline = companion.flash.map { $0.tone == .failed ? (lead?.headline ?? "Failed") : "Finished" } ?? lead?.headline ?? "Working"
        let others = companion.rows.filter { $0.id != lead?.id }
        HStack(spacing: 8) {
            Button(action: companion.tap) {
                HStack(spacing: 8) {
                    CompanionCat(rig: rig).padding(.leading, 6)
                    if let lead { AgentAvatar(agent: lead.session.key.agent, size: 16) }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(lead.map(Self.title) ?? "Agents").font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
                        Text(headline).font(HubTokens.bodyStrong).foregroundStyle(HubTokens.textPrimary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if lead?.pending.isEmpty == false {  // a request waiting in Orbit, rather than "needs you" somewhere else
                        Image(systemName: "lock.shield.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(HubTokens.attention)
                    } else {
                        ToneMark(tone: tone)
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(label(lead: lead, tone: tone, headline: headline))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint("Shows your agent sessions")
            ForEach(others.prefix(3)) { row in
                Button { companion.open(row.id) } label: {
                    AgentAvatar(agent: row.session.key.agent, size: 16)
                        .overlay(alignment: .bottomTrailing) { Circle().fill(ToneMark.color(row.tone)).frame(width: 6, height: 6) }
                }
                .buttonStyle(.plain)
                .help("\(Self.title(row)): \(row.headline)")
                .accessibilityLabel("Open \(Self.title(row)), \(AgentDiscovery.displayName(for: row.session.key.agent)), \(ToneMark.word(row.tone))")
            }
            if others.count > 3 { HubTag(text: "+\(others.count - 3)") }
        }
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .attachDrop(lead?.session) { urls, session in
            companion.open(session.key)
            actions.attach(urls, session)
        }
    }

    static func title(_ row: NotchCompanion.Row) -> String { row.session.title ?? AgentDiscovery.displayName(for: row.session.key.agent) }

    private func label(lead: NotchCompanion.Row?, tone: NotchCompanion.Tone, headline: String) -> String {
        let who = lead.map { AgentDiscovery.displayName(for: $0.session.key.agent) } ?? "Agents"
        let more = companion.rows.count - 1
        return "\(who), \(ToneMark.word(tone)): \(headline)" + (more > 0 ? ". \(more) more session\(more == 1 ? "" : "s")" : "")
            + (companion.approvals > 0 ? ". \(companion.approvals) request\(companion.approvals == 1 ? "" : "s") waiting" : "")
    }
}

/// Status as symbol + colour (the word is in the accessibility label and the pill).
struct ToneMark: View {
    let tone: NotchCompanion.Tone

    static func word(_ tone: NotchCompanion.Tone) -> String {
        switch tone {
        case .attention: "needs you"
        case .failed: "failed"
        case .working: "working"
        case .finished: "finished"
        case .quiet: "quiet"
        }
    }

    static func color(_ tone: NotchCompanion.Tone) -> Color {
        switch tone {
        case .attention: HubTokens.attention
        case .failed: HubTokens.failure
        case .working, .finished: HubTokens.running
        case .quiet: HubTokens.quiet
        }
    }

    var body: some View {
        let symbol = switch tone {
        case .attention: "hand.raised.fill"
        case .failed: "xmark.octagon.fill"
        case .working: "circle.dotted.circle"
        case .finished: "checkmark.circle.fill"
        case .quiet: "moon.zzz"
        }
        Image(systemName: symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(Self.color(tone))
    }
}

/// Sessions to switch between; the selected one's controls and its Activity, Changes and Requests.
private struct ExpandedCompanion: View {
    let companion: NotchCompanion
    let hub: AIHubService
    let rig: PetRig
    let actions: CompanionActions

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                CompanionCat(rig: rig)
                HubScroll(axes: .horizontal) {
                    HStack(spacing: 4) {
                        ForEach(Array(companion.rows.enumerated()), id: \.element.id) { index, row in chip(row, position: index) }
                    }
                }
                Button(action: companion.collapse) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(HubButtonStyle(kind: .quiet)).help("Close (Esc)").accessibilityLabel("Close")
            }
            .frame(height: 34)
            if let row = companion.selectedRow {
                HStack(alignment: .top, spacing: 12) {
                    details(row).frame(width: 170, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 6) {
                        tabs(row)
                        switch companion.tab {
                        case .activity: ActivityList(companion: companion)
                        case .changes: DiffPreview(companion: companion)
                        case .requests: RequestsPanel(companion: companion, hub: hub, row: row)
                        }
                    }
                }
            } else {
                Text("No agent sessions right now").font(HubTokens.bodyStrong).foregroundStyle(HubTokens.textSecondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let notice = companion.notice {
                Label(notice, systemImage: "doc.on.clipboard").font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 10)
    }

    private func chip(_ row: NotchCompanion.Row, position: Int) -> some View {
        let selected = row.id == companion.selectedRow?.id
        return Button { companion.select(row.id) } label: {
            HStack(spacing: 5) {
                AgentAvatar(agent: row.session.key.agent, size: 14)
                Text(row.session.title ?? row.session.key.nativeID).font(HubTokens.caption).lineLimit(1).truncationMode(.middle).frame(maxWidth: 96)
                if !row.pending.isEmpty { Image(systemName: "lock.shield.fill").font(.system(size: 9)).foregroundStyle(HubTokens.attention) }
                ToneMark(tone: row.tone).scaleEffect(0.8)
            }
            .padding(.horizontal, 7).padding(.vertical, 4)
            .foregroundStyle(selected ? HubTokens.textPrimary : HubTokens.textSecondary)
            .background(selected ? HubTokens.surfaceSelected : HubTokens.surface, in: .capsule)
            .overlay(Capsule().strokeBorder(selected ? HubTokens.borderStrong : HubTokens.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .attachDrop(row.session, actions.attach)
        .accessibilityLabel("\(CompactCompanion.title(row)), \(AgentDiscovery.displayName(for: row.session.key.agent)), \(ToneMark.word(row.tone))"
            + (row.pending.isEmpty ? "" : ", \(row.pending.count) request\(row.pending.count == 1 ? "" : "s") waiting"))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .help(position < 6 ? "\(position + 1) or ← → to switch; drop files to copy their paths for it" : "← → to switch")
    }

    private func tabs(_ row: NotchCompanion.Row) -> some View {
        HStack(spacing: 4) {
            ForEach(NotchCompanion.Tab.allCases) { tab in
                let on = companion.tab == tab
                Button { companion.show(tab) } label: {
                    HStack(spacing: 3) {
                        Text(tab.rawValue)
                        if tab == .requests, !row.pending.isEmpty { HubTag(text: "\(row.pending.count)", tint: HubTokens.attention) }
                    }
                    .font(HubTokens.caption)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .foregroundStyle(on ? HubTokens.textPrimary : HubTokens.textSecondary)
                    .background(on ? HubTokens.surfaceSelected : .clear, in: .capsule)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
            }
        }
    }

    private func details(_ row: NotchCompanion.Row) -> some View {
        let session = row.session
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Text(AgentDiscovery.displayName(for: session.key.agent)).font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
                if session.isDemo { HubTag(text: "SIM") }
            }
            StatusPill(status: row.pending.isEmpty ? HubStatus.of(session.status, waiting: hub.waitingPlace(of: session))
                       : HubStatus(label: row.pending.count == 1 ? "Request waiting" : "\(row.pending.count) requests waiting",
                                   symbol: "lock.shield", color: HubTokens.attention))
            Text(row.headline).font(HubTokens.body).foregroundStyle(HubTokens.textPrimary).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            if let project = HubFormat.project(session.cwd) {
                Text(project).font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary).lineLimit(1).truncationMode(.middle)
            }
            HStack(spacing: 4) {
                if let app = hub.originName(of: session) {
                    Button { actions.openApp(session) } label: { Image(systemName: "terminal") }
                        .help("Bring \(app) to the front (Return)").accessibilityLabel("Open \(app)")
                }
                if session.cwd != nil, !session.isDemo {
                    Button { actions.showProject(session) } label: { Image(systemName: "folder") }
                        .help("Show the project in Finder").accessibilityLabel("Show in Finder")
                }
                Button { actions.openInHub(session) } label: { Label("AI Hub", systemImage: "rectangle.on.rectangle") }
                    .help("Open this session in the AI Hub")
            }
            .buttonStyle(HubButtonStyle(kind: .secondary, font: HubTokens.caption))
            Spacer(minLength: 0)
        }
        .contentShape(.rect)
        .attachDrop(session, actions.attach)
    }
}

/// The selected session's latest events, newest first.
private struct ActivityList: View {
    let companion: NotchCompanion

    var body: some View {
        if companion.activity.isEmpty {
            Text("No activity yet").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary).frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            HubScroll {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(companion.activity) { event in
                        HStack(spacing: 6) {
                            Image(systemName: EventStyle.symbol(event.kind)).font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(EventStyle.color(event.kind)).frame(width: 12)
                            Text(event.summary ?? event.nativeName).font(HubTokens.caption).foregroundStyle(HubTokens.textPrimary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(event.receivedAt.formatted(date: .omitted, time: .shortened)).font(HubTokens.caption.monospacedDigit())
                                .foregroundStyle(HubTokens.textTertiary)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

/// The selected session's waiting requests (answerable ones only) and its decision history.
private struct RequestsPanel: View {
    let companion: NotchCompanion
    let hub: AIHubService
    let row: NotchCompanion.Row

    var body: some View {
        HubScroll {
            VStack(alignment: .leading, spacing: 8) {
                if row.session.key.agent.rawValue == "claude-code" {
                    Label("Claude Code asks in \(hub.coucouAnswersClaude ? "Coucou or its terminal" : "its terminal"); Orbit only observes it.",
                          systemImage: "info.circle").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
                }
                let requests = hub.approvals.pending.filter { $0.draft.session == row.id }
                ForEach(requests) { request in RequestCard(hub: hub, request: request) }
                if let error = hub.browser.decisionError {
                    Label(error, systemImage: "exclamationmark.triangle.fill").font(HubTokens.caption).foregroundStyle(HubTokens.failure)
                }
                let history = hub.approvals.history.filter { $0.draft.session == row.id }.prefix(4)
                if !history.isEmpty {
                    Text("EARLIER").font(HubTokens.micro).foregroundStyle(HubTokens.textTertiary)
                    ForEach(Array(history)) { record in
                        HStack(spacing: 6) {
                            Image(systemName: Self.symbol(record.outcome)).foregroundStyle(Self.color(record.outcome)).font(.system(size: 10))
                            Text(record.answer ?? record.draft.summary).font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(record.outcome.rawValue).font(HubTokens.micro).foregroundStyle(Self.color(record.outcome))
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
                if requests.isEmpty, history.isEmpty, row.session.key.agent.rawValue != "claude-code" {
                    Text("No requests from this session").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
                }
            }
        }
    }

    static func symbol(_ outcome: ApprovalManager.Outcome) -> String {
        switch outcome {
        case .allowed: "checkmark.circle.fill"
        case .denied: "xmark.circle.fill"
        case .answered: "text.bubble.fill"
        case .expired: "timer"
        case .withdrawn: "arrow.uturn.backward.circle"
        }
    }

    static func color(_ outcome: ApprovalManager.Outcome) -> Color {
        switch outcome {
        case .allowed, .answered: HubTokens.running
        case .denied: HubTokens.failure
        case .expired, .withdrawn: HubTokens.quiet
        }
    }
}

/// One waiting request: what it wants (every line of the input), time left, and the answers its adapter allows.
private struct RequestCard: View {
    let hub: AIHubService
    let request: ApprovalManager.Request

    var body: some View {
        let draft = request.draft
        let live = draft.expiresAt > .now
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Image(systemName: draft.kind == .question ? "questionmark.bubble.fill" : "lock.shield.fill").foregroundStyle(HubTokens.attention)
                Text(draft.kind == .question ? "Asks" : "Wants to run \(draft.tool ?? "a tool")").font(HubTokens.caption).foregroundStyle(HubTokens.attention)
                if request.isSimulated { HubTag(text: "SIM") }
                Spacer(minLength: 4)
                if live {
                    // SwiftUI updates the countdown itself: no timer of Orbit's.
                    Text(timerInterval: Date.now ... draft.expiresAt, countsDown: true).font(HubTokens.caption.monospacedDigit())
                        .foregroundStyle(HubTokens.textTertiary).frame(width: 40, alignment: .trailing)
                } else {
                    Text("Expired").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
                }
            }
            Text(draft.summary).font(HubTokens.bodyStrong).foregroundStyle(HubTokens.textPrimary).fixedSize(horizontal: false, vertical: true)
            if let detail = draft.detail, !draft.summary.hasSuffix(detail) {
                Text(detail).font(HubTokens.mono).foregroundStyle(HubTokens.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)  // every line: this is what would be allowed
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.black.opacity(0.3), in: .rect(cornerRadius: HubTokens.radiusSmall))
            }
            if !hub.canAnswer(draft) {
                Text("Orbit can't answer this agent: it asks you itself.").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
            } else if !draft.questions.isEmpty {
                QuestionForm(questions: draft.questions, enabled: live, compact: true) { answers in
                    _ = hub.browser.decide(request, .answers(answers), in: hub.approvals)
                }
            } else {
                HStack(spacing: 6) {
                    Spacer()
                    if draft.kind == .permission {
                        Button("Deny") { _ = hub.browser.decide(request, .deny, in: hub.approvals) }
                            .buttonStyle(HubButtonStyle(kind: .destructive, font: HubTokens.caption))
                        Button("Allow Once") { _ = hub.browser.decide(request, .allowOnce, in: hub.approvals) }
                            .buttonStyle(HubButtonStyle(kind: .primary, font: HubTokens.caption))
                    } else {
                        ForEach(draft.options, id: \.self) { option in
                            Button(option) { _ = hub.browser.decide(request, .answer(option), in: hub.approvals) }
                                .buttonStyle(HubButtonStyle(kind: .secondary, font: HubTokens.caption))
                        }
                    }
                }
                .disabled(!live)
            }
        }
        .padding(8)
        .background(HubTokens.surfaceRaised, in: .rect(cornerRadius: HubTokens.radius))
        .overlay { RoundedRectangle(cornerRadius: HubTokens.radius).strokeBorder(HubTokens.attention.opacity(0.4), lineWidth: 1) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.isSimulated ? "Simulated " : "")\(draft.kind == .question ? "question" : "request") from "
            + "\(AgentDiscovery.displayName(for: draft.session.agent)): \(draft.summary)" + (draft.detail.map { ". Full input: \($0)" } ?? ""))
    }
}

/// The selected session's changed files (its own first) and one file's diff, from the first hunk.
private struct DiffPreview: View {
    let companion: NotchCompanion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let changes = companion.changes {
                if let refused = changes.refused {
                    note("Not inspected: \(refused).", color: HubTokens.attention)
                } else if changes.files.isEmpty {
                    note("No uncommitted changes")
                } else {
                    HubScroll(axes: .horizontal) {
                        HStack(spacing: 4) {
                            ForEach(changes.files.prefix(12)) { file in fileChip(file) }
                        }
                    }
                    .frame(height: 22)
                    diff
                }
            } else if companion.loadingChanges {
                note("Reading the repository…")
            } else {
                note(companion.selectedRow?.session.isDemo == true ? "Simulated sessions have no repository." : "No repository for this session.")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func fileChip(_ file: CodeChangeService.FileChange) -> some View {
        let shown = file.path == companion.diffPath
        return Button { companion.showDiff(file.path) } label: {
            HStack(spacing: 3) {
                if file.touchedBySession { Circle().fill(HubTokens.running).frame(width: 5, height: 5) }
                Text((file.path as NSString).lastPathComponent).lineLimit(1)
            }
            .font(HubTokens.caption)
            .padding(.horizontal, 6).padding(.vertical, 3)
            .foregroundStyle(shown ? HubTokens.textPrimary : HubTokens.textSecondary)
            .background(shown ? HubTokens.surfaceSelected : HubTokens.surface, in: .capsule)
        }
        .buttonStyle(.plain)
        .help("↑ ↓ to step through the files")
        .accessibilityLabel(file.path + (file.touchedBySession ? ", changed by this session" : ""))
        .accessibilityAddTraits(shown ? [.isButton, .isSelected] : .isButton)
    }

    private var diff: some View {
        // From the first hunk: the file name is already on its chip.
        let all = (companion.diffText ?? "").split(separator: "\n", omittingEmptySubsequences: false)
        let lines = all[(all.firstIndex { $0.hasPrefix("@@") } ?? all.startIndex)...].prefix(80)
        return HubScroll {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : String(line)).font(HubTokens.mono).foregroundStyle(DiffStyle.color(line))
                        .lineLimit(1).frame(maxWidth: .infinity, alignment: .leading).background(DiffStyle.background(line))
                }
            }
        }
        .padding(6)
        .background(HubTokens.surface, in: .rect(cornerRadius: HubTokens.radiusSmall))
        .accessibilityLabel("Diff of \(companion.diffPath ?? "the file")")
    }

    private func note(_ text: String, color: Color = HubTokens.textTertiary) -> some View {
        Text(text).font(HubTokens.caption).foregroundStyle(color).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

extension PetRig {
    /// The rig as it rests now (no motion), for render-based QA.
    func still(scale: CGFloat = 2) -> CGImage? {
        let size = root.bounds.size
        guard size.width > 0, let context = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        root.render(in: context)
        return context.makeImage()
    }
}
