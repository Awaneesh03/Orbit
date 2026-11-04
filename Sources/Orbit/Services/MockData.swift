import Foundation

/// SAMPLE DATA ONLY. Every value here is invented. Widgets that use it declare
/// `availability: .sample`, which puts a SAMPLE badge on their card. Each is
/// replaced when its service lands:
/// - github   → the GitHub API (needs a token; later stage)
/// - aiReply  → the provider's API (needs a key; later stage)
enum MockData {

    static let githubActivity = [
        GitHubActivity(id: "pr-13", kind: .pullRequest, title: "Screenshot Vault foundation", repo: "orbit",
                       status: "Review requested", minutesAgo: 20),
        GitHubActivity(id: "ci-main", kind: .checks, title: "main", repo: "orbit",
                       status: "Checks passed", minutesAgo: 35),
        GitHubActivity(id: "rv-12", kind: .review, title: "Widget registry", repo: "orbit",
                       status: "Approved", minutesAgo: 140),
        GitHubActivity(id: "is-9", kind: .issue, title: "Battery bar greys out", repo: "orbit",
                       status: "Closed", minutesAgo: 300),
        GitHubActivity(id: "pr-11", kind: .pullRequest, title: "Notch geometry", repo: "orbit",
                       status: "Merged", minutesAgo: 1500),
    ]

    static func aiReply(to prompt: String, from provider: AIProvider) -> String {
        "Sample reply: Orbit isn't connected to \(provider.rawValue) yet, so nothing was sent. "
            + "Once the AI Hub is connected, “\(prompt.prefix(80))” will go to \(provider.rawValue) "
            + "and the real answer will appear here."
    }
}
