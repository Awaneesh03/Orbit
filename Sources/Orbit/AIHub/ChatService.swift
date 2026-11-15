import AppKit
import Foundation

// AI Chat (Phase 7; docs/AI_HUB_SPEC.md §4 F): chat with models on this Mac.
// Local providers only for now — Ollama and OpenAI-compatible servers such as
// LM Studio — reached on 127.0.0.1 (Orbit opens no port; nothing leaves the
// Mac). Cloud providers (Anthropic, OpenAI, Gemini) need API keys, which wait
// for the signing decision (D3): they're listed, not usable. Consumer
// subscriptions are never treated as API keys; no CLI's token is reused.

struct HubChatMessage: Identifiable, Equatable, Sendable {
    enum Role: String, Codable, Sendable { case user, assistant, system }
    let id: UUID
    let role: Role
    var content: String
    let createdAt: Date
}

struct ChatConversation: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var provider: String
    var model: String
    var messages: [HubChatMessage]
    let createdAt: Date
    var updatedAt: Date
}

enum ChatError: Error, Equatable {
    case notLocal, unavailable, badResponse(Int), noModel
}

/// One way of talking to models.
protocol ChatProvider: Sendable {
    var id: String { get }
    var name: String { get }
    var baseURL: URL { get }
    func models(session: URLSession) async throws -> [String]
    func stream(model: String, messages: [HubChatMessage], session: URLSession) -> AsyncThrowingStream<String, any Error>
}

extension ChatProvider {
    /// Only this Mac: anything else is refused before a request is made.
    var isLocal: Bool { ["127.0.0.1", "localhost", "::1"].contains(baseURL.host() ?? "") && baseURL.scheme == "http" }

    func request(_ path: String, body: [String: Any]? = nil) throws -> URLRequest {
        guard isLocal else { throw ChatError.notLocal }
        var request = URLRequest(url: baseURL.appending(path: path), timeoutInterval: 120)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return request
    }

    /// Streams `parse(line)` pieces from a line-oriented response.
    func lines(_ request: URLRequest, session: URLSession, parse: @escaping @Sendable (String) -> (piece: String?, done: Bool)) -> AsyncThrowingStream<String, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let (bytes, response) = try await session.bytes(for: request)
                    guard response.url?.host() == request.url?.host(), let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        throw ChatError.badResponse((response as? HTTPURLResponse)?.statusCode ?? 0)
                    }
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        let (piece, done) = parse(line)
                        if let piece, !piece.isEmpty { continuation.yield(piece) }
                        if done { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }  // cancelling the chat cancels the request
        }
    }
}

/// Ollama's native API (http://127.0.0.1:11434): `/api/tags`, streaming `/api/chat` (one JSON object per line).
struct OllamaProvider: ChatProvider {
    let id = "ollama"
    let name = "Ollama"
    var baseURL = URL(string: "http://127.0.0.1:11434")!

    func models(session: URLSession) async throws -> [String] {
        let (data, response) = try await session.data(for: request("api/tags"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let models = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] else {
            throw ChatError.unavailable
        }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    func stream(model: String, messages: [HubChatMessage], session: URLSession) -> AsyncThrowingStream<String, any Error> {
        let body: [String: Any] = ["model": model, "stream": true, "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }]
        guard let request = try? request("api/chat", body: body) else { return AsyncThrowingStream { $0.finish(throwing: ChatError.notLocal) } }
        return lines(request, session: session, parse: Self.parse)
    }

    static func parse(_ line: String) -> (piece: String?, done: Bool) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return (nil, false) }
        return ((object["message"] as? [String: Any])?["content"] as? String, object["done"] as? Bool ?? false)
    }
}

/// OpenAI-compatible local servers (LM Studio: http://127.0.0.1:1234/v1): `/models`, streaming `/chat/completions` (SSE).
struct OpenAICompatibleProvider: ChatProvider {
    let id: String
    let name: String
    let baseURL: URL

    static let lmStudio = OpenAICompatibleProvider(id: "lm-studio", name: "LM Studio", baseURL: URL(string: "http://127.0.0.1:1234/v1")!)

    func models(session: URLSession) async throws -> [String] {
        let (data, response) = try await session.data(for: request("models"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let models = (try JSONSerialization.jsonObject(with: data) as? [String: Any])?["data"] as? [[String: Any]] else {
            throw ChatError.unavailable
        }
        return models.compactMap { $0["id"] as? String }.sorted()
    }

    func stream(model: String, messages: [HubChatMessage], session: URLSession) -> AsyncThrowingStream<String, any Error> {
        let body: [String: Any] = ["model": model, "stream": true, "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] }]
        guard let request = try? request("chat/completions", body: body) else { return AsyncThrowingStream { $0.finish(throwing: ChatError.notLocal) } }
        return lines(request, session: session, parse: Self.parse)
    }

    static func parse(_ line: String) -> (piece: String?, done: Bool) {
        guard line.hasPrefix("data:") else { return (nil, false) }
        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return (nil, true) }
        guard let object = try? JSONSerialization.jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let choice = (object["choices"] as? [[String: Any]])?.first else { return (nil, false) }
        return ((choice["delta"] as? [String: Any])?["content"] as? String, choice["finish_reason"] is String)
    }
}

/// Refuses every redirect, so a local server can't send Orbit (and a prompt) off the Mac.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? { nil }

    static let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
}

/// Conversations, streaming and attachments; persisted in their own SQLite file.
@MainActor @Observable
final class ChatService {
    struct ProviderState: Identifiable {
        let provider: any ChatProvider
        var models: [String] = []
        var available = false
        var id: String { provider.id }
    }

    /// Cloud providers, shown but not usable until credentials can be stored safely (D3).
    static let cloudProviders = ["Anthropic", "OpenAI", "Google Gemini"]
    static let maxAttachmentBytes = 100 * 1024

    private(set) var providers: [ProviderState]
    private(set) var conversations: [ChatConversation] = []
    var selectedConversation: UUID?
    var selectedProvider: String?
    var selectedModel: String?
    var draft = ""
    /// Text files attached to the next message (name, contents).
    private(set) var attachments: [(name: String, text: String)] = []
    private(set) var isStreaming = false
    private(set) var lastError: String?

    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let store: HubStore?
    @ObservationIgnored private var streaming: Task<Void, Never>?

    init(providers: [any ChatProvider] = [OllamaProvider(), OpenAICompatibleProvider.lmStudio],
         session: URLSession = NoRedirects.session, store: HubStore? = nil) {
        self.providers = providers.map { ProviderState(provider: $0) }
        self.session = session
        self.store = store
    }

    var current: ChatConversation? { conversations.first { $0.id == selectedConversation } }
    var hasLocalModels: Bool { providers.contains { $0.available && !$0.models.isEmpty } }

    /// Loads saved conversations and asks each local server for its models (on demand, not polled).
    func refresh() async {
        if let store, conversations.isEmpty {
            await store.open()
            conversations = await store.conversations()
        }
        for index in providers.indices {
            let models = try? await providers[index].provider.models(session: session)
            providers[index].models = models ?? []
            providers[index].available = models != nil
        }
        if selectedProvider == nil || !(providers.first { $0.id == selectedProvider }?.available ?? false) {
            let first = providers.first { $0.available && !$0.models.isEmpty }
            selectedProvider = first?.id
            selectedModel = first?.models.first
        }
    }

    func newConversation() { selectedConversation = nil }

    /// Attaches a text file (UTF-8, at most 100 KB) to the next message.
    func attach(_ url: URL) {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count <= Self.maxAttachmentBytes,
              let text = String(data: data, encoding: .utf8) else {
            lastError = "Only text files up to 100 KB can be attached."
            return
        }
        attachments.append((url.lastPathComponent, text))
    }

    func removeAttachments() { attachments = [] }

    func send() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isStreaming, let providerID = selectedProvider, let model = selectedModel,
              let provider = providers.first(where: { $0.id == providerID })?.provider else {
            if selectedModel == nil { lastError = "No local model is available." }
            return
        }
        lastError = nil
        draft = ""
        let context = attachments.map { "Attached file \($0.name):\n```\n\($0.text)\n```" }.joined(separator: "\n\n")
        attachments = []
        let now = Date.now
        var conversation = current ?? ChatConversation(id: UUID(), title: String(text.prefix(48)), provider: providerID, model: model,
                                                       messages: [], createdAt: now, updatedAt: now)
        conversation.messages.append(HubChatMessage(id: UUID(), role: .user, content: context.isEmpty ? text : context + "\n\n" + text, createdAt: now))
        let reply = HubChatMessage(id: UUID(), role: .assistant, content: "", createdAt: now)
        conversation.messages.append(reply)
        conversation.updatedAt = now
        upsert(conversation)
        selectedConversation = conversation.id
        isStreaming = true
        let history = Array(conversation.messages.dropLast())
        streaming = Task { [weak self] in
            do {
                for try await piece in provider.stream(model: model, messages: history, session: self?.session ?? .shared) {
                    self?.append(piece, to: reply.id, in: conversation.id)
                }
            } catch is CancellationError {
            } catch {
                self?.lastError = "\(provider.name) didn't answer (\(error))."
            }
            self?.finish(conversation.id)
        }
    }

    /// Stops the reply in progress (what arrived so far is kept).
    func cancel() { streaming?.cancel() }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if selectedConversation == id { selectedConversation = nil }
        Task { await store?.deleteConversation(id) }
    }

    private func append(_ piece: String, to message: UUID, in conversation: UUID) {
        guard let c = conversations.firstIndex(where: { $0.id == conversation }),
              let m = conversations[c].messages.firstIndex(where: { $0.id == message }) else { return }
        conversations[c].messages[m].content += piece
    }

    private func finish(_ id: UUID) {
        isStreaming = false
        streaming = nil
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        Task { await store?.save(conversation: conversation) }
    }

    private func upsert(_ conversation: ChatConversation) {
        if let index = conversations.firstIndex(where: { $0.id == conversation.id }) {
            conversations[index] = conversation
        } else {
            conversations.insert(conversation, at: 0)
        }
    }
}
