import Foundation
import Testing
@testable import Orbit

private func makeFolder(_ url: URL, git: Bool, modified: Date) throws {
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    if git { try FileManager.default.createDirectory(at: url.appending(path: ".git"), withIntermediateDirectories: true) }
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path(percentEncoded: false))
}

@Test func scannerListsFoldersNewestFirstAndFlagsGit() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let root = temp.url.appending(path: "Developer")
    try makeFolder(root.appending(path: "old-app"), git: true, modified: .init(timeIntervalSince1970: 1_000))
    try makeFolder(root.appending(path: "new-app"), git: true, modified: .init(timeIntervalSince1970: 9_000))
    try makeFolder(root.appending(path: "notes"), git: false, modified: .init(timeIntervalSince1970: 5_000))
    try makeFolder(root.appending(path: ".hidden"), git: false, modified: .init(timeIntervalSince1970: 9_999))
    try Data().write(to: root.appending(path: "README.md"))  // files are not projects

    let projects = ProjectScanner.projects(in: root)
    #expect(projects.map(\.name) == ["new-app", "notes", "old-app"])
    #expect(projects.map(\.isGitRepository) == [true, false, true])
    #expect(ProjectScanner.projects(in: root, limit: 1).map(\.name) == ["new-app"])
    #expect(ProjectScanner.projects(in: temp.url.appending(path: "missing")).isEmpty)
}

@MainActor @Test func projectsWidgetRescansOnStartAndReportsEmpty() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let root = temp.url.appending(path: "Developer")
    let widget = ProjectsWidget(root: root, didLaunch: {})
    guard case .empty = widget.state else {
        Issue.record("no projects yet")
        return
    }
    try makeFolder(root.appending(path: "orbit"), git: false, modified: .now)
    widget.start()
    #expect(widget.projects.map(\.name) == ["orbit"])
    #expect(widget.state == .ready)
}

@Test func finderIsAlwaysAvailable() {
    #expect(ProjectAction.finder.isAvailable)
}

@MainActor @Test func githubActivityIsLabelledSample() {
    let widget = GitHubWidget()
    #expect(widget.metadata.availability == .sample)
    #expect(!widget.activity.isEmpty)
}
