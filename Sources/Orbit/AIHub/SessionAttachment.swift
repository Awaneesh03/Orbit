import AppKit

// Dropping files on a session (docs/AI_HUB_SPEC.md §23). What was weighed:
// typing into the agent's terminal or editor needs Accessibility (a new
// permission); no agent offers a supported "attach a file" input for a
// session Orbit didn't start (§3; Claude Code is observe-only anyway, D1);
// copying files into the project would write where the agent works; and
// capturing the session's window is out of scope. So Orbit only hands the
// user a reference: the dropped paths, quoted for a shell, on the clipboard,
// with the session's app brought forward to paste them. It never reads,
// copies, moves, uploads or runs the files.

enum SessionAttachment {
    static let maxFiles = 10

    enum Refusal: Error, Equatable, CustomStringConvertible {
        case nothing, tooMany, notLocal, missing(String), unsafeName(String), simulated

        var description: String {
            switch self {
            case .nothing: "Nothing to attach: drop files or folders."
            case .tooMany: "At most \(SessionAttachment.maxFiles) files at once."
            case .notLocal: "Only files on this Mac can be attached."
            case .missing(let name): "\(name) isn't there any more."
            case .unsafeName(let name): "\(name) has a name a terminal could misread; rename it first."
            case .simulated: "Simulated sessions can't take files."
            }
        }
    }

    /// Local files or folders that exist, with names a shell can't misread (no control characters), deduplicated.
    static func paths(_ urls: [URL], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Result<[String], Refusal> {
        guard !urls.isEmpty else { return .failure(.nothing) }
        guard urls.count <= maxFiles else { return .failure(.tooMany) }
        var paths: [String] = []
        for url in urls {
            guard url.isFileURL else { return .failure(.notLocal) }
            let path = url.standardizedFileURL.path(percentEncoded: false)
            let name = (path as NSString).lastPathComponent
            guard !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return .failure(.unsafeName(name)) }
            guard exists(path) else { return .failure(.missing(name)) }
            if !paths.contains(path) { paths.append(path) }
        }
        return .success(paths)
    }

    /// POSIX single quotes: pasted into a shell or an agent's prompt, it stays one argument, nothing expands.
    static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }

    static func text(_ paths: [String]) -> String { paths.map(quoted).joined(separator: " ") }

    /// Puts the reference on the clipboard — only ever after the user's own drop.
    static func copy(_ paths: [String], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(text(paths), forType: .string)
    }

    /// The file URLs a drop carries (anything else is ignored), at most one more than allowed so "too many" is noticed.
    @MainActor static func urls(from providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers.prefix(maxFiles + 1) where provider.canLoadObject(ofClass: URL.self) {
            let url: URL? = await withCheckedContinuation { continuation in
                _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
            }
            if let url { urls.append(url) }
        }
        return urls
    }
}
