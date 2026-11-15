import Foundation

// Orbit's Claude Code hooks (Phase 2; docs/AI_HUB_SPEC.md §8, §13 D1), as a
// plan the user reviews before anything is written. Observe-only by
// construction: one non-blocking command hook per observed event, never
// PermissionRequest, never a decision (the helper prints nothing). Every
// other key and hook in the file — NotchBuddy's included — is kept; Orbit's
// entries are recognised by the helper's path and removed by it alone.
// Writing to the user's real ~/.claude/settings.json needs their explicit
// approval (an approval gate): nothing in Orbit calls `apply` on its own.

enum ClaudeHookInstaller {
    struct Failure: Error, Equatable, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Where Orbit's helper is installed for agents to run.
    static var helperPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Orbit/AgentHook/OrbitAgentHook").path(percentEncoded: false)
    }

    static var settingsURL: URL { FileManager.default.homeDirectoryForCurrentUser.appending(path: ".claude/settings.json") }

    /// Seconds Claude Code waits for the helper (it finishes in milliseconds).
    static let timeout = 5

    static func command(helper: String, event: String) -> String {
        "\"\(helper)\" --agent claude-code --event \(event)"
    }

    /// The settings with Orbit's hooks added (an earlier Orbit set replaced).
    /// `settings` nil: no file yet. Refuses a file that isn't a JSON object.
    static func installing(into settings: Data?, helper: String) throws(Failure) -> Data {
        var root = try object(settings)
        var hooks = try removingOrbit(from: root["hooks"], helper: helper)
        for event in ClaudeCodeAdapter.observedEvents {
            precondition(event != "PermissionRequest")  // D1
            var entries = hooks[event] as? [Any] ?? []
            entries.append(["hooks": [["type": "command", "command": command(helper: helper, event: event), "timeout": timeout]]])
            hooks[event] = entries
        }
        root["hooks"] = hooks
        return try serialise(root)
    }

    /// The settings with only Orbit's hooks taken out.
    static func removing(from settings: Data, helper: String) throws(Failure) -> Data {
        var root = try object(settings)
        let hooks = try removingOrbit(from: root["hooks"], helper: helper)
        root["hooks"] = hooks.isEmpty ? nil : hooks
        return try serialise(root)
    }

    /// Whether Coucou's relay (`nb-hook`) is Claude's PermissionRequest hook, i.e.
    /// Coucou answers Claude's prompts while it runs. Read-only: Orbit never
    /// changes Coucou's entries (decision A, docs/AI_HUB_SPEC.md §21).
    static func coucouAnswersPermissions(in settings: Data?) -> Bool {
        guard let root = try? object(settings), let hooks = root["hooks"] as? [String: Any] else { return false }
        return (hooks["PermissionRequest"] as? [Any] ?? []).contains { entry in
            ((entry as? [String: Any])?["hooks"] as? [Any] ?? []).contains {
                (($0 as? [String: Any])?["command"] as? String)?.contains("nb-hook") == true
            }
        }
    }

    /// The observed events that have Orbit's hook.
    static func installedEvents(in settings: Data?, helper: String) -> Set<String> {
        guard let root = try? object(settings), let hooks = root["hooks"] as? [String: Any] else { return [] }
        return Set(hooks.compactMap { event, entries in
            (entries as? [Any] ?? []).contains { isOrbit($0, helper: helper) } ? event : nil
        })
    }

    /// Writes `new` over `url` atomically after copying the current file to
    /// `settings.json.orbit-backup-<time>[-n]` (never overwriting a backup).
    /// Only after the user approved the exact change.
    @discardableResult
    static func apply(_ new: Data, to link: URL, now: Date = .now) throws(Failure) -> URL? {
        // A settings file symlinked into a dotfiles repository: back up and write the real file, keep the link.
        let url = link.resolvingSymlinksInPath()
        var backup: URL?
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "UTC")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let base = "\(url.lastPathComponent).orbit-backup-\(formatter.string(from: now))"
            for n in 0 ..< 1000 {
                let candidate = url.deletingLastPathComponent().appending(path: n == 0 ? base : "\(base)-\(n)")
                if (try? FileManager.default.copyItem(at: url, to: candidate)) != nil { backup = candidate; break }
                if !FileManager.default.fileExists(atPath: candidate.path(percentEncoded: false)) {
                    throw Failure("Couldn't back up \(url.lastPathComponent)")
                }
            }
            guard backup != nil else { throw Failure("Couldn't back up \(url.lastPathComponent)") }
        }
        do {
            try new.write(to: url, options: .atomic)
        } catch {
            throw Failure("Couldn't write \(url.lastPathComponent)")
        }
        return backup
    }

    /// Copies the helper shipped inside Orbit.app to `helperPath` (folder 0700).
    static func installHelper(from source: URL? = Bundle.main.url(forAuxiliaryExecutable: "OrbitAgentHook"),
                              to destination: String = helperPath) throws(Failure) {
        guard let source, FileManager.default.isExecutableFile(atPath: source.path(percentEncoded: false)) else {
            throw Failure("Orbit's hook helper isn't in this build of Orbit")
        }
        let target = URL(filePath: destination)
        do {
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            let staged = target.deletingLastPathComponent().appending(path: ".OrbitAgentHook-\(UUID().uuidString)")
            try FileManager.default.copyItem(at: source, to: staged)
            _ = try FileManager.default.replaceItemAt(target, withItemAt: staged)
        } catch {
            throw Failure("Couldn't install Orbit's hook helper")
        }
    }

    /// What installing would change, for the confirmation dialog.
    static func preview(settings: Data?, helper: String) -> String {
        let installed = installedEvents(in: settings, helper: helper)
        let others = (try? object(settings)).flatMap { $0["hooks"] as? [String: Any] }.map { hooks in
            hooks.values.reduce(0) { $0 + (($1 as? [Any])?.filter { !isOrbit($0, helper: helper) }.count ?? 0) }
        } ?? 0
        let missing = ClaudeCodeAdapter.observedEvents.filter { !installed.contains($0) }
        return """
            Adds \(missing.count) observe-only hook\(missing.count == 1 ? "" : "s") to ~/.claude/settings.json \
            (\(missing.joined(separator: ", "))). Each runs Orbit's helper, which reports the event and prints nothing. \
            No PermissionRequest hook: Claude's prompts stay with NotchBuddy and the terminal. \
            Keeps the \(others) hook entr\(others == 1 ? "y" : "ies") already there and every other setting. \
            The current file is backed up first.
            """
    }

    // MARK: Private

    private static func object(_ data: Data?) throws(Failure) -> [String: Any] {
        guard let data, !data.isEmpty else { return [:] }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw Failure("settings.json isn't a JSON object; it was left untouched")
        }
        return root
    }

    private static func removingOrbit(from value: Any?, helper: String) throws(Failure) -> [String: Any] {
        guard let value else { return [:] }
        guard let hooks = value as? [String: Any] else { throw Failure("settings.json \"hooks\" isn't an object; it was left untouched") }
        var result: [String: Any] = [:]
        for (event, entries) in hooks {
            guard let list = entries as? [Any] else {
                result[event] = entries  // not ours to judge
                continue
            }
            let kept = list.compactMap { entry -> Any? in
                guard var matcher = entry as? [String: Any], let inner = matcher["hooks"] as? [Any] else { return entry }
                let others = inner.filter { !isOrbitHook($0, helper: helper) }
                if others.count == inner.count { return entry }
                if others.isEmpty { return nil }
                matcher["hooks"] = others
                return matcher
            }
            if !kept.isEmpty { result[event] = kept }
        }
        return result
    }

    private static func isOrbit(_ entry: Any, helper: String) -> Bool {
        ((entry as? [String: Any])?["hooks"] as? [Any] ?? []).contains { isOrbitHook($0, helper: helper) }
    }

    private static func isOrbitHook(_ hook: Any, helper: String) -> Bool {
        ((hook as? [String: Any])?["command"] as? String)?.hasPrefix("\"\(helper)\" --agent claude-code") == true
    }

    private static func serialise(_ root: [String: Any]) throws(Failure) -> Data {
        guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            throw Failure("Couldn't encode settings.json")
        }
        return data + Data("\n".utf8)
    }
}
