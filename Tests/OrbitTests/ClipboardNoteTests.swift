import Foundation
import Testing
@testable import Orbit

// Milestone 8: clipboard history (memory only, off by default, private
// items skipped) and the quick note (saved as you type).

@MainActor
private final class FakeBoard {
    var change = 0
    var text: String?
    var types: Set<String> = ["public.utf8-plain-text"]
    func copy(_ value: String?, types: Set<String> = ["public.utf8-plain-text"]) { change += 1; text = value; self.types = types }
}

@MainActor
private func history(_ board: FakeBoard) -> ClipboardHistory {
    ClipboardHistory(read: { (board.change, board.text, board.types) },
                     write: { board.copy($0); return board.change })
}

@MainActor @Test func historyIsOffByDefaultAndRecordsOnlyNewCopies() {
    let board = FakeBoard()
    board.copy("already there")
    let clips = history(board)
    #expect(!clips.isOn)
    clips.poll()
    #expect(clips.items.isEmpty)  // off: nothing recorded
    clips.setOn(true)
    clips.poll()
    #expect(clips.items.isEmpty)  // what was on the clipboard before isn't history
    board.copy("first")
    clips.poll()
    board.copy("https://example.com")
    clips.poll()
    clips.poll()  // no change: nothing added
    #expect(clips.items.map(\.text) == ["https://example.com", "first"] && clips.items[0].isLink)
    board.copy("first")
    clips.poll()
    #expect(clips.items.map(\.text) == ["first", "https://example.com"])  // copied again: moved up, not duplicated
    clips.setOn(false)
    #expect(clips.items.isEmpty)  // off forgets everything
}

@MainActor @Test func privateAndHugeItemsAreNeverRecorded() {
    let board = FakeBoard()
    let clips = history(board)
    clips.setOn(true)
    board.copy("hunter2", types: ["public.utf8-plain-text", "org.nspasteboard.ConcealedType"])
    clips.poll()
    board.copy("one-time code", types: ["public.utf8-plain-text", "org.nspasteboard.TransientType"])
    clips.poll()
    board.copy(String(repeating: "x", count: ClipboardHistory.maxLength + 1))
    clips.poll()
    board.copy("   \n ")
    clips.poll()
    board.copy(nil, types: ["public.png"])  // an image: not text
    clips.poll()
    #expect(clips.items.isEmpty)
    clips.setOn(false)
}

@MainActor @Test func historyIsCappedAndCopyingBackIsntRecordedTwice() {
    let board = FakeBoard()
    let clips = history(board)
    clips.setOn(true)
    for index in 0 ..< ClipboardHistory.limit + 5 {
        board.copy("item \(index)")
        clips.poll()
    }
    #expect(clips.items.count == ClipboardHistory.limit && clips.items.first?.text == "item \(ClipboardHistory.limit + 4)")
    let old = clips.items.last!
    clips.copy(old)
    #expect(board.text == old.text && clips.items.first?.text == old.text)
    let count = clips.items.count
    clips.poll()  // the pasteboard changed because of us: not a new item
    #expect(clips.items.count == count)
    clips.setOn(false)
}

@MainActor @Test func theQuickNoteSavesAfterTypingAndWhenHidden() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<String> = temp.file("quicknote.json")
    let note = QuickNoteWidget(file: file, saveDelay: .milliseconds(30))
    #expect(note.text.isEmpty && (try? file.load()) == nil)  // nothing written until something's typed
    note.text = "buy milk"
    for _ in 0 ..< 100 where (try? file.load()) != "buy milk" { try await Task.sleep(for: .milliseconds(10)) }
    #expect(try file.load() == "buy milk")
    note.text = "buy milk and eggs"
    note.stop()  // hidden: saved at once
    #expect(try file.load() == "buy milk and eggs")
    #expect(QuickNoteWidget(file: file).text == "buy milk and eggs")  // a relaunch
}
