import AppKit

struct Project: Identifiable, Equatable {
    var id: String { url.path(percentEncoded: false) }
    let name: String
    let url: URL
    let modified: Date
    var isGitRepository = false
}

enum ProjectScanner {
    /// Folders directly inside `root` (Git repositories flagged), most recently
    /// modified first. Lists names and dates only; never reads project contents.
    static func projects(in root: URL, limit: Int = 8) -> [Project] {
        let fileManager = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .contentModificationDateKey]
        guard let entries = try? fileManager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        else { return [] }
        let projects = entries.compactMap { url -> Project? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isDirectory == true else { return nil }
            return Project(name: url.lastPathComponent, url: url,
                           modified: values?.contentModificationDate ?? .distantPast,
                           isGitRepository: fileManager.fileExists(atPath: url.appending(path: ".git").path(percentEncoded: false)))
        }
        return Array(projects.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}

/// Ways to open a project. Each passes the folder to an app; Orbit never
/// reads it, and `~/Developer` is not a privacy-protected folder.
enum ProjectAction: CaseIterable, Identifiable {
    case editor, terminal, finder

    var id: Self { self }

    var title: String {
        switch self {
        case .editor: "VS Code"
        case .terminal: "Terminal"
        case .finder: "Finder"
        }
    }

    var symbol: String {
        switch self {
        case .editor: "chevron.left.forwardslash.chevron.right"
        case .terminal: "terminal"
        case .finder: "folder"
        }
    }

    private var bundleID: String? {
        switch self {
        case .editor: "com.microsoft.VSCode"
        case .terminal: "com.apple.Terminal"
        case .finder: nil
        }
    }

    /// False when the app isn't installed.
    var isAvailable: Bool {
        bundleID.map { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil } ?? true
    }

    @MainActor func open(_ project: Project) {
        guard let bundleID else {
            NSWorkspace.shared.open(project.url)
            return
        }
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return }
        NSWorkspace.shared.open([project.url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
    }
}
