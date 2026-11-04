import Foundation
import Testing
@testable import Orbit

@Test func jsonFileIsNilWhenMissingAndRoundTrips() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<[String]> = temp.file("nested/list.json")
    #expect(try file.load() == nil)
    try file.save(["a", "b"])  // creates the folder
    #expect(try file.load() == ["a", "b"])
}

@Test func jsonFileThrowsOnCorruptData() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<[String]> = temp.file("bad.json")
    try Data("not json".utf8).write(to: file.url)
    #expect(throws: (any Error).self) { try file.load() }
}

@Test func persistedRefusesToOverwriteAnUnreadableFile() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<Checklist> = temp.file("tasks.json")
    let original = Data("{ corrupted".utf8)
    try original.write(to: file.url)

    var stored = Persisted(file, initial: Checklist())
    #expect(stored.problem != nil)
    stored.update { $0.add("would overwrite") }
    #expect(stored.value.items.isEmpty)
    #expect(try Data(contentsOf: file.url) == original)  // data left untouched
}

@Test func persistedSavesEachChange() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<Checklist> = temp.file("tasks.json")
    var stored = Persisted(file, initial: Checklist())
    #expect(stored.problem == nil)
    stored.update { $0.add("Ship Step 5") }
    #expect(try file.load()?.items.map(\.title) == ["Ship Step 5"])
}
