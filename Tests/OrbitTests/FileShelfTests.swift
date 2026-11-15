import Foundation
import Testing
@testable import Orbit

// Milestone 9: the File Shelf never moves, modifies or overwrites a file it
// didn't make, and only ever deletes Orbit's own copies.

@MainActor
private func fixture() throws -> (TemporaryDirectory, FileShelf, URL) {
    let temp = TemporaryDirectory()
    let originals = temp.url.appending(path: "Desktop", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    let shelf = FileShelf(file: temp.file("shelf.json"), folder: temp.url.appending(path: "Shelf", directoryHint: .isDirectory))
    return (temp, shelf, originals)
}

private func write(_ text: String, to url: URL) throws { try Data(text.utf8).write(to: url) }

@MainActor @Test func aReferenceLeavesTheOriginalAloneAndFollowsAMove() throws {
    let (temp, shelf, originals) = try fixture()
    defer { temp.cleanup() }
    let report = originals.appending(path: "report.pdf")
    try write("pdf", to: report)
    #expect(shelf.add([report]) == 1)
    #expect(shelf.add([report]) == 0)  // already shelved
    let item = try #require(shelf.items.first)
    #expect(item.storage == .reference && item.size == 3 && item.name == "report.pdf")
    #expect(try String(contentsOf: report, encoding: .utf8) == "pdf")  // untouched
    let moved = originals.appending(path: "renamed.pdf")
    try FileManager.default.moveItem(at: report, to: moved)
    #expect(shelf.resolve(item)?.lastPathComponent == "renamed.pdf")  // the bookmark follows it
    shelf.remove(item)
    #expect(FileManager.default.fileExists(atPath: moved.path(percentEncoded: false)))  // removing a reference never deletes the file
}

@MainActor @Test func copiesLiveInTheirOwnFolderAndNeverOverwrite() throws {
    let (temp, shelf, originals) = try fixture()
    defer { temp.cleanup() }
    let note = originals.appending(path: "note.txt")
    try write("one", to: note)
    shelf.add([note], copy: true)
    try write("two", to: note)
    shelf.add([note], copy: true)  // the same name again: a second copy, not an overwrite
    let copies = shelf.items.filter { $0.storage == .copy }
    #expect(copies.count == 2 && Set(copies.map(\.path)).count == 2)
    #expect(Set(try copies.map { try String(contentsOf: URL(filePath: $0.path), encoding: .utf8) }) == ["one", "two"])
    for copy in copies { #expect(copy.path.hasPrefix(shelf.folder.path(percentEncoded: false))) }
    shelf.remove(copies[0])
    #expect(!FileManager.default.fileExists(atPath: copies[0].path))  // Orbit's copy goes with it
    #expect(try String(contentsOf: note, encoding: .utf8) == "two")  // the original never
}

@MainActor @Test func linksFoldersAndOddFilesAreHandledSafely() throws {
    let (temp, shelf, originals) = try fixture()
    defer { temp.cleanup() }
    let target = originals.appending(path: "secret.txt")
    try write("s", to: target)
    let link = originals.appending(path: "link.txt")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    #expect(shelf.add([link]) == 0 && shelf.message?.contains("Links") == true)
    let folder = originals.appending(path: "Project", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    #expect(shelf.add([folder], copy: true) == 0)  // folders are references only
    #expect(shelf.add([folder]) == 1 && shelf.items.first?.isFolder == true)
    #expect(shelf.add([URL(string: "https://example.com/file.zip")!]) == 0)  // not a file
    #expect(shelf.add([originals.appending(path: "missing.txt")]) == 0)
}

@MainActor @Test func oldItemsExpireAndOnlyOrbitsCopiesAreDeleted() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var now = Date(timeIntervalSince1970: 1_000_000)
    let folder = temp.url.appending(path: "Shelf", directoryHint: .isDirectory)
    let original = temp.url.appending(path: "keep.txt")
    try write("keep", to: original)
    let shelf = FileShelf(file: temp.file("shelf.json"), folder: folder, clock: { now })
    shelf.add([original])
    shelf.add([original], copy: true)
    let copyPath = try #require(shelf.items.first { $0.storage == .copy }?.path)
    now = now.addingTimeInterval(8 * 86_400)
    shelf.expire()
    #expect(shelf.items.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: copyPath) && FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
    // The index persists (a relaunch keeps the shelf).
    shelf.add([original])
    #expect(FileShelf(file: temp.file("shelf.json"), folder: folder, clock: { now }).items.count == 1)
}

@Test func pathsForAgentsAreShellQuoted() {
    #expect(FileShelf.quoted("/Users/me/My File.txt") == "'/Users/me/My File.txt'")
    #expect(FileShelf.quoted("/tmp/it's") == "'/tmp/it'\\''s'")
}

// MARK: Milestone 14: projects, search, agent hand-off

@Test func projectsComeFromKnownFoldersByPathOnly() {
    let roots = ["/Users/me/Developer/Orbit", "/Users/me/Developer/Orbit/Packages/Kit/"]
    let containers = ["/Users/me/Developer"]
    #expect(FileShelf.project(of: "/Users/me/Developer/Orbit/Sources/a.swift", roots: roots, containers: containers) == "/Users/me/Developer/Orbit")
    #expect(FileShelf.project(of: "/Users/me/Developer/Orbit/Packages/Kit/x.swift", roots: roots, containers: containers)
            == "/Users/me/Developer/Orbit/Packages/Kit")  // the deepest known folder wins
    #expect(FileShelf.project(of: "/Users/me/Developer/Site/index.html", roots: roots, containers: containers) == "/Users/me/Developer/Site")
    #expect(FileShelf.project(of: "/Users/me/Developer/notes.txt", roots: roots, containers: containers) == nil)  // loose file
    #expect(FileShelf.project(of: "/Users/me/Developer/OrbitOld/a", roots: ["/Users/me/Developer/Orbit"], containers: []) == nil)  // not a prefix trick
    #expect(FileShelf.project(of: "/Users/me/Desktop/a.png", roots: roots, containers: containers) == nil)
}

@MainActor @Test func theShelfSearchesFiltersAndFindsASessionsFiles() throws {
    let (temp, shelf, originals) = try fixture()
    defer { temp.cleanup() }
    let orbit = originals.appending(path: "Orbit", directoryHint: .isDirectory), site = originals.appending(path: "Site", directoryHint: .isDirectory)
    for folder in [orbit, site] { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    let spec = orbit.appending(path: "spec.md"), logo = site.appending(path: "logo.png"), copied = orbit.appending(path: "it's.txt")
    for file in [spec, logo, copied] { try write("x", to: file) }
    shelf.add([spec]); shelf.add([logo]); shelf.add([copied], copy: true)
    shelf.projectRoots = { ([orbit.path(percentEncoded: false)], [originals.path(percentEncoded: false)]) }

    #expect(shelf.items.first { $0.name == "it's.txt" }?.originalPath == copied.path(percentEncoded: false))  // a copy remembers its origin
    #expect(shelf.projects.map { ($0 as NSString).lastPathComponent } == ["Orbit", "Site"])
    shelf.projectFilter = shelf.projects.first
    #expect(Set(shelf.visibleItems.map(\.name)) == ["spec.md", "it's.txt"])  // the copy groups with its original's project
    shelf.projectFilter = nil
    shelf.query = "LOGO"
    #expect(shelf.visibleItems.map(\.name) == ["logo.png"])
    shelf.query = "site png"  // every word, in the name or the folder
    #expect(shelf.visibleItems.map(\.name) == ["logo.png"])
    shelf.query = ""

    let session = shelf.items(inside: orbit.path(percentEncoded: false) + "/")
    #expect(Set(session.map(\.name)) == ["spec.md", "it's.txt"])
    #expect(shelf.items(inside: "").isEmpty)
    let paths = shelf.agentPaths(session)
    #expect(paths.found == 2 && paths.missing == 0 && paths.text.contains(#"'\''s.txt'"#))  // quoted, never run
    try FileManager.default.removeItem(at: spec)
    #expect(shelf.agentPaths(session).missing == 1)  // gone files are named, not pasted
    #expect(FileManager.default.fileExists(atPath: copied.path(percentEncoded: false)))  // the original of the copy is untouched
}
