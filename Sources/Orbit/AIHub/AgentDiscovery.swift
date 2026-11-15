import Foundation

// Which coding agents are on this Mac (docs/AI_HUB_SPEC.md §14, P1-5): known
// executable paths and app bundles only. Nothing is executed, no version
// command is run and no other process is started; a present file says
// "installed", not "working" (e.g. a broken install still has its file).

enum AgentDiscovery {
    struct Known: Sendable {
        let id: String
        let name: String
        /// Absolute, or relative to the home folder when starting with "~/".
        let paths: [String]
    }

    struct Found: Identifiable, Equatable, Sendable {
        let id: String
        let name: String
        /// The first known path that exists; nil when none does.
        let path: String?
        var isInstalled: Bool { path != nil }
    }

    static let known: [Known] = [
        Known(id: "claude-code", name: "Claude Code",
              paths: ["~/.local/bin/claude", "~/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]),
        Known(id: "codex", name: "OpenAI Codex",
              paths: ["/opt/homebrew/bin/codex", "/usr/local/bin/codex", "~/.local/bin/codex", "/Applications/Codex.app"]),
        Known(id: "copilot-cli", name: "GitHub Copilot CLI",
              paths: ["/opt/homebrew/bin/copilot", "/usr/local/bin/copilot", "~/.local/bin/copilot"]),
        Known(id: "cursor", name: "Cursor",
              paths: ["/Applications/Cursor.app", "~/Applications/Cursor.app", "~/.local/bin/cursor-agent"]),
        Known(id: "antigravity", name: "Google Antigravity",
              paths: ["/Applications/Antigravity.app", "/Applications/Antigravity IDE.app", "~/Applications/Antigravity.app",
                      "~/.local/bin/agy", "/opt/homebrew/bin/agy"]),
        Known(id: "gemini-cli", name: "Gemini CLI",
              paths: ["/opt/homebrew/bin/gemini", "/usr/local/bin/gemini", "~/.local/bin/gemini"]),
        Known(id: "opencode", name: "OpenCode",
              paths: ["~/.opencode/bin/opencode", "/opt/homebrew/bin/opencode", "/usr/local/bin/opencode", "~/.local/bin/opencode"]),
    ]

    /// A person-facing name for an agent ID (simulated agents say so).
    static func displayName(for agent: AgentID) -> String {
        if agent.isDemo { return "Simulated agent (\(agent.rawValue.dropFirst(AgentID.demoPrefix.count)))" }
        return known.first { $0.id == agent.rawValue }?.name ?? agent.rawValue
    }

    /// `exists` answers for one absolute path (tests pass their own).
    static func scan(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     exists: (String) -> Bool = installed) -> [Found] {
        let homePath = home.path(percentEncoded: false)
        return known.map { agent in
            let paths = agent.paths.map { $0.hasPrefix("~/") ? (homePath as NSString).appendingPathComponent(String($0.dropFirst(2))) : $0 }
            return Found(id: agent.id, name: agent.name, path: paths.first(where: exists))
        }
    }

    /// An app bundle folder, or an executable file (following symlinks).
    static func installed(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return path.hasSuffix(".app") ? isDirectory.boolValue : !isDirectory.boolValue && FileManager.default.isExecutableFile(atPath: path)
    }
}
