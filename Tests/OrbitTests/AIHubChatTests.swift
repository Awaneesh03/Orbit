import Foundation
import Synchronization
import Testing
@testable import Orbit

// AI Hub Phase 7: local chat through a stub URLProtocol (no network, no port).
// Not verified against a real Ollama or LM Studio: neither is installed here.

final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    static let responses = Mutex<[String: (Int, Data)]>([:])
    static let requested = Mutex<[String]>([])

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url?.absoluteString ?? ""
        Self.requested.withLock { $0.append(url) }
        let (status, body) = Self.responses.withLock { $0[url] } ?? (404, Data())
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!,
                            cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static var session: URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }
}

private func collect(_ stream: AsyncThrowingStream<String, any Error>) async throws -> String {
    var text = ""
    for try await piece in stream { text += piece }
    return text
}

/// These share the stub's responses, so they run one at a time.
@Suite(.serialized) struct LocalChatTests {
    @Test func providersDiscoverModelsAndStream() async throws {
        StubURLProtocol.responses.withLock {
            $0["http://127.0.0.1:11434/api/tags"] = (200, Data(#"{"models":[{"name":"qwen3:8b"},{"name":"llama3.2"}]}"#.utf8))
            $0["http://127.0.0.1:11434/api/chat"] = (200, Data("""
                {"message":{"role":"assistant","content":"Hel"},"done":false}
                {"message":{"role":"assistant","content":"lo"},"done":false}
                {"message":{"role":"assistant","content":""},"done":true}
                {"message":{"role":"assistant","content":"ignored"},"done":false}

                """.utf8))
            $0["http://127.0.0.1:1234/v1/models"] = (200, Data(#"{"data":[{"id":"local-model"}]}"#.utf8))
            $0["http://127.0.0.1:1234/v1/chat/completions"] = (200, Data("""
                data: {"choices":[{"delta":{"content":"Hi "}}]}

                data: {"choices":[{"delta":{"content":"there"}}]}

                data: [DONE]

                """.utf8))
        }
        let session = StubURLProtocol.session
        let message = HubChatMessage(id: UUID(), role: .user, content: "hey", createdAt: .now)
        #expect(try await OllamaProvider().models(session: session) == ["llama3.2", "qwen3:8b"])
        #expect(try await collect(OllamaProvider().stream(model: "llama3.2", messages: [message], session: session)) == "Hello")
        #expect(try await OpenAICompatibleProvider.lmStudio.models(session: session) == ["local-model"])
        #expect(try await collect(OpenAICompatibleProvider.lmStudio.stream(model: "local-model", messages: [message], session: session)) == "Hi there")
    }

    @Test func onlyThisMacIsEverContacted() async throws {
        let remote = OpenAICompatibleProvider(id: "x", name: "Remote", baseURL: URL(string: "https://api.example.com/v1")!)
        let plain = OpenAICompatibleProvider(id: "y", name: "LAN", baseURL: URL(string: "http://192.168.1.5:1234/v1")!)
        StubURLProtocol.requested.withLock { $0 = [] }
        for provider in [remote, plain] {
            #expect(!provider.isLocal)
            await #expect(throws: ChatError.notLocal) { try await provider.models(session: StubURLProtocol.session) }
            await #expect(throws: ChatError.notLocal) {
                try await collect(provider.stream(model: "m", messages: [], session: StubURLProtocol.session))
            }
        }
        #expect(StubURLProtocol.requested.withLock { $0 }.isEmpty)  // refused before any request
    }

    @MainActor @Test func aChatStreamsIsSavedAndComesBack() async throws {
        let temp = TemporaryDirectory()
        defer { temp.cleanup() }
        StubURLProtocol.responses.withLock {
            $0["http://127.0.0.1:11434/api/tags"] = (200, Data(#"{"models":[{"name":"llama3.2"}]}"#.utf8))
            $0["http://127.0.0.1:11434/api/chat"] = (200, Data("{\"message\":{\"content\":\"Four.\"},\"done\":true}\n".utf8))
            $0["http://127.0.0.1:1234/v1/models"] = (404, Data())
        }
        let store = HubStore(url: temp.url.appending(path: "chat.sqlite"))
        let chat = ChatService(session: StubURLProtocol.session, store: store)
        await chat.refresh()
        #expect(chat.hasLocalModels && chat.selectedProvider == "ollama" && chat.selectedModel == "llama3.2")
        #expect(chat.providers.first { $0.id == "lm-studio" }?.available == false)
        let notes = temp.url.appending(path: "notes.txt")
        try "remember the milk".write(to: notes, atomically: true, encoding: .utf8)
        chat.attach(notes)
        chat.attach(temp.url.appending(path: "missing.txt"))
        #expect(chat.attachments.count == 1 && chat.lastError != nil)
        chat.draft = "What is 2 + 2?"
        chat.send()
        for _ in 0 ..< 300 where chat.isStreaming { try await Task.sleep(for: .milliseconds(10)) }
        let conversation = try #require(chat.current)
        #expect(conversation.messages.map(\.role) == [.user, .assistant] && conversation.messages[1].content == "Four.")
        #expect(conversation.messages[0].content.contains("remember the milk") && chat.attachments.isEmpty)
        try await Task.sleep(for: .milliseconds(100))  // the save runs after the stream
        let reloaded = ChatService(session: StubURLProtocol.session, store: HubStore(url: temp.url.appending(path: "chat.sqlite")))
        await reloaded.refresh()
        #expect(reloaded.conversations.first?.messages.map(\.content).last == "Four." && reloaded.conversations.first?.title == "What is 2 + 2?")
        reloaded.delete(try #require(reloaded.conversations.first).id)
        try await Task.sleep(for: .milliseconds(100))
            await store.close()
    }
}

@MainActor @Test func largeOrBinaryFilesArentAttached() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let chat = ChatService(session: StubURLProtocol.session)
    let big = temp.url.appending(path: "big.txt")
    try Data(repeating: 0x61, count: ChatService.maxAttachmentBytes + 1).write(to: big)
    let binary = temp.url.appending(path: "bin.dat")
    try Data([0xFF, 0xFE, 0x00, 0xD8]).write(to: binary)
    chat.attach(big)
    chat.attach(binary)
    #expect(chat.attachments.isEmpty && chat.lastError == "Only text files up to 100 KB can be attached.")
}
