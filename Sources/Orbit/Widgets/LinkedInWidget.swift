import AppKit
import SwiftUI

/// Your LinkedIn post performance (Briefing, off by default). Shows only what
/// LinkedIn's Member Post Analytics API returns for the signed-in member;
/// every other situation (no token, expired token, app not approved) is said
/// plainly, never filled with sample numbers. Analytics stay in memory.
@MainActor @Observable
final class LinkedInWidget: DashboardWidget {
    enum Phase: Equatable {
        case disconnected
        case loading
        case ready(LinkedInAnalytics)
        case failed(LinkedInError)
    }

    let metadata = WidgetMetadata(
        id: "linkedin", title: "LinkedIn", description: "Your post impressions, reactions and trends (official API)",
        symbol: "chart.line.uptrend.xyaxis", category: .general, availability: .live,
        presentations: [.compact, .expanded], isEnabledByDefault: false)
    private(set) var phase = Phase.disconnected
    /// The token being pasted (view state; cleared once used).
    var tokenDraft = ""
    @ObservationIgnored private let store: any CredentialStore
    @ObservationIgnored private let client: LinkedInClient
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored let open: (URL) -> Void

    static let tokenGenerator = URL(string: "https://www.linkedin.com/developers/tools/oauth/token-generator")!
    static let developerApps = URL(string: "https://www.linkedin.com/developers/apps")!
    static let creatorAnalytics = URL(string: "https://www.linkedin.com/analytics/creator/content/")!

    init(store: any CredentialStore = MemoryCredentialStore(), client: LinkedInClient = LinkedInClient(http: URLSessionLinkedInHTTP()),
         clock: @escaping () -> Date = { .now }, open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        self.store = store
        self.client = client
        self.clock = clock
        self.open = open
        if store.read() != nil { phase = .loading }
    }

    /// Always "ready" for the host: every LinkedIn state has its own UI here
    /// (the connect form needs a text field, which the host's states don't have).
    var state: WidgetState { .ready }

    var isConnected: Bool { store.read() != nil }

    /// Refreshes when shown, at most hourly (LinkedIn rate-limits each app daily).
    func start() {
        guard isConnected else { return }
        if case .ready(let analytics) = phase, clock().timeIntervalSince(analytics.fetchedAt) < 3600 { return }
        refresh()
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    func connect() {
        let token = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        try? store.write(token)
        tokenDraft = ""
        refresh()
    }

    func disconnect() {
        task?.cancel()
        task = nil
        store.delete()
        phase = .disconnected
    }

    @discardableResult
    func refresh() -> Task<Void, Never>? {
        guard let token = store.read() else { phase = .disconnected; return nil }
        task?.cancel()
        if case .ready = phase {} else { phase = .loading }  // numbers stay on screen while refreshing
        let client = self.client, now = clock()
        let task = Task { [weak self] in
            let outcome: Phase
            do {
                outcome = .ready(try await client.fetch(token: token, now: now))
            } catch let error as LinkedInError {
                outcome = .failed(error)
            } catch {
                guard DataSourceError.from(error) != nil else { return }  // cancelled
                outcome = .failed(.failed(DataSourceError.from(error) == .offline ? "You're offline." : "Couldn't reach LinkedIn."))
            }
            guard !Task.isCancelled else { return }
            self?.phase = outcome
        }
        self.task = task
        return task
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(LinkedInView(widget: self, compact: presentation == .compact))
    }
}

private struct LinkedInView: View {
    let widget: LinkedInWidget
    let compact: Bool

    var body: some View {
        switch widget.phase {
        case .disconnected: connectForm(reason: nil)
        case .loading: OrbitLoadingView()
        case .ready(let analytics): dashboard(analytics)
        case .failed(.unauthorized): connectForm(reason: "Your token expired or was revoked. LinkedIn tokens last 60 days; generate a new one.")
        case .failed(.notApproved(let detail)): notApproved(detail)
        case .failed(.rateLimited): retry("LinkedIn's daily limit for your app was reached. Try again later.")
        case .failed(.failed(let message)): retry(message)
        }
    }

    private func connectForm(reason: String?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            if let reason {
                Label(reason, systemImage: "exclamationmark.triangle").font(OrbitType.caption).foregroundStyle(OrbitGlass.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("Connect with your own LinkedIn developer app. Orbit uses LinkedIn's official analytics API and never sees your password.")
                    .font(OrbitType.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !compact {
                Text("1. Create an app; request Community Management API (Member Post Analytics).\n2. In Token Generator, choose openid, profile and r_member_postAnalytics.\n3. Paste the access token here. It stays in memory until Orbit quits.")
                    .font(OrbitType.caption).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                SecureField("Access token", text: Binding(get: { widget.tokenDraft }, set: { widget.tokenDraft = $0 }))
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .orbitSurface(radius: 8)
                    .onSubmit(widget.connect)
                OrbitGlassButton(title: "Connect", symbol: "link", prominent: true, action: widget.connect)
            }
            HStack(spacing: 12) {
                OrbitLinkButton(title: "Developer apps…") { widget.open(LinkedInWidget.developerApps) }
                OrbitLinkButton(title: "Token Generator…") { widget.open(LinkedInWidget.tokenGenerator) }
            }
        }
    }

    private func notApproved(_ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Analytics not available for this app", systemImage: "lock.shield").font(OrbitType.title)
            Text("LinkedIn only returns post analytics to apps approved for the Community Management API with the r_member_postAnalytics scope. Request it for your app, then generate a new token.")
                .font(OrbitType.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Text("LinkedIn said: \(detail)").font(OrbitType.caption).foregroundStyle(Theme.tertiary).lineLimit(2)
            HStack(spacing: 10) {
                OrbitGlassButton(title: "Developer apps", symbol: "arrow.up.right") { widget.open(LinkedInWidget.developerApps) }
                OrbitGlassButton(title: "Disconnect", symbol: "xmark", action: widget.disconnect)
            }
        }
    }

    private func retry(_ message: String) -> some View {
        VStack(spacing: 10) {
            StatusMessage(text: message, symbol: "exclamationmark.triangle", tone: .warning).fixedSize(horizontal: false, vertical: true)
            HStack {
                OrbitGlassButton(title: "Retry", symbol: "arrow.clockwise") { widget.refresh() }
                OrbitGlassButton(title: "Disconnect", symbol: "xmark", action: widget.disconnect)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func dashboard(_ analytics: LinkedInAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(analytics.profile?.name ?? "Your posts").font(OrbitType.title).lineLimit(1)
                Text("Last 28 days").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                Spacer(minLength: 4)
                if !compact {
                    Text("Updated \(analytics.fetchedAt.formatted(date: .omitted, time: .shortened))")
                        .font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                    iconButton("arrow.up.right.square", help: "Open your posts on LinkedIn") { widget.open(LinkedInWidget.creatorAnalytics) }
                    iconButton("arrow.clockwise", help: "Refresh LinkedIn analytics") { widget.refresh() }
                }
            }
            if compact {
                metric(.impressions, analytics)
                Sparkline(values: analytics.dailyImpressions.map(\.count))
            } else {
                HStack(spacing: 6) {
                    ForEach([LinkedInMetric.impressions, .reactions, .comments, .reshares], id: \.self) { metric($0, analytics) }
                }
                HStack(alignment: .bottom, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DAILY IMPRESSIONS").font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.tertiary)
                        Sparkline(values: analytics.dailyImpressions.map(\.count), height: 26)
                    }
                    VStack(alignment: .trailing, spacing: 3) {
                        if let rate = analytics.engagementRate {
                            Text(rate.formatted(.percent.precision(.fractionLength(1)))).font(OrbitType.title).monospacedDigit()
                            Text("engagement").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                        }
                        if let reached = analytics.totals[.reached] {
                            Text("\(reached.formatted()) reached").font(OrbitType.caption).foregroundStyle(Theme.secondary)
                        }
                    }
                }
            }
        }
    }

    private func iconButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
                .frame(width: 20, height: 20).contentShape(.rect)
        }
        .buttonStyle(DashboardButtonStyle()).help(help).accessibilityLabel(help)
    }

    private func metric(_ metric: LinkedInMetric, _ analytics: LinkedInAnalytics) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(metric.title.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Text((analytics.totals[metric] ?? 0).formatted(.number.notation(.compactName)))
                .font(.system(size: 17, weight: .semibold, design: .rounded)).monospacedDigit()
            if let change = analytics.change(metric) {
                Label(change.formatted(.percent.precision(.fractionLength(0)).sign(strategy: .always())),
                      systemImage: change >= 0 ? "arrow.up.right" : "arrow.down.right")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(change >= 0 ? HubTokens.running : OrbitGlass.critical)
            } else {
                Text("—").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8).padding(.vertical, 6)
        .orbitSurface(radius: 9)
        .accessibilityElement(children: .combine)
    }
}

/// Daily counts as bars, scaled to the largest; empty days show a stub.
struct Sparkline: View {
    let values: [Int]
    var height: CGFloat = 34

    var body: some View {
        let top = max(values.max() ?? 0, 1)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, value in
                Capsule().fill(Theme.accent.opacity(value == 0 ? 0.25 : 0.85))
                    .frame(maxWidth: 7)
                    .frame(height: max(2, height * CGFloat(value) / CGFloat(top)))
            }
        }
        .frame(maxWidth: .infinity, minHeight: height, maxHeight: height, alignment: .bottomLeading)
        .accessibilityElement()
        .accessibilityLabel(values.isEmpty ? "No daily data" : "Daily trend, highest \(top)")
    }
}
