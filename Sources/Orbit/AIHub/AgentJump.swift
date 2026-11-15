import AppKit

// Jump to an agent's terminal or editor (Milestone 9). Public APIs only, no
// Accessibility, no Apple Events, no shell. Precision is reported honestly:
// - editors with a documented folder URL scheme open the session's project
//   window (its integrated terminal is there);
// - terminals: the exact app process that hosts the session is activated
//   (choosing its tab would need Apple Events / Automation permission);
// - otherwise the app is opened, or the project folder shown.
// Nothing from an agent event chooses what runs: the scheme comes from a
// fixed table by bundle ID, the path must be an existing folder.

enum AgentJump {
    enum Target: Equatable {
        /// Opens the project's window in the editor (exact window).
        case editorWindow(URL, app: String)
        /// The exact running app process (its window, not a specific tab).
        case process(pid_t, app: String)
        /// Opens or brings the app forward.
        case app(URL, name: String)
        /// No app to go to: the project in Finder.
        case folder(URL)
        case unavailable
    }

    /// Editors whose URL scheme opens a folder window, by bundle ID.
    static let editorSchemes: [String: String] = [
        "com.microsoft.VSCode": "vscode",
        "com.microsoft.VSCodeInsiders": "vscode-insiders",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
        "dev.zed.Zed": "zed",
    ]

    /// `vscode://file/Users/me/project`, path percent-encoded; nil for anything but an absolute path.
    static func folderURL(scheme: String, path: String) -> URL? {
        guard path.hasPrefix("/"), !path.contains("\0"),
              let encoded = path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else { return nil }
        return URL(string: "\(scheme)://file\(encoded)")
    }

    struct Environment {
        var isRunning: (pid_t, String) -> Bool = { pid, bundleID in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == bundleID
        }
        var appURL: (String) -> URL? = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }
        var isFolder: (String) -> Bool = { path in
            var directory: ObjCBool = false
            return FileManager.default.fileExists(atPath: path, isDirectory: &directory) && directory.boolValue
        }
    }

    static func plan(_ session: AgentSession, in env: Environment = Environment()) -> Target {
        let folder = session.cwd.flatMap { env.isFolder($0) ? $0 : nil }
        if let bundleID = session.originBundleID, let appURL = env.appURL(bundleID) {
            let name = FileManager.default.displayName(atPath: appURL.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "")
            if let scheme = editorSchemes[bundleID], let folder, let url = folderURL(scheme: scheme, path: folder) {
                return .editorWindow(url, app: name)
            }
            if let pid = session.originPID, env.isRunning(pid, bundleID) { return .process(pid, app: name) }
            return .app(appURL, name: name)
        }
        if let folder { return .folder(URL(filePath: folder)) }
        return .unavailable
    }

    /// What the button says, so the user knows how precise it will be.
    static func title(_ target: Target) -> String {
        switch target {
        case .editorWindow(_, let app): "Open in \(app)"
        case .process(_, let app), .app(_, let app): "Go to \(app)"
        case .folder: "Show Project"
        case .unavailable: "Unavailable"
        }
    }

    static func help(_ target: Target) -> String {
        switch target {
        case .editorWindow(_, let app): "Brings \(app)'s window for this project forward."
        case .process(_, let app): "Brings the \(app) running this session forward. Choosing its tab would need Automation permission, which Orbit doesn't ask for."
        case .app(_, let app): "Opens \(app). The session's own window can't be identified."
        case .folder: "The session's app isn't known; shows its project folder in Finder."
        case .unavailable: "This session has no app or project folder Orbit can open."
        }
    }

    @MainActor @discardableResult
    static func perform(_ target: Target) -> Bool {
        switch target {
        case .editorWindow(let url, _): return NSWorkspace.shared.open(url)
        case .process(let pid, _): return NSRunningApplication(processIdentifier: pid)?.activate() ?? false
        case .app(let url, _):
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            return true
        case .folder(let url):
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return true
        case .unavailable: return false
        }
    }
}
