import SwiftUI

enum AIProvider: String, Codable, CaseIterable, Identifiable, Sendable {
    case chatGPT = "ChatGPT", claude = "Claude", gemini = "Gemini"
    var id: Self { self }
}

struct ChatMessage: Identifiable, Equatable, Sendable {
    enum Role: Sendable { case user, assistant }

    let id = UUID()
    let role: Role
    let text: String
    let provider: AIProvider
}

struct AIPreferences: Codable, Equatable, Sendable {
    var provider = AIProvider.claude
}

/// AI Hub foundation: model choice and a chat. SAMPLE: replies come from
/// `MockData.aiReply`; nothing is sent anywhere and no API keys exist. The
/// model choice is saved (ai.json); conversations are not.
@MainActor @Observable
final class AIChatWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "ai", title: "AI Hub", description: "Chat with ChatGPT, Claude or Gemini",
        symbol: "sparkles", category: .ai, availability: .sample,
        presentations: [.compact, .expanded], sectionPresentation: .expanded, isEnabledByDefault: false)
    private(set) var preferences: Persisted<AIPreferences>
    private(set) var messages: [ChatMessage] = []
    private(set) var isResponding = false
    var draft = ""
    private let replyDelay: Duration

    let state = WidgetState.ready
    var provider: AIProvider { preferences.value.provider }

    init(file: JSONFile<AIPreferences>, replyDelay: Duration = .milliseconds(700)) {
        preferences = Persisted(file, initial: AIPreferences())
        self.replyDelay = replyDelay
    }

    func select(_ provider: AIProvider) { preferences.update { $0.provider = provider } }

    func send() {
        let prompt = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !isResponding else { return }
        draft = ""
        let provider = provider
        messages.append(ChatMessage(role: .user, text: prompt, provider: provider))
        isResponding = true
        Task { [weak self, replyDelay] in
            try? await Task.sleep(for: replyDelay)
            guard let self else { return }
            self.messages.append(ChatMessage(role: .assistant, text: MockData.aiReply(to: prompt, from: provider),
                                             provider: provider))
            self.isResponding = false
        }
    }

    func clear() {
        guard !isResponding else { return }
        messages = []
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(AIChatView(widget: self, isCompact: presentation == .compact))
    }
}

private struct AIChatView: View {
    let widget: AIChatWidget
    let isCompact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 4) {
                ForEach(AIProvider.allCases) { provider in
                    let isSelected = provider == widget.provider
                    Button { widget.select(provider) } label: {
                        Text(provider.rawValue)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .foregroundStyle(isSelected ? .white : Theme.secondary)
                    }
                    .buttonStyle(OrbitSelectableStyle(isSelected: isSelected))
                }
                Spacer()
                if !isCompact && !widget.messages.isEmpty {
                    Button("Clear") { widget.clear() }
                        .buttonStyle(DashboardButtonStyle())
                        .foregroundStyle(Theme.secondary)
                }
            }
            transcript
            HStack(spacing: 6) {
                TextField("Message \(widget.provider.rawValue)", text: Binding(get: { widget.draft }, set: { widget.draft = $0 }))
                    .textFieldStyle(.plain)
                    .onSubmit { widget.send() }
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .orbitSurface(radius: 14)
                Button { widget.send() } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 20))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(DashboardButtonStyle())
                .disabled(widget.isResponding)
            }
        }
    }

    private var transcript: some View {
        let shown = isCompact ? Array(widget.messages.suffix(2)) : widget.messages
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if shown.isEmpty {
                    Text("Replies here are samples until the AI Hub is connected. Nothing you type is sent anywhere.")
                        .foregroundStyle(Theme.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(shown) { message in bubble(message) }
                if widget.isResponding {
                    Text("\(widget.provider.rawValue) is typing…").foregroundStyle(Theme.tertiary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollIndicators(.never)
        .frame(maxHeight: .infinity)
    }

    private func bubble(_ message: ChatMessage) -> some View {
        let isUser = message.role == .user
        return HStack {
            if isUser { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 3) {
                if !isUser {
                    Text("\(message.provider.rawValue.uppercased()) · SAMPLE REPLY")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                }
                Text(message.text).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(isUser ? Theme.accent.opacity(0.28) : OrbitGlass.surfaceFill, in: .rect(cornerRadius: OrbitGlass.innerRadius, style: .continuous))
            if !isUser { Spacer(minLength: 40) }
        }
    }
}
