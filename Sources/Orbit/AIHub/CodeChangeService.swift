import Foundation

// Code intelligence (Phase 5; docs/AI_HUB_SPEC.md §4 E): a session's branch,
// commit, changed files with additions/deletions, and one file's diff, from
// git, on demand only (no polling, no file watching). The folder comes from an
// agent, so it's untrusted: git runs without a shell, read-only, with every
// repository-configurable way of running a program turned off (fsmonitor,
// external diff, textconv), no optional locks, no prompts, a timeout and
// capped output. Nothing is written to the repository.

enum CodeChangeService {
    struct FileChange: Identifiable, Equatable, Sendable {
        let path: String  // relative to the repository root
        let status: String  // porcelain XY, e.g. " M", "A ", "??"
        let additions: Int?
        let deletions: Int?
        /// The session reported touching it.
        var touchedBySession = false
        var id: String { path }
    }

    struct Snapshot: Equatable, Sendable {
        let root: String
        /// Set when the repository was refused (nothing else was run in it).
        var refused: String? = nil
        let branch: String?
        let commit: String?
        let subject: String?
        let files: [FileChange]
        var additions: Int { files.compactMap(\.additions).reduce(0, +) }
        var deletions: Int { files.compactMap(\.deletions).reduce(0, +) }
    }

    static let git = "/usr/bin/git"
    static let timeout: TimeInterval = 5
    static let maxOutputBytes = 512 * 1024
    static let maxDiffBytes = 200 * 1024
    static let maxFiles = 500

    /// Arguments that keep a repository's own config from running anything.
    static let hardening = ["-c", "core.fsmonitor=false", "-c", "core.untrackedCache=false", "-c", "diff.external=",
                            "-c", "core.hooksPath=/dev/null", "-c", "log.showSignature=false", "-c", "core.pager=cat", "--no-pager"]

    /// Repository-level (local/worktree) settings that can make git run a program; any one refuses the repository.
    /// User-wide settings (git-lfs's filter, say) are the user's own and stay allowed.
    static let dangerousConfig = #"^(filter\.|gpg\.|diff\..*\.(command|textconv)|core\.(hookspath|fsmonitor|worktree|sshcommand|attributesfile|gitproxy)|include\.|includeif\.)"#

    /// nil when safe to inspect; otherwise why not.
    static func refusal(root: String) async -> String? {
        if let gitDir = await run(["rev-parse", "--absolute-git-dir"], in: root)?.trimmed,
           FileManager.default.fileExists(atPath: (gitDir as NSString).appendingPathComponent("info/attributes")) {
            return "The repository has .git/info/attributes, which can run programs"
        }
        // `--get-regexp` exits 1 when nothing matches: that's the safe answer.
        let (status, output) = await runStatus(["config", "--show-scope", "--get-regexp", dangerousConfig], in: root)
        if status == 1 { return nil }
        guard status == 0, let output else { return "Couldn't check the repository's settings" }
        // "command" scope is Orbit's own hardening (-c …), not the repository's.
        let local = output.split(separator: "\n").contains { $0.hasPrefix("local") || $0.hasPrefix("worktree") }
        return local ? "The repository's own settings can run programs (filters, hooks, GPG or diff commands)" : nil
    }

    /// The repository state for `folder`, marking files in `touched` (absolute paths). nil: not a git repository.
    static func snapshot(of folder: String, touched: Set<String> = []) async -> Snapshot? {
        guard isDirectory(folder), let root = await run(["rev-parse", "--show-toplevel"], in: folder)?.trimmed, isDirectory(root) else {
            return nil
        }
        if let reason = await refusal(root: root) {
            return Snapshot(root: root, refused: reason, branch: nil, commit: nil, subject: nil, files: [])
        }
        async let branchOutput = run(["rev-parse", "--abbrev-ref", "HEAD"], in: root)
        async let headOutput = run(["log", "-1", "--no-show-signature", "--format=%h%x00%s"], in: root)
        async let statusOutput = run(["status", "--porcelain=v1", "-z", "--untracked-files=normal"], in: root)
        async let numstatOutput = run(["diff", "--numstat", "-z", "--no-ext-diff", "--no-textconv", "HEAD"], in: root)
        let head = (await headOutput)?.trimmed.split(separator: "\0", maxSplits: 1).map(String.init) ?? []
        let counts = parseNumstat(await numstatOutput ?? "")
        let touchedCanonical = Set(touched.map(canonical))
        let files = parseStatus(await statusOutput ?? "").prefix(maxFiles).map { change in
            var change = change
            let counted = counts[change.path]
            change = FileChange(path: change.path, status: change.status, additions: counted?.0, deletions: counted?.1)
            change.touchedBySession = touchedCanonical.contains(canonical((root as NSString).appendingPathComponent(change.path)))
            return change
        }
        return Snapshot(root: root, branch: (await branchOutput)?.trimmed, commit: head.first, subject: head.count > 1 ? head[1] : nil,
                        files: files.sorted { ($0.touchedBySession ? 0 : 1, $0.path) < ($1.touchedBySession ? 0 : 1, $1.path) })
    }

    /// One file's uncommitted diff against HEAD (capped), or nil.
    static func diff(of path: String, in root: String) async -> String? {
        guard isDirectory(root), !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { return nil }
        guard await refusal(root: root) == nil else { return nil }
        guard let output = await run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", "HEAD", "--", path], in: root, limit: maxDiffBytes) else {
            return nil
        }
        return output.utf8.count >= maxDiffBytes ? output + "\n… (diff truncated)" : output
    }

    // MARK: Parsing

    /// `git status --porcelain=v1 -z`: "XY path\0", renames followed by the old path.
    static func parseStatus(_ output: String) -> [FileChange] {
        var changes: [FileChange] = []
        var entries = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let entry = entries.next() {
            guard entry.count > 3 else { continue }
            let status = String(entry.prefix(2))
            changes.append(FileChange(path: String(entry.dropFirst(3)), status: status, additions: nil, deletions: nil))
            if status.contains("R") || status.contains("C") { _ = entries.next() }  // the original path
        }
        return changes
    }

    /// `git diff --numstat -z`: "add\tdel\tpath\0" (binary: "-\t-"); renames: "add\tdel\t\0old\0new\0".
    static func parseNumstat(_ output: String) -> [String: (Int?, Int?)] {
        var result: [String: (Int?, Int?)] = [:]
        var entries = output.split(separator: "\0", omittingEmptySubsequences: false).makeIterator()
        while let entry = entries.next() {
            let parts = entry.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3 else { continue }
            var path = String(parts[2])
            if path.isEmpty {  // a rename: old, then new
                _ = entries.next()
                path = entries.next().map(String.init) ?? ""
            }
            if !path.isEmpty { result[path] = (Int(parts[0]), Int(parts[1])) }
        }
        return result
    }

    // MARK: Running git

    /// The path with its folder's symlinks resolved (/var and /private/var, /tmp and /private/tmp…); the file needn't exist.
    static func canonical(_ path: String) -> String {
        let folder = (path as NSString).deletingLastPathComponent
        guard let resolved = realpath(folder, nil) else { return path }
        defer { free(resolved) }
        return (String(cString: resolved) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return path.hasPrefix("/") && FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// git's standard output, or nil if it failed, timed out or wasn't there.
    static func run(_ arguments: [String], in folder: String, limit: Int = maxOutputBytes) async -> String? {
        let (status, output) = await runStatus(arguments, in: folder, limit: limit)
        return status == 0 ? output : nil
    }

    /// git's exit status and standard output (nil status: it couldn't run or timed out).
    static func runStatus(_ arguments: [String], in folder: String, limit: Int = maxOutputBytes) async -> (Int32?, String?) {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: runSync(arguments, in: folder, limit: limit))
            }
        }
    }

    private static func runSync(_ arguments: [String], in folder: String, limit: Int) -> (Int32?, String?) {
        guard FileManager.default.isExecutableFile(atPath: git) else { return (nil, nil) }
        let process = Process()
        process.executableURL = URL(filePath: git)
        process.arguments = hardening + ["-C", folder] + arguments
        process.currentDirectoryURL = URL(filePath: folder)
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
                               "GIT_CONFIG_NOSYSTEM": "1", "LC_ALL": "C", "HOME": NSHomeDirectory()]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (nil, nil) }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)
        var data = Data()
        let handle = output.fileHandleForReading
        while let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            if data.count < limit { data.append(chunk.prefix(limit - data.count)) }  // keep draining so git can finish
        }
        process.waitUntilExit()
        killer.cancel()
        guard process.terminationReason == .exit else { return (nil, nil) }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
