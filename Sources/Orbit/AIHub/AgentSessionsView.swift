import AppKit
import SwiftUI

// AI Hub 2.0: the dashboard's AI Hub section as a compact developer workspace
// (about 708 × 330 pt). A slim rail replaces the second tab row; Overview is
// the command centre; Agents pushes into a session's detail; Approvals,
// Insights and Chat each get a purpose-built layout. Simulated sessions are
// always labelled, "waiting" always says inferred, and Claude Code never gets
// Allow/Deny controls (D1).

/// The section's view state (a model: no @State macro with the Command Line Tools).
@MainActor @Observable
final class AgentBrowser {
    enum Page: String, CaseIterable, Identifiable {
        case overview = "Overview", agents = "Agents", approvals = "Approvals", insights = "Insights", chat = "Chat"
        var id: Self { self }

        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .agents: "cpu"
            case .approvals: "checkmark.shield"
            case .insights: "chart.bar.xaxis"
            case .chat: "bubble.left.and.text.bubble.right"
            }
        }
    }

    enum Scope: String, CaseIterable, Identifiable {
        case real = "Real", simulated = "Simulated"
        var id: Self { self }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", active = "Active", waiting = "Needs you", finished = "Finished"
        var id: Self { self }

        func includes(_ status: AgentSession.Status) -> Bool {
            switch self {
            case .all: true
            case .active: status == .running || status == .idle
            case .waiting: status == .waiting
            case .finished: !status.isActive
            }
        }
    }

    enum DetailTab: String, CaseIterable, Identifiable {
        case timeline = "Timeline", changes = "Changes"
        var id: Self { self }
    }

    var page = Page.overview
    var scope = Scope.real
    var filter = Filter.all
    var search = ""
    var selected: SessionKey?
    var detailTab = DetailTab.timeline
    var showsApprovalHistory = false
    /// The selected session's saved timeline (live events are merged in by the view).
    var timeline: [AgentEvent] = []
    /// The selected session's repository state (Phase 5), loaded on selection.
    var changes: CodeChangeService.Snapshot?
    var diffPath: String?
    var diffText: String?
    /// "Copied" confirmation, shown for a moment after a copy.
    private(set) var copied = false
    /// Why the last approval decision didn't go through (shown until dismissed or the next one succeeds).
    var decisionError: String?
    @ObservationIgnored private var copiedGeneration = 0

    /// Copies `text`, confirms on screen for 2 s and to VoiceOver.
    func copy(_ text: String, to pasteboard: NSPasteboard = .general, confirmFor duration: Duration = .seconds(2)) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        copied = true
        copiedGeneration += 1
        let current = copiedGeneration
        announce("Copied")
        Task { [weak self] in
            try? await Task.sleep(for: duration)
            if self?.copiedGeneration == current { self?.copied = false }
        }
    }

    /// A decision through the Approval Center; when it can't be made, says why.
    @discardableResult
    func decide(_ request: ApprovalManager.Request, _ decision: ApprovalDecision, in approvals: ApprovalManager) -> Bool {
        if approvals.decide(request.id, decision) {
            decisionError = nil
            return true
        }
        let gone = !approvals.pending.contains { $0.id == request.id }
        decisionError = gone ? "That request is no longer waiting: it was answered, expired or withdrawn by the agent."
            : request.draft.expiresAt <= .now ? "That request expired; the agent asks you itself."
            : "That answer isn't one the agent offered, so nothing was sent."
        announce(decisionError!)
        return false
    }

    private func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// Sessions matching the filter and search (title, project path, agent), most recent first.
    static func visible(_ sessions: [AgentSession], filter: Filter, search: String) -> [AgentSession] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        return sessions.filter { session in
            guard filter.includes(session.status) else { return false }
            guard !needle.isEmpty else { return true }
            return [session.title, session.cwd, session.key.agent.rawValue, AgentDiscovery.displayName(for: session.key.agent)]
                .compactMap { $0?.lowercased() }.contains { $0.contains(needle) }
        }
    }

    /// One list by event ID, oldest first.
    static func merge(_ stored: [AgentEvent], _ live: [AgentEvent]) -> [AgentEvent] {
        var seen = Set<UUID>()
        return (stored + live).filter { seen.insert($0.id).inserted }.sorted { $0.receivedAt < $1.receivedAt }
    }

    /// Opens a session's detail and loads its timeline and repository state (git runs off the main thread).
    func select(_ session: AgentSession, in hub: AIHubService) {
        page = .agents
        scope = session.isDemo ? .simulated : .real
        selected = session.key
        detailTab = .timeline
        timeline = []
        changes = nil
        diffPath = nil
        diffText = nil
        Task {
            let events = await hub.timeline(for: session)
            guard selected == session.key else { return }
            timeline = events
            guard !session.isDemo, let cwd = session.cwd else { return }
            let snapshot = await CodeChangeService.snapshot(of: cwd, touched: Set(events.flatMap(\.files)))
            if selected == session.key { changes = snapshot }
        }
    }

    func showDiff(_ path: String) {
        guard let root = changes?.root else { return }
        diffPath = path
        diffText = nil
        Task {
            let text = await CodeChangeService.diff(of: path, in: root)
            // git prints nothing for an untracked file: say so rather than show a blank panel.
            if diffPath == path { diffText = text.flatMap { $0.isEmpty ? nil : $0 } ?? "No diff (new or binary file)." }
        }
    }
}

// MARK: Page

struct AIHubPage: View {
    let hub: AIHubService
    let chat: [DashboardModel.PlacedWidget]
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        let browser = hub.browser
        HStack(alignment: .top, spacing: HubTokens.s3) {
            HubRail(hub: hub)
            Group {
                switch browser.page {
                case .overview: OverviewScreen(hub: hub)
                case .agents:
                    if let key = browser.selected, let session = (browser.scope == .real ? hub.real : hub.demo).sessions[key] {
                        SessionDetailScreen(hub: hub, session: session)
                    } else {
                        AgentsScreen(hub: hub)
                    }
                case .approvals: ApprovalsScreen(hub: hub)
                case .insights: InsightsScreen(hub: hub)
                case .chat:
                    if hub.isEnabled { ChatScreen(chat: hub.chat) } else { CategorySection(widgets: chat) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(browser.page)
            .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 6)))
        }
        .animation(reduceMotion ? nil : HubTokens.move, value: browser.page)
        .animation(reduceMotion ? nil : HubTokens.move, value: browser.selected)
    }
}

/// The section's own navigation: a slim vertical rail (Orbit's tabs stay on top).
private struct HubRail: View {
    let hub: AIHubService

    var body: some View {
        VStack(spacing: 2) {
            ForEach(Array(AgentBrowser.Page.allCases.enumerated()), id: \.element) { index, page in
                let selected = hub.browser.page == page
                let badge = page == .approvals ? hub.approvals.pending.count : 0
                Button {
                    hub.browser.page = page
                    if page == .agents { hub.browser.selected = nil }
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: page.symbol).font(.system(size: 14, weight: selected ? .semibold : .regular))
                            .overlay(alignment: .topTrailing) {
                                if badge > 0 {
                                    Text("\(badge)").font(.system(size: 8.5, weight: .bold)).foregroundStyle(.black)
                                        .padding(.horizontal, 3.5).padding(.vertical, 1)
                                        .background(HubTokens.attention, in: .capsule).offset(x: 9, y: -6)
                                }
                            }
                        Text(page.rawValue).font(.system(size: 9, weight: .medium)).lineLimit(1).minimumScaleFactor(0.8)
                    }
                    .foregroundStyle(selected ? HubTokens.textPrimary : HubTokens.textTertiary)
                    .frame(width: 58, height: 44)
                }
                .buttonStyle(HubRowStyle(isSelected: selected))
                .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                .help("\(page.rawValue) (⌘\(index + 1))")
                .accessibilityLabel(badge > 0 ? "\(page.rawValue), \(badge) pending" : page.rawValue)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
            Spacer(minLength: 0)
            BridgeDot(hub: hub)
        }
        .frame(width: 58)
    }
}

/// The bridge's state at the foot of the rail.
private struct BridgeDot: View {
    let hub: AIHubService

    var body: some View {
        let (label, color): (String, Color) = switch hub.health.bridge {
        case .listening: ("Live", HubTokens.running)
        case .off: ("Off", HubTokens.quiet)
        case .failed: ("Error", HubTokens.failure)
        }
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(HubTokens.textTertiary)
        }
        .padding(.bottom, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Agent bridge: \(label)")
    }
}

// MARK: Overview

private struct OverviewScreen: View {
    let hub: AIHubService

    var body: some View {
        if !hub.isEnabled {
            HubEmptyState(symbol: "sparkles", title: "Your AI agents, at a glance",
                          message: "Turn on the AI Hub to follow coding agents on this Mac: their sessions, what they change and when they need you. Everything stays on this Mac.",
                          action: ("Open AI Hub Settings", { openHubSettings() }))
        } else {
            let real = Array(hub.real.sessions.values)
            let simulated = Array(hub.demo.sessions.values)
            let isActive = { (s: AgentSession) in s.status == .running || s.status == .idle }
            let active = (real + simulated).filter(isActive).sorted { $0.lastEventAt > $1.lastEventAt }
            let waiting = (real + simulated).filter { $0.status == .waiting }
            let realApprovals = hub.approvals.pending.filter { !$0.isSimulated }.count
            let today = Calendar.current.startOfDay(for: .now)
            let simulatedNote = { (n: Int) in n > 0 ? " · +\(n) sim." : "" }
            HubScroll {
            VStack(alignment: .leading, spacing: HubTokens.s2) {
                HStack(spacing: HubTokens.s2) {  // totals count real agents; simulated ones are noted, never added
                    HubMetric(value: "\(real.filter(isActive).count)", label: "Active" + simulatedNote(simulated.filter(isActive).count),
                              symbol: "circle.dotted.circle", tint: real.contains(where: isActive) ? HubTokens.running : HubTokens.textPrimary)
                    HubMetric(value: "\(real.filter { $0.status == .waiting }.count + realApprovals)",
                              label: "Needs you" + simulatedNote(simulated.filter { $0.status == .waiting }.count + hub.approvals.pending.count - realApprovals),
                              symbol: "hand.raised",
                              tint: real.contains { $0.status == .waiting } || realApprovals > 0 ? HubTokens.attention : HubTokens.textPrimary)
                    HubMetric(value: "\(real.filter { !$0.status.isActive && $0.lastEventAt >= today }.count)", label: "Finished today",
                              symbol: "checkmark.circle")
                    HubMetric(value: "\(hub.agents.filter(\.isInstalled).count)", label: "Agents on this Mac", symbol: "cpu")
                }
                HStack(alignment: .top, spacing: HubTokens.s3) {
                    HubPanel(padding: HubTokens.s2) {
                        VStack(alignment: .leading, spacing: HubTokens.s1) {
                            HubSectionHeader(title: "Live sessions") {
                                Button("All sessions") { hub.browser.page = .agents; hub.browser.selected = nil }
                                    .buttonStyle(HubButtonStyle(kind: .quiet, font: HubTokens.caption))
                            }
                            .padding(.horizontal, HubTokens.s1)
                            if active.isEmpty && waiting.isEmpty {
                                Text(hub.isDemoEnabled ? "Simulated sessions start in a few seconds…"
                                     : "No agent is working right now. Connect an agent in Settings › AI Hub, or turn on demo mode to see how it looks.")
                                    .font(HubTokens.body).foregroundStyle(HubTokens.textSecondary)
                                    .padding(HubTokens.s1).fixedSize(horizontal: false, vertical: true)
                            }
                            ForEach((waiting + active).prefix(3)) { session in SessionCard(hub: hub, session: session, compact: true) }
                            if waiting.count + active.count > 3 {
                                Button("+\(waiting.count + active.count - 3) more") { hub.browser.page = .agents; hub.browser.selected = nil }
                                    .buttonStyle(HubButtonStyle(kind: .quiet, font: HubTokens.caption))
                            }
                            Spacer(minLength: 0)
                            RecentActivity(hub: hub)
                        }
                    }
                    VStack(alignment: .leading, spacing: HubTokens.s2) {
                        AttentionPanel(hub: hub, waiting: waiting)
                        StatusPanel(hub: hub)
                    }
                    .frame(width: 218)
                }
            }
            }
        }
    }
}

private struct RecentActivity: View {
    let hub: AIHubService

    var body: some View {
        let events = (hub.real.recentEvents.values.flatMap { $0 } + hub.demo.recentEvents.values.flatMap { $0 })
            .sorted { $0.receivedAt > $1.receivedAt }.prefix(3)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HubSectionHeader(title: "Recent")
                ForEach(Array(events)) { event in
                    HStack(spacing: 6) {
                        Image(systemName: EventStyle.symbol(event.kind)).font(.system(size: 9)).foregroundStyle(EventStyle.color(event.kind)).frame(width: 12)
                        Text(event.summary ?? event.nativeName).font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
                        if event.session.agent.isDemo { HubTag(text: "SIM") }
                        Spacer(minLength: 4)
                        Text(event.receivedAt, format: .dateTime.hour().minute()).font(HubTokens.caption.monospacedDigit()).foregroundStyle(HubTokens.textTertiary)
                    }
                }
            }
            .padding(.horizontal, HubTokens.s1)
        }
    }
}

private struct AttentionPanel: View {
    let hub: AIHubService
    let waiting: [AgentSession]

    var body: some View {
        let count = hub.approvals.pending.count + waiting.count
        HubPanel(padding: HubTokens.s2, tint: count > 0 ? HubTokens.attention : nil) {
            VStack(alignment: .leading, spacing: 6) {
                HubSectionHeader(title: "Needs attention")
                if count == 0 {
                    Label("All clear", systemImage: "checkmark.seal").font(HubTokens.bodyStrong).foregroundStyle(HubTokens.textSecondary)
                }
                ForEach(hub.approvals.pending.prefix(3)) { request in
                    Button { hub.browser.page = .approvals } label: {
                        AttentionRow(agent: request.draft.session.agent, title: request.draft.summary,
                                     detail: (request.draft.kind == .question ? "Question" : "Approval") + " · " + AgentDiscovery.displayName(for: request.draft.session.agent))
                    }
                    .buttonStyle(HubRowStyle()).help(request.draft.summary)
                }
                ForEach(waiting.prefix(max(0, 3 - hub.approvals.pending.count))) { session in
                    Button { hub.browser.select(session, in: hub) } label: {
                        AttentionRow(agent: session.key.agent, title: session.title ?? session.key.nativeID,
                                     detail: (hub.waitingPlace(of: session)?.label ?? "Needs you") + " · inferred · " + AgentDiscovery.displayName(for: session.key.agent))
                    }
                    .buttonStyle(HubRowStyle()).help(session.title ?? session.key.nativeID)
                }
                if count > 3 { Text("+\(count - 3) more").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary) }
            }
        }
    }
}

private struct AttentionRow: View {
    let agent: AgentID
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: 6) {
            AgentAvatar(agent: agent, size: 18)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(HubTokens.caption).foregroundStyle(HubTokens.textPrimary).lineLimit(1)
                Text(detail).font(HubTokens.caption).foregroundStyle(HubTokens.attention).lineLimit(1)
            }
            Spacer(minLength: 0)
            if agent.isDemo { HubTag(text: "SIM") }
        }
        .padding(3)
    }
}

private struct StatusPanel: View {
    let hub: AIHubService

    var body: some View {
        HubPanel(padding: HubTokens.s2) {
            VStack(alignment: .leading, spacing: 5) {
                HubSectionHeader(title: "System")
                statusRow("Agent bridge", hub.health.bridge == .listening ? "Live on this Mac" : "Unavailable",
                          ok: hub.health.bridge == .listening)
                statusRow("History", { if case .degraded = hub.health.store { "Not saving" } else { "Saved locally" } }(),
                          ok: { if case .degraded = hub.health.store { false } else { true } }())
                statusRow("Integrations", "None connected", ok: nil)
                if case .failed(let reason) = hub.health.bridge {
                    Text(reason).font(HubTokens.caption).foregroundStyle(HubTokens.attention).lineLimit(2)
                }
                Button("AI Hub Settings…") { openHubSettings() }.buttonStyle(HubButtonStyle(kind: .secondary, font: HubTokens.caption))
            }
        }
    }

    private func statusRow(_ label: String, _ value: String, ok: Bool?) -> some View {
        HStack(spacing: 5) {
            Image(systemName: ok == nil ? "minus.circle" : ok! ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 9)).foregroundStyle(ok == nil ? HubTokens.quiet : ok! ? HubTokens.running : HubTokens.attention)
            Text(label).font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
            Spacer(minLength: 4)
            Text(value).font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }
}

@MainActor private func openHubSettings() {
    NotificationCenter.default.post(name: SettingsWindowController.showRequest, object: SettingsSection.aiHub.rawValue)
}

// MARK: Agents

/// One session: identity, project, what it's doing, state, time.
private struct SessionCard: View {
    let hub: AIHubService
    let session: AgentSession
    var compact = false

    var body: some View {
        let manager = session.isDemo ? hub.demo : hub.real
        let activity = manager.recentEvents[session.key]?.last?.summary
        let status = HubStatus.of(session.status, bridgeUp: hub.health.bridge == .listening, waiting: hub.waitingPlace(of: session))
        Button { hub.browser.select(session, in: hub) } label: {
            HStack(spacing: HubTokens.s2) {
                AgentAvatar(agent: session.key.agent, size: compact ? 22 : 28)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(session.title ?? session.key.nativeID).font(HubTokens.title).foregroundStyle(HubTokens.textPrimary).lineLimit(1)
                        if session.isDemo { HubTag(text: "SIMULATED") }
                    }
                    HStack(spacing: 0) {
                        Text(AgentDiscovery.displayName(for: session.key.agent)).lineLimit(1).fixedSize()
                        if let folder = HubFormat.parent(session.cwd) {
                            Text(" · in ").fixedSize()
                            Text(folder).lineLimit(1).truncationMode(.head)  // the folder's end is the useful part
                        }
                    }
                    .font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
                    if !compact, let activity {
                        Text(activity).font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
                    }
                }
                Spacer(minLength: HubTokens.s2)
                VStack(alignment: .trailing, spacing: 3) {
                    StatusPill(status: status)
                    Text(compact ? "active " + session.lastEventAt.formatted(.relative(presentation: .named))
                         : "active \(session.lastEventAt.formatted(.relative(presentation: .named))) · \(HubFormat.duration(session.lastEventAt.timeIntervalSince(session.startedAt))) long")
                        .font(HubTokens.caption.monospacedDigit()).foregroundStyle(HubTokens.textTertiary).lineLimit(1)
                }
                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(HubTokens.textTertiary)
            }
            .padding(.horizontal, HubTokens.s2)
            .padding(.vertical, compact ? 5 : 7)
        }
        .buttonStyle(HubRowStyle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the session")
    }
}

private struct AgentsScreen: View {
    let hub: AIHubService

    var body: some View {
        let browser = hub.browser
        let manager = browser.scope == .real ? hub.real : hub.demo
        let sessions = AgentBrowser.visible(manager.ordered, filter: browser.filter, search: browser.search)
        VStack(alignment: .leading, spacing: HubTokens.s2) {
            HStack(spacing: HubTokens.s2) {
                if hub.isDemoEnabled || !hub.demo.sessions.isEmpty {
                    SegmentedChips(options: AgentBrowser.Scope.allCases, selection: browser.scope, title: \.rawValue) {
                        browser.scope = $0
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(HubTokens.textTertiary)
                    HubField(placeholder: "Search sessions, projects, agents", text: Binding(get: { browser.search }, set: { browser.search = $0 }))
                }
                .padding(.horizontal, HubTokens.s2).frame(height: 26)
                .background(HubTokens.surface, in: .rect(cornerRadius: HubTokens.radiusSmall))
                .overlay { RoundedRectangle(cornerRadius: HubTokens.radiusSmall).strokeBorder(HubTokens.border, lineWidth: 0.75) }
                SegmentedChips(options: AgentBrowser.Filter.allCases, selection: browser.filter, title: \.rawValue) { browser.filter = $0 }
            }
            if !hub.isEnabled {
                HubEmptyState(symbol: "cpu", title: "The AI Hub is off", message: "Turn it on to see your agents' sessions here.",
                              action: ("Open AI Hub Settings", { openHubSettings() }))
            } else if sessions.isEmpty {
                let filtered = !browser.search.isEmpty || browser.filter != .all
                HubEmptyState(symbol: filtered ? "line.3.horizontal.decrease.circle" : "rectangle.stack",
                              title: filtered ? "No \(browser.filter == .all ? "" : browser.filter.rawValue.lowercased() + " ")sessions match"
                                : (browser.scope == .simulated ? "No simulated sessions" : "No sessions yet"),
                              message: filtered ? "Nothing here with this filter or search."
                                : "Sessions appear when a connected agent starts working. Claude Code connects from Settings › AI Hub.",
                              action: filtered ? ("Show All Sessions", { browser.filter = .all; browser.search = "" }) : nil)
            } else {
                HubScroll {
                    LazyVStack(spacing: 2) { ForEach(sessions) { SessionCard(hub: hub, session: $0) } }
                }
            }
        }
    }
}

/// A compact single-choice control.
private struct SegmentedChips<Option: Hashable>: View {
    let options: [Option]
    let selection: Option
    let title: KeyPath<Option, String>
    let select: (Option) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options, id: \.self) { option in
                let selected = option == selection
                Button { select(option) } label: {
                    Text(option[keyPath: title]).font(HubTokens.caption)
                        .foregroundStyle(selected ? HubTokens.textPrimary : HubTokens.textTertiary)
                        .padding(.horizontal, 8).frame(height: 24)
                        .background(selected ? HubTokens.surfaceRaised : .clear, in: .rect(cornerRadius: HubTokens.radiusSmall - 2))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2)
        .background(HubTokens.surface, in: .rect(cornerRadius: HubTokens.radiusSmall))
        .fixedSize()
    }
}

// MARK: Session detail

private struct SessionDetailScreen: View {
    let hub: AIHubService
    let session: AgentSession

    var body: some View {
        let browser = hub.browser
        let manager = session.isDemo ? hub.demo : hub.real
        let events = AgentBrowser.merge(browser.timeline, manager.recentEvents[session.key] ?? [])
        let status = HubStatus.of(session.status, bridgeUp: hub.health.bridge == .listening, waiting: hub.waitingPlace(of: session))
        VStack(alignment: .leading, spacing: HubTokens.s2) {
            HStack(spacing: HubTokens.s2) {
                Button { browser.selected = nil } label: { Label("Sessions", systemImage: "chevron.left") }
                    .buttonStyle(HubButtonStyle(kind: .quiet))
                    .keyboardShortcut("[", modifiers: .command).help("Back to sessions (⌘[)")
                AgentAvatar(agent: session.key.agent, size: 24)
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 5) {
                        Text(session.title ?? session.key.nativeID).font(HubTokens.title).foregroundStyle(HubTokens.textPrimary).lineLimit(1)
                        if session.isDemo { HubTag(text: "SIMULATED") }
                    }
                    Text([AgentDiscovery.displayName(for: session.key.agent), HubFormat.project(session.cwd),
                          "started \(session.startedAt.formatted(date: .omitted, time: .shortened))",
                          HubFormat.duration(session.lastEventAt.timeIntervalSince(session.startedAt))].compactMap { $0 }.joined(separator: " · "))
                        .font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                StatusPill(status: status)
                if session.originBundleID != nil, !session.isDemo {
                    let target = AgentJump.plan(session)
                    if target != .unavailable {
                        Button { AgentJump.perform(target) } label: {
                            Label(AgentJump.title(target), systemImage: {
                                if case .editorWindow = target { return "macwindow" } else { return "terminal" }
                            }())
                        }
                        .buttonStyle(HubButtonStyle(kind: .secondary)).help(AgentJump.help(target))
                    }
                }
                if session.cwd != nil, !session.isDemo {
                    Button { hub.revealProject(of: session) } label: { Image(systemName: "folder") }
                        .buttonStyle(HubButtonStyle(kind: .secondary)).help("Show the project in Finder").accessibilityLabel("Show in Finder")
                }
            }
            if session.status == .waiting {
                Label(hub.waitingPlace(of: session) == .coucou
                      ? "Inferred from what Claude Code reported. Answer it in Coucou, in the notch; Orbit doesn't answer for it."
                      : "Inferred from what the agent reported. Answer it in its own terminal; Orbit doesn't answer for it.",
                      systemImage: "hand.raised").font(HubTokens.caption).foregroundStyle(HubTokens.attention)
            }
            if let shelf = hub.shelf, let cwd = session.cwd, !session.isDemo {
                ShelfStrip(shelf: shelf, items: shelf.items(inside: cwd))
            }
            SegmentedChips(options: AgentBrowser.DetailTab.allCases, selection: browser.detailTab, title: \.rawValue) { browser.detailTab = $0 }
            switch browser.detailTab {
            case .timeline: TimelineList(events: events)
            case .changes: ChangesPanel(hub: hub, session: session)
            }
        }
    }
}

private struct TimelineList: View {
    let events: [AgentEvent]

    var body: some View {
        if events.isEmpty {
            HubEmptyState(symbol: "clock", title: "No events yet", message: "Events appear here as the agent works.")
        } else {
            HubScroll {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(events.reversed().enumerated()), id: \.element.id) { index, event in
                        HStack(alignment: .top, spacing: HubTokens.s2) {
                            Text(event.receivedAt.formatted(.dateTime.hour().minute().second()))
                                .font(HubTokens.mono).foregroundStyle(HubTokens.textTertiary).lineLimit(1).fixedSize().frame(width: 76, alignment: .leading)
                            VStack(spacing: 0) {
                                Image(systemName: EventStyle.symbol(event.kind)).font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(EventStyle.color(event.kind)).frame(width: 18, height: 18)
                                    .background(EventStyle.color(event.kind).opacity(0.14), in: .circle)
                                if index < events.count - 1 { Rectangle().fill(HubTokens.border).frame(width: 1).frame(maxHeight: .infinity) }
                            }
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 5) {
                                    Text(event.summary ?? event.nativeName).font(HubTokens.body).foregroundStyle(HubTokens.textPrimary)
                                    if let tool = event.tool { HubTag(text: tool) }
                                }
                                // Files only when the summary doesn't already name them.
                                if !event.files.isEmpty, !event.files.allSatisfy({ (event.summary ?? "").contains(($0 as NSString).lastPathComponent) }) {
                                    Text(event.files.map { ($0 as NSString).lastPathComponent }.joined(separator: "  "))
                                        .font(HubTokens.mono).foregroundStyle(HubTokens.textTertiary).lineLimit(1)
                                }
                            }
                            .padding(.bottom, HubTokens.s2)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct ChangesPanel: View {
    let hub: AIHubService
    let session: AgentSession

    var body: some View {
        let browser = hub.browser
        if session.isDemo || session.cwd == nil {
            HubEmptyState(symbol: "doc.badge.ellipsis", title: "No repository",
                          message: session.isDemo ? "Simulated sessions don't have a real project folder." : "This session didn't report a project folder.")
        } else if let changes = browser.changes {
            HStack(alignment: .top, spacing: HubTokens.s3) {
                VStack(alignment: .leading, spacing: 4) {
                    Text([changes.branch.map { "⎇ \($0)" }, changes.commit].compactMap { $0 }.joined(separator: " · "))
                        .font(HubTokens.mono).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
                    if let refused = changes.refused {
                        Label("Not inspected: \(refused).", systemImage: "lock.trianglebadge.exclamationmark")
                            .font(HubTokens.caption).foregroundStyle(HubTokens.attention).fixedSize(horizontal: false, vertical: true)
                    } else if changes.files.isEmpty {
                        Text("No uncommitted changes").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
                    } else {
                        Text("+\(changes.additions)  −\(changes.deletions)  in \(changes.files.count) files")
                            .font(HubTokens.caption.monospacedDigit()).foregroundStyle(HubTokens.textSecondary)
                        HubScroll {
                            LazyVStack(alignment: .leading, spacing: 1) {
                                ForEach(changes.files.prefix(60)) { file in
                                    Button { browser.showDiff(file.path) } label: {
                                        HStack(spacing: 5) {
                                            Circle().fill(file.touchedBySession ? AgentStyle.color(session.key.agent) : .clear).frame(width: 5, height: 5)
                                            Text((file.path as NSString).lastPathComponent).font(HubTokens.caption).foregroundStyle(HubTokens.textPrimary).lineLimit(1)
                                            Spacer(minLength: 2)
                                            if let a = file.additions { Text("+\(a)").foregroundStyle(HubTokens.running) }
                                            if let d = file.deletions { Text("−\(d)").foregroundStyle(HubTokens.failure) }
                                        }
                                        .font(HubTokens.mono).padding(.horizontal, 5).padding(.vertical, 5)
                                        .accessibilityLabel("\(file.path), \(file.additions ?? 0) added, \(file.deletions ?? 0) removed\(file.touchedBySession ? ", changed by this session" : "")")
                                    }
                                    .buttonStyle(HubRowStyle(isSelected: browser.diffPath == file.path))
                                    .help(file.path)
                                }
                            }
                        }
                        Text("● changed by this session").font(.system(size: 9)).foregroundStyle(HubTokens.textTertiary)
                    }
                }
                .frame(width: 200)
                DiffView(hub: hub, root: changes.root)
            }
        } else {
            HubEmptyState(symbol: "hourglass", title: "Reading the repository…", message: "Git runs read-only, on this Mac.")
        }
    }
}

/// A unified diff with additions, deletions and hunk headers coloured.
private struct DiffView: View {
    let hub: AIHubService
    let root: String

    var body: some View {
        let browser = hub.browser
        if let path = browser.diffPath {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(path).font(HubTokens.mono).foregroundStyle(HubTokens.textSecondary).lineLimit(1).truncationMode(.head)
                    Spacer()
                    Button { hub.revealFile(path, in: root) } label: { Image(systemName: "folder") }
                        .buttonStyle(HubButtonStyle(kind: .quiet)).help("Show in Finder").accessibilityLabel("Show in Finder")
                }
                HubScroll(axes: [.vertical, .horizontal]) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array((browser.diffText ?? "Loading…").split(separator: "\n", omittingEmptySubsequences: false).prefix(800).enumerated()),
                                id: \.offset) { _, line in
                            Text(line.isEmpty ? " " : String(line)).font(HubTokens.mono).foregroundStyle(DiffStyle.color(line))
                                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                                .background(DiffStyle.background(line))
                        }
                    }
                    .textSelection(.enabled)
                }
                .background(Color.black.opacity(0.25), in: .rect(cornerRadius: HubTokens.radius))
            }
        } else {
            HubEmptyState(symbol: "text.alignleft", title: "Choose a file", message: "Its uncommitted changes show here.")
        }
    }
}

@MainActor
enum DiffStyle {
    static func color(_ line: Substring) -> Color {
        if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("diff ") || line.hasPrefix("index ") { return HubTokens.textTertiary }
        if line.hasPrefix("@@") { return Theme.accent }
        if line.hasPrefix("+") { return HubTokens.running }
        if line.hasPrefix("-") { return HubTokens.failure }
        return HubTokens.textSecondary
    }

    static func background(_ line: Substring) -> Color {
        if line.hasPrefix("+"), !line.hasPrefix("+++") { return HubTokens.running.opacity(0.08) }
        if line.hasPrefix("-"), !line.hasPrefix("---") { return HubTokens.failure.opacity(0.08) }
        return .clear
    }
}

@MainActor
enum EventStyle {
    static func symbol(_ kind: AgentEvent.Kind) -> String {
        switch kind {
        case .sessionStarted: "play.fill"
        case .sessionEnded: "stop.fill"
        case .promptSubmitted: "text.bubble"
        case .turnCompleted: "checkmark"
        case .toolStarted: "hammer"
        case .toolCompleted: "checkmark.circle"
        case .toolFailed: "xmark"
        case .fileChanged: "doc.badge.ellipsis"
        case .notification: "bell"
        case .error: "exclamationmark.triangle"
        case .waitingForUser: "hand.raised"
        }
    }

    static func color(_ kind: AgentEvent.Kind) -> Color {
        switch kind {
        case .toolFailed, .error: HubTokens.failure
        case .waitingForUser: HubTokens.attention
        case .fileChanged: Theme.accent
        case .sessionStarted, .turnCompleted, .toolCompleted: HubTokens.running
        default: HubTokens.textSecondary
        }
    }
}

// MARK: Approvals

private struct ApprovalsScreen: View {
    let hub: AIHubService

    var body: some View {
        let approvals = hub.approvals
        let browser = hub.browser
        VStack(alignment: .leading, spacing: HubTokens.s2) {
            HStack {
                SegmentedChips(options: [false, true], selection: browser.showsApprovalHistory,
                               title: \.approvalTab) { browser.showsApprovalHistory = $0 }
                Spacer()
                Label(hub.coucouAnswersClaude ? "Claude Code asks in Coucou or its terminal; Orbit only observes it" : "Claude Code asks in its own terminal; Orbit only observes it", systemImage: "info.circle")
                    .font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary).lineLimit(1)
            }
            if let error = browser.decisionError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(HubTokens.failure)
                    Text(error).font(HubTokens.caption).foregroundStyle(HubTokens.textPrimary).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button("Dismiss") { browser.decisionError = nil }.buttonStyle(HubButtonStyle(kind: .quiet, font: HubTokens.caption))
                }
                .padding(HubTokens.s2)
                .background(HubTokens.failure.opacity(0.14), in: .rect(cornerRadius: HubTokens.radius))
                .overlay { RoundedRectangle(cornerRadius: HubTokens.radius).strokeBorder(HubTokens.failure.opacity(0.5), lineWidth: 1) }
                .accessibilityElement(children: .combine)
                .transition(.opacity)
            }
            if browser.showsApprovalHistory {
                if approvals.history.isEmpty {
                    HubEmptyState(symbol: "clock.arrow.circlepath", title: "No decisions yet", message: "Every decision and expiry is recorded here.")
                } else {
                    HubScroll {
                        LazyVStack(spacing: 2) {
                            ForEach(approvals.history) { record in ApprovalHistoryRow(record: record) }
                        }
                    }
                }
            } else if approvals.pending.isEmpty {
                HubEmptyState(symbol: "checkmark.shield", title: "Nothing needs your approval",
                              message: "Agents that can be answered here ask in this place, and it shows below the notch too. If nobody answers in time, the agent asks you itself.")
            } else {
                HubScroll {
                    VStack(spacing: HubTokens.s2) { ForEach(approvals.pending) { ApprovalCard(hub: hub, request: $0) } }
                }
            }
        }
    }
}

private extension Bool {
    var approvalTab: String { self ? "History" : "Pending" }
}

private struct ApprovalCard: View {
    let hub: AIHubService
    let request: ApprovalManager.Request

    var body: some View {
        let draft = request.draft
        let tint = AgentStyle.color(draft.session.agent)
        HStack(alignment: .top, spacing: 0) {
            Rectangle().fill(tint).frame(width: 3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    AgentAvatar(agent: draft.session.agent, size: 20)
                    Text(AgentDiscovery.displayName(for: draft.session.agent)).font(HubTokens.bodyStrong).foregroundStyle(HubTokens.textPrimary)
                    if request.isSimulated { HubTag(text: "SIMULATED") }
                    let session = (draft.session.agent.isDemo ? hub.demo : hub.real).sessions[draft.session]
                    Text(session?.title.map { "in \($0)" } ?? "session \(draft.session.nativeID)").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary).lineLimit(1)
                    Spacer(minLength: 4)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = Int(draft.expiresAt.timeIntervalSince(context.date))
                        Label(left > 0 ? "\(left)s left" : "Expiring", systemImage: "timer")
                            .font(HubTokens.caption.monospacedDigit()).foregroundStyle(left < 15 ? HubTokens.attention : HubTokens.textTertiary)
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: draft.kind == .question ? "questionmark.bubble.fill" : "lock.shield.fill").foregroundStyle(HubTokens.attention)
                    Text(draft.kind == .question ? "Asks a question" : "Wants to run \(draft.tool ?? "a tool")")
                        .font(HubTokens.caption).foregroundStyle(HubTokens.attention)
                }
                Text(draft.summary).font(HubTokens.title).foregroundStyle(HubTokens.textPrimary).fixedSize(horizontal: false, vertical: true)
                if let detail = draft.detail, !draft.summary.hasSuffix(detail) {  // only when it adds something
                    Text(detail).font(HubTokens.mono).foregroundStyle(HubTokens.textSecondary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)  // every line shows: this is what's being allowed
                        .padding(HubTokens.s2).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.black.opacity(0.25), in: .rect(cornerRadius: HubTokens.radiusSmall))
                }
                let live = draft.expiresAt > .now
                if !hub.canAnswer(draft) {
                    Label("Orbit can't answer \(AgentDiscovery.displayName(for: draft.session.agent)): it asks you itself", systemImage: "info.circle")
                        .font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
                } else if !draft.questions.isEmpty {
                    QuestionForm(questions: draft.questions, enabled: live) { answers in
                        withAnimation(HubTokens.move) { _ = hub.browser.decide(request, .answers(answers), in: hub.approvals) }
                    }
                }
                HStack(spacing: 6) {
                    if !live { Text("Expired: the agent asks you itself").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary) }
                    Spacer()
                    if !hub.canAnswer(draft) {
                        EmptyView()  // no buttons for an adapter that can't be answered (§23)
                    } else if draft.kind == .permission {
                        Button("Deny") { withAnimation(HubTokens.move) { hub.browser.decide(request, .deny, in: hub.approvals) } }
                            .buttonStyle(HubButtonStyle(kind: .destructive))
                        Button("Allow Once") { withAnimation(HubTokens.move) { hub.browser.decide(request, .allowOnce, in: hub.approvals) } }
                            .buttonStyle(HubButtonStyle(kind: .primary))
                    } else {
                        ForEach(draft.options, id: \.self) { option in
                            Button(option) { withAnimation(HubTokens.move) { hub.browser.decide(request, .answer(option), in: hub.approvals) } }
                                .buttonStyle(HubButtonStyle(kind: .secondary))
                        }
                    }
                }
                .disabled(!live)
            }
            .padding(HubTokens.s3)
        }
        .background(HubTokens.surfaceRaised, in: .rect(cornerRadius: HubTokens.radiusLarge, style: .continuous))
        .clipShape(.rect(cornerRadius: HubTokens.radiusLarge, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: HubTokens.radiusLarge, style: .continuous).strokeBorder(HubTokens.attention.opacity(0.35), lineWidth: 1) }
        .transition(.opacity.combined(with: .scale(scale: 0.98)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(request.isSimulated ? "Simulated " : "")\(draft.kind == .question ? "question" : "approval request") from \(AgentDiscovery.displayName(for: draft.session.agent)): \(draft.summary)\(draft.detail.map { ". Full input: \($0)" } ?? "")")
    }
}

private struct ApprovalHistoryRow: View {
    let record: ApprovalManager.Record

    var body: some View {
        let (symbol, color): (String, Color) = switch record.outcome {
        case .allowed: ("checkmark.circle.fill", HubTokens.running)
        case .denied: ("xmark.circle.fill", HubTokens.failure)
        case .answered: ("text.bubble.fill", Theme.accent)
        case .expired: ("timer", HubTokens.quiet)
        case .withdrawn: ("arrow.uturn.backward.circle", HubTokens.quiet)
        }
        HStack(spacing: HubTokens.s2) {
            Label(record.outcome.rawValue.capitalized + (record.answer.map { ": \($0)" } ?? ""), systemImage: symbol)
                .font(HubTokens.caption).foregroundStyle(color).frame(width: 120, alignment: .leading)
            AgentAvatar(agent: record.draft.session.agent, size: 16)
            Text(AgentDiscovery.displayName(for: record.draft.session.agent)).font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary).fixedSize()
            Text(record.draft.summary).font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
            if record.draft.session.agent.isDemo { HubTag(text: "SIMULATED") }
            Spacer(minLength: 4)
            Text(record.decidedAt.formatted(date: .omitted, time: .shortened)).font(HubTokens.caption.monospacedDigit()).foregroundStyle(HubTokens.textTertiary)
        }
        .padding(.horizontal, HubTokens.s2).padding(.vertical, 5)
        .background(HubTokens.surface, in: .rect(cornerRadius: HubTokens.radiusSmall))
        .accessibilityElement(children: .combine)
    }
}

// MARK: Insights

private struct InsightsScreen: View {
    let hub: AIHubService

    var body: some View {
        let insights = hub.insights
        if !hub.isEnabled {
            HubEmptyState(symbol: "chart.bar.xaxis", title: "Insights need the AI Hub", message: "Turn it on to see how your agents work over the week.",
                          action: ("Open AI Hub Settings", { openHubSettings() }))
        } else if insights.agents.isEmpty {
            HubEmptyState(symbol: "chart.bar.xaxis", title: "Not enough activity yet",
                          message: "Insights come from real agents' sessions on this Mac over the last 7 days. Simulated sessions never count.")
                .task { await hub.refreshInsights() }
        } else {
            HubScroll {
                VStack(alignment: .leading, spacing: HubTokens.s2) {
                    if insights.isPartial {
                        Label("History starts \(insights.historyStart.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "now"): earlier days weren't recorded, so this week is incomplete.",
                              systemImage: "info.circle")
                            .font(HubTokens.caption).foregroundStyle(HubTokens.attention).lineLimit(2)
                    }
                    HStack(spacing: HubTokens.s2) {
                        HubMetric(value: "\(insights.sessions)", label: "Sessions", symbol: "rectangle.stack")
                        HubMetric(value: "\(insights.finished)", label: "Finished", symbol: "checkmark.circle", tint: HubTokens.running)
                        HubMetric(value: "\(insights.failed)", label: "Failed", symbol: "xmark.octagon",
                                  tint: insights.failed > 0 ? HubTokens.failure : HubTokens.textPrimary)
                        HubMetric(value: "\(insights.active)", label: "Active now", symbol: "circle.dotted.circle")
                        HubMetric(value: "\(insights.filesChanged)", label: "Files touched", symbol: "doc.on.doc")
                    }
                    if !insights.highlights.isEmpty {
                        HubPanel(padding: 10) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    HubSectionHeader(title: "This week")
                                    Spacer()
                                    if let trend = insights.trend {
                                        Label("\(trend.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always()))) events vs last week",
                                              systemImage: trend >= 0 ? "arrow.up.right" : "arrow.down.right")
                                            .font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary)
                                    }
                                }
                                ForEach(insights.highlights, id: \.self) { line in
                                    Label(line, systemImage: "sparkle").font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                            }
                        }
                    }
                    HStack(alignment: .top, spacing: HubTokens.s2) {
                        HubPanel(padding: 10) { DailyBars(days: insights.days) }
                        HubPanel(padding: 10) { AgentShare(agents: insights.agents) }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    HStack(alignment: .top, spacing: HubTokens.s2) {
                        HubPanel(padding: 10) { RankedBars(title: "Most used tools", rows: insights.tools.map { ($0.tool, $0.count) }, unit: "calls") }
                        HubPanel(padding: 10) { RankedBars(title: "Busiest projects", rows: insights.projects.map { (($0.project as NSString).lastPathComponent, $0.sessions) }, unit: "sessions") }
                    }
                    HStack {
                        Text("Real agents only · no costs or plan limits (no reliable source without API keys)")
                            .font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary).lineLimit(1)
                        Spacer()
                        Button { hub.browser.copy(insights.report) } label: {
                            Label(hub.browser.copied ? "Copied" : "Copy Weekly Summary", systemImage: hub.browser.copied ? "checkmark" : "doc.on.doc")
                                .contentTransition(.opacity)
                        }
                        .buttonStyle(HubButtonStyle(kind: .secondary))
                        .accessibilityLabel(hub.browser.copied ? "Weekly summary copied" : "Copy weekly summary")
                    }
                }
            }
            .task { await hub.refreshInsights() }
        }
    }
}

private struct DailyBars: View {
    let days: [(day: String, count: Int)]

    var body: some View {
        let peak = max(days.map(\.count).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 6) {
            HubSectionHeader(title: "Events per day")
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(days, id: \.day) { day in
                    VStack(spacing: 3) {
                        Text("\(day.count)").font(.system(size: 8.5).monospacedDigit()).foregroundStyle(HubTokens.textTertiary)
                        RoundedRectangle(cornerRadius: 2).fill(Theme.accent.opacity(0.75))
                            .frame(height: max(3, 40 * CGFloat(day.count) / CGFloat(peak)))
                        Text(String(day.day.suffix(2))).font(.system(size: 9).monospacedDigit()).foregroundStyle(HubTokens.textTertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(day.day): \(day.count) events")
                }
            }
            .frame(height: 66, alignment: .bottom)
        }
    }
}

private struct AgentShare: View {
    let agents: [HubStore.AgentTotals]

    var body: some View {
        let total = max(agents.map(\.activeSeconds).reduce(0, +), 1)
        VStack(alignment: .leading, spacing: 6) {
            HubSectionHeader(title: "Active time by agent")
            ForEach(agents.prefix(4), id: \.agent) { totals in
                let agent = AgentID(totals.agent) ?? AgentID("unknown")!
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        AgentAvatar(agent: agent, size: 14)
                        Text(AgentDiscovery.displayName(for: agent)).font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary)
                        Spacer()
                        Text(HubFormat.duration(totals.activeSeconds)).font(HubTokens.caption.monospacedDigit()).foregroundStyle(HubTokens.textTertiary)
                    }
                    GeometryReader { geometry in
                        Capsule().fill(AgentStyle.color(agent).opacity(0.8)).frame(width: max(3, geometry.size.width * totals.activeSeconds / total))
                    }
                    .frame(height: 4)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct RankedBars: View {
    let title: String
    let rows: [(String, Int)]
    let unit: String

    var body: some View {
        let peak = max(rows.map(\.1).max() ?? 1, 1)
        VStack(alignment: .leading, spacing: 5) {
            HubSectionHeader(title: title)
            if rows.isEmpty { Text("Nothing yet").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary) }
            ForEach(Array(rows.prefix(4).enumerated()), id: \.offset) { _, row in
                HStack(spacing: 6) {
                    Text(row.0).font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1).truncationMode(.middle)
                        .frame(width: 110, alignment: .leading)
                    GeometryReader { geometry in
                        Capsule().fill(Theme.accent.opacity(0.7)).frame(width: max(3, geometry.size.width * CGFloat(row.1) / CGFloat(peak)))
                    }
                    .frame(height: 4)
                    Text("\(row.1)").font(HubTokens.caption.monospacedDigit()).foregroundStyle(HubTokens.textTertiary).frame(width: 28, alignment: .trailing)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(row.0): \(row.1) \(unit)")
            }
        }
    }
}

// MARK: Chat

private struct ChatScreen: View {
    let chat: ChatService

    var body: some View {
        HStack(alignment: .top, spacing: HubTokens.s3) {
            VStack(alignment: .leading, spacing: HubTokens.s2) {
                Button { chat.newConversation() } label: { Label("New Chat", systemImage: "square.and.pencil").frame(maxWidth: .infinity) }
                    .buttonStyle(HubButtonStyle(kind: .secondary)).keyboardShortcut("n", modifiers: .command)
                    .disabled(!chat.hasLocalModels).help("New chat (⌘N)")
                HubScroll {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(chat.conversations) { conversation in
                            Button { chat.selectedConversation = conversation.id } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(conversation.title).font(HubTokens.caption).foregroundStyle(HubTokens.textPrimary).lineLimit(1)
                                    Text(conversation.model).font(.system(size: 9)).foregroundStyle(HubTokens.textTertiary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                            }
                            .buttonStyle(HubRowStyle(isSelected: chat.selectedConversation == conversation.id))
                            .contextMenu { Button("Delete", role: .destructive) { chat.delete(conversation.id) } }
                        }
                    }
                }
            }
            .frame(width: 150)
            VStack(alignment: .leading, spacing: HubTokens.s2) {
                ChatHeader(chat: chat)
                if !chat.hasLocalModels {
                    HubEmptyState(symbol: "cpu", title: "No model server on this Mac",
                                  message: "Start Ollama (port 11434) or LM Studio's local server (port 1234), then check again. \(ChatService.cloudProviders.joined(separator: ", ")) need API keys, which Orbit can't store safely yet.",
                                  action: ("Check Again", { Task { await chat.refresh() } }))
                } else {
                    Messages(chat: chat)
                    Composer(chat: chat)
                }
            }
        }
        .task { await chat.refresh() }
    }
}

private struct ChatHeader: View {
    let chat: ChatService

    var body: some View {
        let available = chat.providers.filter(\.available)
        HStack(spacing: 6) {
            Circle().fill(available.isEmpty ? HubTokens.quiet : HubTokens.running).frame(width: 6, height: 6)
            Text(available.isEmpty ? "Offline" : available.map { "\($0.provider.name) · \($0.models.count) model\($0.models.count == 1 ? "" : "s")" }.joined(separator: "   "))
                .font(HubTokens.caption).foregroundStyle(HubTokens.textSecondary).lineLimit(1)
            Spacer()
            if !available.isEmpty {
                Menu {
                    ForEach(available) { state in
                        Section(state.provider.name) {
                            ForEach(state.models, id: \.self) { model in
                                Button(model) { chat.selectedProvider = state.id; chat.selectedModel = model }
                            }
                        }
                    }
                } label: { Text(chat.selectedModel ?? "Choose a model").font(HubTokens.caption) }
                .menuStyle(.borderlessButton).fixedSize()
            }
            ForEach(ChatService.cloudProviders, id: \.self) { name in HubTag(text: name, tint: HubTokens.textTertiary).help("\(name) needs an API key (not yet supported)") }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct Messages: View {
    let chat: ChatService

    var body: some View {
        let messages = chat.current?.messages ?? []
        if messages.isEmpty {
            HubEmptyState(symbol: "bubble.left.and.text.bubble.right", title: "Ask a local model",
                          message: "Conversations stay on this Mac. Attach a text file for context with the paperclip.")
        } else {
            HubScroll {
                LazyVStack(alignment: .leading, spacing: HubTokens.s2) {
                    ForEach(messages) { message in
                        let mine = message.role == .user
                        Text(message.content.isEmpty ? "…" : message.content)
                            .font(HubTokens.body).foregroundStyle(HubTokens.textPrimary).textSelection(.enabled)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(mine ? Theme.accent.opacity(0.22) : HubTokens.surface, in: .rect(cornerRadius: HubTokens.radius, style: .continuous))
                            .frame(maxWidth: .infinity, alignment: mine ? .trailing : .leading)
                            .padding(mine ? .leading : .trailing, 40)
                            .accessibilityLabel((mine ? "You: " : "Model: ") + message.content)
                    }
                }
            }
            .defaultScrollAnchor(.bottom)
        }
    }
}

private struct Composer: View {
    let chat: ChatService

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let error = chat.lastError { Label(error, systemImage: "exclamationmark.triangle").font(HubTokens.caption).foregroundStyle(HubTokens.attention) }
            if !chat.attachments.isEmpty {
                HStack(spacing: 4) {
                    ForEach(chat.attachments, id: \.name) { HubTag(text: $0.name) }
                    Button("Remove") { chat.removeAttachments() }.buttonStyle(HubButtonStyle(kind: .quiet)).font(HubTokens.caption)
                }
            }
            HStack(spacing: 6) {
                Button { attachFile() } label: { Image(systemName: "paperclip") }
                    .buttonStyle(HubButtonStyle(kind: .quiet)).help("Attach a text file").accessibilityLabel("Attach a text file")
                HubField(placeholder: "Message \(chat.selectedModel ?? "a local model")", text: Binding(get: { chat.draft }, set: { chat.draft = $0 })) {
                    chat.send()
                }
                    .padding(.horizontal, 10).frame(height: 28)
                    .background(HubTokens.surface, in: .rect(cornerRadius: HubTokens.radius))
                    .overlay { RoundedRectangle(cornerRadius: HubTokens.radius).strokeBorder(HubTokens.border, lineWidth: 0.75) }
                if chat.isStreaming {
                    Button { chat.cancel() } label: { Label("Stop", systemImage: "stop.fill") }.buttonStyle(HubButtonStyle(kind: .secondary))
                        .keyboardShortcut(".", modifiers: .command).help("Stop generating (⌘.)")
                } else {
                    Button { chat.send() } label: { Image(systemName: "arrow.up") }.buttonStyle(HubButtonStyle(kind: .primary))
                        .disabled(chat.draft.trimmingCharacters(in: .whitespaces).isEmpty).accessibilityLabel("Send")
                }
            }
        }
    }

    private func attachFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText, .sourceCode, .json, .text]
        if panel.runModal() == .OK, let url = panel.url { chat.attach(url) }
    }
}

/// Files from this session's project on the File Shelf (Milestone 14): click one to copy its
/// shell-quoted path, ready to paste into the agent. Orbit never sends anything to the agent itself.
private struct ShelfStrip: View {
    let shelf: FileShelf
    let items: [ShelfItem]

    var body: some View {
        if !items.isEmpty {
            HStack(spacing: 6) {
                Label("On the shelf", systemImage: "tray.full").font(HubTokens.caption).foregroundStyle(HubTokens.textTertiary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(items.prefix(8)) { item in
                            Button { shelf.copyPathForAgent(item) } label: {
                                Label(item.name, systemImage: item.storage == .copy ? "doc.on.doc" : "link")
                                    .font(HubTokens.caption).lineLimit(1)
                            }
                            .buttonStyle(HubButtonStyle(kind: .quiet))
                            .help("Copy \(item.sourcePath), quoted, to paste into the agent")
                        }
                    }
                }
                if items.count > 1 {
                    Button("Copy all") { shelf.copyPathsForAgent(items) }.buttonStyle(HubButtonStyle(kind: .secondary))
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(items.count) shelved file\(items.count == 1 ? "" : "s") from this project")
        }
    }
}
