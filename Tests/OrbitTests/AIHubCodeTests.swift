import Foundation
import Testing
@testable import Orbit

// AI Hub Phase 5: code intelligence on a throwaway git repository.

private func git(_ arguments: [String], in folder: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main"] + arguments
    process.currentDirectoryURL = folder
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0, "git \(arguments)")
}

private func repository(_ temp: TemporaryDirectory) throws -> URL {
    let repo = temp.url.appending(path: "repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git(["init", "-q"], in: repo)
    try "one\ntwo\nthree\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)
    try "keep\n".write(to: repo.appending(path: "b.txt"), atomically: true, encoding: .utf8)
    try "old name\n".write(to: repo.appending(path: "old.txt"), atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: repo)
    try git(["commit", "-q", "-m", "First commit"], in: repo)
    try "one\nTWO\nthree\nfour\n".write(to: repo.appending(path: "a.txt"), atomically: true, encoding: .utf8)  // +2 −1
    try "new\n".write(to: repo.appending(path: "new.txt"), atomically: true, encoding: .utf8)  // untracked
    try git(["mv", "old.txt", "renamed.txt"], in: repo)
    return repo
}

@Test func aSnapshotShowsBranchCommitAndChangedFiles() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let repo = try repository(temp)
    let root = repo.resolvingSymlinksInPath().path(percentEncoded: false)
    let snapshot = try #require(await CodeChangeService.snapshot(of: repo.appending(path: ".").path(percentEncoded: false),
                                                                 touched: [root + "/a.txt"]))
    #expect(snapshot.branch == "main" && snapshot.subject == "First commit" && snapshot.commit?.count ?? 0 >= 7)
    #expect(snapshot.files.map(\.path) == ["a.txt", "new.txt", "renamed.txt"])  // the session's file first
    let edited = try #require(snapshot.files.first)
    #expect(edited.touchedBySession && edited.status == " M" && edited.additions == 2 && edited.deletions == 1)
    #expect(snapshot.files[1].status == "??" && snapshot.files[2].status.hasPrefix("R"))
    let diff = try #require(await CodeChangeService.diff(of: "a.txt", in: snapshot.root))
    #expect(diff.contains("-two") && diff.contains("+TWO") && diff.contains("+four"))
    #expect(await CodeChangeService.diff(of: "../outside.txt", in: snapshot.root) == nil)  // no climbing out
    #expect(await CodeChangeService.diff(of: "/etc/hosts", in: snapshot.root) == nil)
}

@Test func aRepositoryCantMakeOrbitRunAProgram() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let repo = try repository(temp)
    let marker = temp.url.appending(path: "ran")
    let script = temp.url.appending(path: "evil.sh")
    try "#!/bin/sh\ntouch '\(marker.path(percentEncoded: false))'\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    let evil = script.path(percentEncoded: false)
    try git(["config", "core.fsmonitor", evil], in: repo)
    try git(["config", "diff.external", evil], in: repo)
    try git(["config", "diff.evil.textconv", evil], in: repo)
    try "*.txt diff=evil\n".write(to: repo.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
    let snapshot = await CodeChangeService.snapshot(of: repo.path(percentEncoded: false))
    #expect(snapshot != nil)
    _ = await CodeChangeService.diff(of: "a.txt", in: try #require(snapshot).root)
    #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))  // nothing the repository configured ran
}

@Test func repositoriesThatCouldRunProgramsAreRefused() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let marker = temp.url.appending(path: "ran")
    let script = temp.url.appending(path: "evil.sh")
    try "#!/bin/sh\ntouch '\(marker.path(percentEncoded: false))'\ncat\n".write(to: script, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path(percentEncoded: false))
    let evil = script.path(percentEncoded: false)
    // A clean filter, a hook git runs on index refresh, and GPG on log: each refused or never run.
    for setup in [["config", "filter.x.clean", evil], ["config", "core.hooksPath", temp.url.appending(path: "hooks").path(percentEncoded: false)],
                  ["config", "gpg.program", evil]] {
        let repo = try repository(temp)
        try "*.txt filter=x\n".write(to: repo.appending(path: ".gitattributes"), atomically: true, encoding: .utf8)
        try git(setup, in: repo)
        try git(["config", "log.showSignature", "true"], in: repo)
        let snapshot = try #require(await CodeChangeService.snapshot(of: repo.path(percentEncoded: false)))
        #expect(snapshot.refused != nil && snapshot.files.isEmpty, "\(setup)")
        #expect(await CodeChangeService.diff(of: "a.txt", in: snapshot.root) == nil)
        try FileManager.default.removeItem(at: repo)
    }
    let repo = try repository(temp)
    let hooks = repo.appending(path: ".git/hooks")
    try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: script, to: hooks.appending(path: "post-index-change"))  // the default hooks folder
    let snapshot = try #require(await CodeChangeService.snapshot(of: repo.path(percentEncoded: false)))
    #expect(snapshot.refused == nil && !snapshot.files.isEmpty)  // inspected, with hooks off
    _ = await CodeChangeService.diff(of: "a.txt", in: snapshot.root)
    try FileManager.default.createDirectory(at: repo.appending(path: ".git/info"), withIntermediateDirectories: true)
    try "*.txt filter=x\n".write(to: repo.appending(path: ".git/info/attributes"), atomically: true, encoding: .utf8)
    #expect(await CodeChangeService.snapshot(of: repo.path(percentEncoded: false))?.refused != nil)
    #expect(!FileManager.default.fileExists(atPath: marker.path(percentEncoded: false)))  // nothing ran, in any of them
}

@Test func foldersThatArentRepositoriesGiveNothing() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    #expect(await CodeChangeService.snapshot(of: temp.url.path(percentEncoded: false)) == nil)
    #expect(await CodeChangeService.snapshot(of: "/Simulated/Atlas") == nil)
    #expect(await CodeChangeService.snapshot(of: "relative/path") == nil)
}

@Test func porcelainAndNumstatAreParsed() {
    let status = CodeChangeService.parseStatus(" M a.txt\0R  new name.txt\0old name.txt\0?? x\0")
    #expect(status.map(\.path) == ["a.txt", "new name.txt", "x"] && status.map(\.status) == [" M", "R ", "??"])
    let counts = CodeChangeService.parseNumstat("2\t1\ta.txt\0-\t-\timage.png\00\t0\t\0old.txt\0renamed.txt\0")
    #expect(counts["a.txt"]?.0 == 2 && counts["a.txt"]?.1 == 1 && counts["image.png"]?.0 == nil && counts["renamed.txt"]?.0 == 0)
}
