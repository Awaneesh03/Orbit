import SwiftUI

struct GitHubActivity: Identifiable, Equatable {
    enum Kind { case pullRequest, review, checks, issue }

    let id: String
    let kind: Kind
    let title: String
    let repo: String
    let status: String
    let minutesAgo: Int
}

/// Pull requests, reviews and CI. SAMPLE: `MockData.githubActivity` until the
/// GitHub API is connected (needs a token; later stage).
@MainActor
final class GitHubWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "github", title: "GitHub", description: "Pull requests, reviews and CI",
        symbol: "arrow.triangle.pull", category: .developer, availability: .sample,
        presentations: [.compact, .expanded], isEnabledByDefault: false)
    let activity: [GitHubActivity]

    var state: WidgetState { activity.isEmpty ? .empty("No recent activity") : .ready }

    init(activity: [GitHubActivity] = MockData.githubActivity) {
        self.activity = activity
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(activity) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: Self.symbol(item.kind))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 14)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.title).lineLimit(1)
                            Text("\(item.repo) · \(item.status) · \(Self.ago(item.minutesAgo))")
                                .foregroundStyle(Theme.tertiary)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .scrollIndicators(.never))
    }

    private static func symbol(_ kind: GitHubActivity.Kind) -> String {
        switch kind {
        case .pullRequest: "arrow.triangle.pull"
        case .review: "eye"
        case .checks: "checkmark.seal"
        case .issue: "exclamationmark.circle"
        }
    }

    private static func ago(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes)m" : minutes < 1440 ? "\(minutes / 60)h" : "\(minutes / 1440)d"
    }
}
