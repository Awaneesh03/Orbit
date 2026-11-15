import Foundation
import Testing
@testable import Orbit

// Milestone 9: jump to an agent's terminal or editor, as precisely as public
// APIs allow, and never anything an agent event chooses.

private func session(agent: String = "claude-code", bundle: String?, pid: Int32? = nil, cwd: String? = "/Users/me/Orbit") -> AgentSession {
    var session = AgentSession(key: SessionKey(agent: AgentID(agent)!, nativeID: "s1")!, status: .running, startedAt: .now, lastEventAt: .now,
                               originBundleID: bundle)
    session.originPID = pid
    session.cwd = cwd
    return session
}

private func env(installed: [String: String] = [:], running: [pid_t: String] = [:], folders: Set<String> = ["/Users/me/Orbit"]) -> AgentJump.Environment {
    AgentJump.Environment(isRunning: { pid, bundle in running[pid] == bundle },
                          appURL: { installed[$0].map { URL(filePath: $0) } },
                          isFolder: { folders.contains($0) })
}

@Test func anEditorOpensTheProjectsOwnWindow() {
    let plan = AgentJump.plan(session(bundle: "com.todesktop.230313mzl4w4u92", pid: 42),
                              in: env(installed: ["com.todesktop.230313mzl4w4u92": "/Applications/Cursor.app"], running: [42: "com.todesktop.230313mzl4w4u92"]))
    #expect(plan == .editorWindow(URL(string: "cursor://file/Users/me/Orbit")!, app: "Cursor"))
    #expect(AgentJump.title(plan) == "Open in Cursor")
}

@Test func aTerminalBringsItsExactProcessForward() {
    let plan = AgentJump.plan(session(bundle: "com.googlecode.iterm2", pid: 77),
                              in: env(installed: ["com.googlecode.iterm2": "/Applications/iTerm.app"], running: [77: "com.googlecode.iterm2"]))
    #expect(plan == .process(77, app: "iTerm"))
    #expect(AgentJump.help(plan).contains("Automation permission"))  // honest about the tab
}

@Test func fallbacksAreHonest() {
    // The process is gone (or the PID now belongs to another app): the app, not a guess.
    let reused = AgentJump.plan(session(bundle: "com.apple.Terminal", pid: 77),
                                in: env(installed: ["com.apple.Terminal": "/System/Applications/Utilities/Terminal.app"], running: [77: "com.evil.app"]))
    #expect(reused == .app(URL(filePath: "/System/Applications/Utilities/Terminal.app"), name: "Terminal"))
    // The app isn't installed any more: the project folder.
    #expect(AgentJump.plan(session(bundle: "com.microsoft.VSCode"), in: env()) == .folder(URL(filePath: "/Users/me/Orbit")))
    // Neither: nothing to do, said plainly.
    #expect(AgentJump.plan(session(bundle: nil, cwd: "/gone"), in: env()) == .unavailable)
    // An editor whose project folder is missing: the app, never a URL for a path that isn't there.
    let editor = AgentJump.plan(session(bundle: "com.microsoft.VSCode", cwd: "/nope"),
                                in: env(installed: ["com.microsoft.VSCode": "/Applications/Visual Studio Code.app"]))
    #expect(editor == .app(URL(filePath: "/Applications/Visual Studio Code.app"), name: "Visual Studio Code"))
}

@Test func folderURLsAreEncodedAndOnlyForAbsolutePaths() {
    #expect(AgentJump.folderURL(scheme: "vscode", path: "/Users/me/My Project")?.absoluteString == "vscode://file/Users/me/My%20Project")
    #expect(AgentJump.folderURL(scheme: "vscode", path: "relative/path") == nil)
    #expect(AgentJump.folderURL(scheme: "vscode", path: "/a\0b") == nil)
    // The scheme only ever comes from the fixed table.
    #expect(Set(AgentJump.editorSchemes.values) == ["vscode", "vscode-insiders", "cursor", "windsurf", "zed"])
}
