import AppKit
import SwiftUI

/// Technology news from curated publisher feeds (Briefing's lead widget).
/// Refreshes when shown and older than 30 minutes, and every 30 minutes while
/// visible; the last digest is cached on disk, so the Briefing opens with
/// news even offline. Stories open in the browser at the source.
@MainActor @Observable
final class NewsWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "news", title: "Tech News", description: "Technology and AI headlines from trusted sources",
        symbol: "newspaper", category: .general, availability: .live,
        presentations: [.compact, .expanded], isEnabledByDefault: false)
    let refresher: Refresher<NewsDigest>
    /// nil: every category.
    var filter: NewsCategory?
    /// The story under the pointer (view state; no @State on this toolchain).
    var hovered: String?
    @ObservationIgnored private let open: (URL) -> Void

    init(source: NewsFeedSource, cache: DataCache<NewsDigest>, clock: @escaping () -> Date = { .now },
         open: @escaping (URL) -> Void = { NSWorkspace.shared.open($0) }) {
        refresher = Refresher(source: source, policy: .init(maxAge: 30 * 60, interval: .seconds(30 * 60)),
                              cache: cache, clock: clock)
        self.open = open
    }

    var state: WidgetState {
        refresher.widgetState { $0.stories.isEmpty ? "No stories in the last few days." : nil }
    }

    var statusNote: WidgetNote? { refresher.statusNote }
    var stateAction: WidgetAction? { refresher.retryAction }

    func start() { refresher.becameVisible() }
    func stop() { refresher.becameHidden() }

    /// The filtered list (all categories when none is chosen).
    var stories: [NewsStory] {
        let all = refresher.value?.stories ?? []
        return filter.map { category in all.filter { $0.category == category } } ?? all
    }

    /// Categories that have at least one story, in their fixed order.
    var categories: [NewsCategory] {
        let present = Set(refresher.value?.stories.map(\.category) ?? [])
        return NewsCategory.allCases.filter(present.contains)
    }

    /// Only web links open: a feed can't make Orbit launch anything else.
    func read(_ story: NewsStory) {
        guard story.url.scheme == "https" || story.url.scheme == "http" else { return }
        open(story.url)
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(NewsView(widget: self, compact: presentation == .compact))
    }
}

private struct NewsView: View {
    let widget: NewsWidget
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !compact {
                HStack(spacing: 4) {
                    chip("All", selected: widget.filter == nil) { widget.filter = nil }
                    ForEach(widget.categories) { category in
                        chip(category.title, selected: widget.filter == category) { widget.filter = category }
                    }
                    Spacer(minLength: 4)
                    Button { widget.refresher.refresh() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(widget.refresher.isRefreshing ? Theme.tertiary : Theme.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(.rect)
                    }
                    .buttonStyle(DashboardButtonStyle())
                    .disabled(widget.refresher.isRefreshing)
                    .help("Refresh news")
                    .accessibilityLabel(widget.refresher.isRefreshing ? "Refreshing news" : "Refresh news")
                }
            }
            HubScroll {
                VStack(alignment: .leading, spacing: compact ? 6 : 3) {
                    let stories = compact ? Array(widget.stories.prefix(4)) : widget.stories
                    ForEach(stories) { story in
                        row(story, lead: !compact && story.id == stories.first?.id)
                    }
                    if !compact, let missing = widget.refresher.value?.unavailable, !missing.isEmpty {
                        Text("Couldn't reach \(missing.formatted(.list(type: .and))).")
                            .font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? .white : Theme.secondary)
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(selected ? Theme.accent.opacity(0.35) : Color.white.opacity(0.06), in: .capsule)
        }
        .buttonStyle(DashboardButtonStyle())
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The lead story shows its summary; the rest are one dense line each
    /// (the summary is in the tooltip), so the card lists several at a glance.
    private func row(_ story: NewsStory, lead: Bool) -> some View {
        let hovered = widget.hovered == story.id
        return Button { widget.read(story) } label: {
            Group {
                if compact || lead {
                    VStack(alignment: .leading, spacing: 2) {
                        meta(story)
                        Text(story.title)
                            .font(.system(size: compact ? 11.5 : 12.5, weight: .semibold))
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                        if lead, let summary = story.summary {
                            Text(summary).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } else {
                    HStack(spacing: 7) {
                        Text(story.sourceName).font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.accent)
                            .frame(width: 74, alignment: .leading).lineLimit(1)
                        Text(story.title).font(.system(size: 11.5, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 4)
                        if let published = story.published { age(published) }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, compact ? 0 : 8).padding(.vertical, compact ? 0 : lead ? 6 : 4)
            .background(compact ? .clear : hovered ? Theme.selectedFill : OrbitGlass.surfaceFill,
                        in: .rect(cornerRadius: 9, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(DashboardButtonStyle())
        .onHover { inside in widget.hovered = inside ? story.id : (widget.hovered == story.id ? nil : widget.hovered) }
        .help(story.summary.map { "\($0)\n\n\(story.url.host() ?? "")" } ?? "Open in browser: \(story.url.host() ?? "")")
        .accessibilityLabel("\(story.title). \(story.sourceName), \(story.category.title)")
        .accessibilityHint("Opens the article in your browser")
    }

    private func meta(_ story: NewsStory) -> some View {
        HStack(spacing: 5) {
            Text(story.sourceName).foregroundStyle(Theme.accent)
            Text("·").foregroundStyle(Theme.tertiary)
            Text(story.category.title).foregroundStyle(Theme.secondary)
            if let published = story.published {
                Spacer(minLength: 4)
                age(published)
            }
        }
        .font(.system(size: 9.5, weight: .semibold))
        .lineLimit(1)
    }

    private func age(_ published: Date) -> some View {
        Text(published, format: .relative(presentation: .named, unitsStyle: .abbreviated))
            .font(.system(size: 9.5, weight: .medium))
            .foregroundStyle(Theme.tertiary)
            .lineLimit(1)
            .fixedSize()
    }
}
