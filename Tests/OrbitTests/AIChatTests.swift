import Foundation
import Testing
@testable import Orbit

@MainActor @Test func sendAddsMessageThenASampleReply() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = AIChatWidget(file: temp.file("ai.json"), replyDelay: .milliseconds(20))
    widget.draft = "  Summarise my day  "
    widget.send()
    #expect(widget.draft.isEmpty)
    #expect(widget.messages.map(\.text) == ["Summarise my day"])
    #expect(widget.isResponding)
    widget.draft = "second"
    widget.send()  // ignored while a reply is pending
    #expect(widget.messages.count == 1)

    for _ in 0..<100 where widget.isResponding { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!widget.isResponding)
    #expect(widget.messages.count == 2)
    let reply = widget.messages[1]
    #expect(reply.role == .assistant)
    #expect(reply.provider == .claude)
    #expect(reply.text.hasPrefix("Sample reply"))
    #expect(reply.text.contains("nothing was sent"))
}

@MainActor @Test func emptyMessagesAreIgnoredAndClearWorks() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = AIChatWidget(file: temp.file("ai.json"), replyDelay: .milliseconds(10))
    widget.draft = "   "
    widget.send()
    #expect(widget.messages.isEmpty)
    widget.draft = "hi"
    widget.send()
    widget.clear()  // not while responding
    #expect(widget.messages.count == 1)
    for _ in 0..<100 where widget.isResponding { try await Task.sleep(for: .milliseconds(10)) }
    widget.clear()
    #expect(widget.messages.isEmpty)
}

@MainActor @Test func providerChoiceIsSavedButChatsAreNot() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = AIChatWidget(file: temp.file("ai.json"), replyDelay: .milliseconds(10))
    widget.select(.gemini)
    widget.draft = "private"
    widget.send()
    for _ in 0..<100 where widget.isResponding { try await Task.sleep(for: .milliseconds(10)) }
    #expect(widget.messages.last?.provider == .gemini)

    let relaunched = AIChatWidget(file: temp.file("ai.json"))
    #expect(relaunched.provider == .gemini)
    #expect(relaunched.messages.isEmpty)
    let saved = try String(contentsOf: temp.url.appending(path: "ai.json"), encoding: .utf8)
    #expect(!saved.contains("private"))
}
