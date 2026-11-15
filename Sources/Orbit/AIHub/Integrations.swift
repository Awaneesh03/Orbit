import Foundation

// Developer integrations (Phase 8; docs/AI_HUB_SPEC.md §4 G). Every one needs
// the user's own credential (a token, OAuth or an API key), and Orbit doesn't
// store credentials until the signing decision is made (D3) — so each is
// listed with what it would need and why it isn't connected, rather than
// pretending. Orbit never reuses another tool's token (gh, Vercel CLI…).

struct IntegrationManifest: Identifiable, Equatable, Sendable {
    enum Category: String, Sendable { case developer = "Developer", communication = "Communication", business = "Business" }
    enum Status: Equatable, Sendable {
        /// Needs a credential Orbit can't yet store safely (D3).
        case waitingForCredentials
    }

    let id: String
    let name: String
    let category: Category
    /// How the user would connect it.
    let auth: String
    /// What Orbit would show from it.
    let shows: String
    var status = Status.waitingForCredentials
}

enum IntegrationRegistry {
    /// Developer integrations first (the spec's priority).
    static let all: [IntegrationManifest] = [
        .init(id: "github", name: "GitHub", category: .developer, auth: "OAuth device flow or a fine-grained token (read-only)",
              shows: "Pull requests, reviews and checks for the repositories your agents work in"),
        .init(id: "gitlab", name: "GitLab", category: .developer, auth: "Personal access token (read_api)", shows: "Merge requests and pipelines"),
        .init(id: "vercel", name: "Vercel", category: .developer, auth: "Access token", shows: "Deployments for your projects"),
        .init(id: "linear", name: "Linear", category: .developer, auth: "OAuth or personal API key", shows: "Issues assigned to you"),
        .init(id: "jira", name: "Jira", category: .developer, auth: "API token", shows: "Issues assigned to you"),
        .init(id: "n8n", name: "n8n", category: .developer, auth: "API key (self-hosted or cloud)", shows: "Workflow executions"),
        .init(id: "notion", name: "Notion", category: .business, auth: "OAuth (integration)", shows: "Pages you choose to share with Orbit"),
        .init(id: "stripe", name: "Stripe", category: .business, auth: "Restricted API key (read-only)", shows: "Recent payments and payouts"),
        .init(id: "slack", name: "Slack", category: .communication, auth: "OAuth (bot token)", shows: "Agent notifications to a channel you pick"),
        .init(id: "discord", name: "Discord", category: .communication, auth: "Webhook URL", shows: "Agent notifications to a channel"),
        .init(id: "telegram", name: "Telegram", category: .communication, auth: "Bot token", shows: "Agent notifications to a chat"),
    ]

    static let waitingReason = "Needs your credential. Orbit doesn't store credentials until it has a stable app signature for the Keychain."
}
