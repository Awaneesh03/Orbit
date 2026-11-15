import SwiftUI

// Daily Digest (Milestone 14): today in a few lines, from what Orbit already
// knows (weather, calendar, tasks, news, yesterday's agent work), each line
// naming its source. Optional: a model running on this Mac (Ollama or LM
// Studio, through ChatService's local-only providers) rewrites it as prose.
// - Off by default; Orbit never downloads a model or contacts anything but 127.0.0.1.
// - The plain digest is always there: no model, a failure, or a model that
//   adds numbers not in your data (a made-up time or count) all fall back to it.

struct DigestFact: Equatable, Sendable {
    let source: String
    let text: String
}

enum DailyDigest {
    struct Inputs {
        var forecast: Forecast?
        var events: [AgendaEvent] = []
        var tasks: [ChecklistItem] = []
        var news: [NewsStory] = []
        var insights: AIHubService.Insights?
        // Milestone 17: the Daily Intelligence Briefing (from the Context Engine; empty when it's off).
        var workspace: String?
        var goals: [ChecklistItem] = []
        var agentsWaiting: [String] = []
        var agentsDoneToday: [String] = []
        var focusSessionsToday = 0
        /// Suggestions, kept apart from the facts (never sent to a model as facts).
        var suggestions: [String] = []
    }

    static func facts(_ inputs: Inputs, now: Date, calendar: Calendar = .current) -> [DigestFact] {
        var facts: [DigestFact] = []
        if let forecast = inputs.forecast {
            let unit = forecast.unit == .celsius ? "°C" : "°F"
            var parts: [String] = []
            if abs(forecast.current.time.timeIntervalSince(now)) < 3 * 3600 {  // a cached reading from hours ago isn't "now"
                parts.append("\(WeatherCondition(code: forecast.current.code).title), \(Int(forecast.current.temperature.rounded()))\(unit) in \(forecast.place.name)")
            }
            if let today = forecast.daily.first(where: { calendar.isDate($0.date, inSameDayAs: now) }) {
                var line = "high \(Int(today.high.rounded()))\(unit), low \(Int(today.low.rounded()))\(unit)"
                if parts.isEmpty { line = "In \(forecast.place.name) today: " + line }
                if let rain = today.rainChance, rain >= 30 { line += ", \(rain)% chance of rain" }
                parts.append(line)
            }
            if !parts.isEmpty { facts.append(DigestFact(source: "Weather", text: parts.joined(separator: "; "))) }
        }
        let timed = inputs.events.filter { !$0.isAllDay && $0.end > now && calendar.isDate($0.start, inSameDayAs: now) }.sorted { $0.start < $1.start }
        if let next = timed.first {
            let time = next.start.formatted(date: .omitted, time: .shortened)
            facts.append(DigestFact(source: "Calendar", text: "\(timed.count) more event\(timed.count == 1 ? "" : "s") today; next: \(next.title) at \(time)"))
        }
        let open = inputs.tasks.filter { !$0.isDone }
        let dueToday = open.filter { $0.dueDate.map { calendar.isDate($0, inSameDayAs: now) } ?? false }
        let overdue = open.filter { $0.dueDate.map { $0 < calendar.startOfDay(for: now) } ?? false }
        if !open.isEmpty {
            var line = "\(open.count) open task\(open.count == 1 ? "" : "s")"
            if !dueToday.isEmpty { line += ", \(dueToday.count) due today (\(dueToday.prefix(2).map(\.title).joined(separator: ", ")))" }
            if !overdue.isEmpty { line += ", \(overdue.count) overdue" }
            facts.append(DigestFact(source: "Tasks", text: line))
        }
        if let workspace = inputs.workspace { facts.append(DigestFact(source: "Workspace", text: "Workspace: \(workspace)")) }
        if !inputs.goals.isEmpty {
            let done = inputs.goals.filter(\.isDone).count
            let next = inputs.goals.first { !$0.isDone }.map { "; next: \($0.title)" } ?? ""
            facts.append(DigestFact(source: "Goals", text: "\(done) of \(inputs.goals.count) daily goals done" + next))
        }
        if !inputs.agentsWaiting.isEmpty || !inputs.agentsDoneToday.isEmpty {
            var parts: [String] = []
            if !inputs.agentsWaiting.isEmpty { parts.append(inputs.agentsWaiting.joined(separator: ", ") + " waiting for you") }
            if !inputs.agentsDoneToday.isEmpty {
                parts.append("\(inputs.agentsDoneToday.count) agent session\(inputs.agentsDoneToday.count == 1 ? "" : "s") finished today")
            }
            facts.append(DigestFact(source: "AI Hub", text: parts.joined(separator: "; ")))
        }
        if inputs.focusSessionsToday > 0 {
            facts.append(DigestFact(source: "Focus", text: "\(inputs.focusSessionsToday) focus session\(inputs.focusSessionsToday == 1 ? "" : "s") today"))
        }
        for story in inputs.news.prefix(2) {
            facts.append(DigestFact(source: story.sourceName, text: story.title))
        }
        if inputs.agentsWaiting.isEmpty, inputs.agentsDoneToday.isEmpty, let insights = inputs.insights,
           let yesterday = insights.days.dropLast().last, yesterday.count > 0 {
            facts.append(DigestFact(source: "AI Hub", text: "\(yesterday.count) agent events yesterday"
                                    + (insights.projects.first.map { ", mostly in \(($0.project as NSString).lastPathComponent)" } ?? "")))
        }
        return facts
    }

    /// The digest without a model: one sentence per fact.
    static func plain(_ facts: [DigestFact]) -> String {
        facts.isEmpty ? "Nothing to summarise yet: add the Weather, Calendar, Tasks or News widgets." : facts.map { $0.text + "." }.joined(separator: " ")
    }

    static func messages(_ facts: [DigestFact], now: Date) -> [HubChatMessage] {
        let list = facts.map { "- [\($0.source)] \($0.text)" }.joined(separator: "\n")
        return [
            HubChatMessage(id: UUID(), role: .system, content: """
                You write a short morning briefing. Use ONLY the facts given. Do not add times, numbers, names, events or advice \
                that are not in the facts. If a fact is unclear, leave it out. Two to four plain sentences, no lists, no greeting.
                """, createdAt: now),
            HubChatMessage(id: UUID(), role: .user, content: "Facts:\n\(list)", createdAt: now),
        ]
    }

    /// A cheap guard against invention: every number the model wrote must appear in the facts.
    static func isGrounded(_ summary: String, in facts: [DigestFact]) -> Bool {
        let source = facts.map(\.text).joined(separator: " ")
        let known = Set(numbers(in: source))
        return !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && numbers(in: summary).allSatisfy(known.contains)
    }

    static func numbers(in text: String) -> [String] {
        text.split { !$0.isNumber }.map(String.init)
    }
}

struct DigestSettings: Codable, Equatable, Sendable {
    var useLocalModel = false
    var model: String?
    /// Write the model's digest once a day, the first time the widget shows.
    var daily = false
    var lastSummary: String?
    var lastModel: String?
    var lastDay: String?

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useLocalModel = (try? container.decode(Bool.self, forKey: .useLocalModel)) ?? false
        model = try? container.decode(String.self, forKey: .model)
        daily = (try? container.decode(Bool.self, forKey: .daily)) ?? false
        lastSummary = try? container.decode(String.self, forKey: .lastSummary)
        lastModel = try? container.decode(String.self, forKey: .lastModel)
        lastDay = try? container.decode(String.self, forKey: .lastDay)
    }
}

@MainActor @Observable
final class DailyDigestWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "digest", title: "Daily Digest", description: "Today in a few lines, optionally written by a model on this Mac",
        symbol: "text.append", category: .productivity, availability: .live, isEnabledByDefault: false)
    var state: WidgetState { .ready }
    private(set) var stored: Persisted<DigestSettings>
    var settings: DigestSettings { stored.value }
    /// Local models found (only looked for once the user turns the model on).
    private(set) var models: [(provider: String, model: String)] = []
    private(set) var isWriting = false
    private(set) var note: String?
    /// What Orbit knows today (set by the app).
    @ObservationIgnored var inputs: @MainActor () -> DailyDigest.Inputs = { .init() }
    @ObservationIgnored private let providers: [any ChatProvider]
    @ObservationIgnored private let session: URLSession
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var writing: Task<Void, Never>?

    init(file: JSONFile<DigestSettings>?, providers: [any ChatProvider] = [OllamaProvider(), OpenAICompatibleProvider.lmStudio],
         session: URLSession = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil), now: @escaping () -> Date = { .now }) {
        stored = file.map { Persisted($0, initial: DigestSettings()) } ?? Persisted(memory: DigestSettings())
        self.providers = providers.filter(\.isLocal)
        self.session = session
        self.now = now
    }

    var facts: [DigestFact] { DailyDigest.facts(inputs(), now: now()) }
    var suggestions: [String] { inputs().suggestions }

    /// Today's model digest, if one was written today and it's still on.
    var modelSummary: (text: String, model: String)? {
        guard settings.useLocalModel, settings.lastDay == GoalsWidget.dayKey(now()),
              let text = settings.lastSummary, let model = settings.lastModel else { return nil }
        return (text, model)
    }

    func start() {
        guard settings.useLocalModel else { return }
        Task {
            await findModels()
            if settings.daily, modelSummary == nil, settings.model != nil { write() }
        }
    }

    func stop() {}

    func setUseLocalModel(_ on: Bool) {
        stored.update { $0.useLocalModel = on }
        if on { Task { await findModels() } } else { writing?.cancel(); models = []; note = nil }
    }

    func choose(model: String) { stored.update { $0.model = model } }
    func setDaily(_ on: Bool) { stored.update { $0.daily = on } }

    /// Asks the local servers which models are installed. Never pulls one.
    func findModels() async {
        var found: [(String, String)] = []
        for provider in providers {
            if let names = try? await provider.models(session: session) { found += names.map { (provider.id, $0) } }
        }
        models = found
        if found.isEmpty {
            note = "No local model found. Start Ollama or LM Studio with a model you've installed; Orbit never downloads one."
        } else {
            note = nil
            if settings.model == nil || !found.contains(where: { $0.1 == settings.model }) { stored.update { $0.model = found[0].1 } }
        }
    }

    /// Writes today's digest with the chosen local model, on request (or once a day if asked).
    func write() {
        guard settings.useLocalModel, let model = settings.model,
              let providerID = models.first(where: { $0.model == model })?.provider,
              let provider = providers.first(where: { $0.id == providerID }) else { return }
        let facts = self.facts
        guard !facts.isEmpty else { note = "Nothing to summarise yet."; return }
        writing?.cancel()
        isWriting = true
        note = nil
        writing = Task { [weak self, session] in
            var text = ""
            do {
                for try await piece in provider.stream(model: model, messages: DailyDigest.messages(facts, now: .now), session: session) {
                    text += piece
                    if text.count > 1200 { break }
                }
            } catch {
                self?.finish(nil, model: model, note: "\(provider.name) didn't answer; showing the plain digest.")
                return
            }
            guard !Task.isCancelled else { return }
            if DailyDigest.isGrounded(text, in: facts) {
                self?.finish(text.trimmingCharacters(in: .whitespacesAndNewlines), model: model, note: nil)
            } else {
                self?.finish(nil, model: model, note: "The model added details that aren't in your data, so the plain digest is shown.")
            }
        }
    }

    private func finish(_ text: String?, model: String, note: String?) {
        isWriting = false
        self.note = note
        guard let text else { return }
        stored.update {
            $0.lastSummary = text
            $0.lastModel = model
            $0.lastDay = GoalsWidget.dayKey(now())
        }
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(DailyDigestView(widget: self, compact: presentation == .compact))
    }
}

private struct DailyDigestView: View {
    let widget: DailyDigestWidget
    let compact: Bool

    var body: some View {
        let facts = widget.facts
        VStack(alignment: .leading, spacing: 6) {
            if let summary = widget.modelSummary {
                Text(summary.text).font(OrbitType.body).foregroundStyle(.white.opacity(0.92)).lineLimit(compact ? 4 : 8)
                Text("Written by \(summary.model) on this Mac, from the sources below").font(.system(size: 9)).foregroundStyle(Theme.tertiary)
            } else {
                Text(DailyDigest.plain(facts)).font(OrbitType.body).foregroundStyle(.white.opacity(0.92)).lineLimit(compact ? 4 : 8)
            }
            if !widget.suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Suggested (not facts)").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.tertiary).textCase(.uppercase)
                    ForEach(widget.suggestions.prefix(compact ? 1 : 3), id: \.self) { line in
                        Label(line, systemImage: "lightbulb").font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
            }
            if !compact {
                HStack(spacing: 4) {
                    ForEach(Array(Set(facts.map(\.source))).sorted(), id: \.self) { source in
                        Text(source).font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 2).background(OrbitGlass.surfaceFill, in: .capsule)
                    }
                }
                HStack(spacing: 8) {
                    Text("Local model").font(OrbitType.caption).foregroundStyle(Theme.secondary)
                    OrbitSwitch(label: "Write the digest with a model on this Mac", isOn: widget.settings.useLocalModel) { widget.setUseLocalModel($0) }
                    if widget.settings.useLocalModel, !widget.models.isEmpty {
                        Menu(widget.settings.model ?? "Model") {
                            ForEach(widget.models, id: \.model) { found in Button(found.model) { widget.choose(model: found.model) } }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(OrbitType.caption)
                        Text("Daily").font(OrbitType.caption).foregroundStyle(Theme.secondary)
                        OrbitSwitch(label: "Write it once a day, when the digest first shows", isOn: widget.settings.daily) { widget.setDaily($0) }
                    }
                }
                HStack(spacing: 8) {
                    if widget.settings.useLocalModel {
                        if widget.isWriting {
                            ProgressView().controlSize(.small)
                            Text("Writing on this Mac…").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                        } else if let model = widget.settings.model {
                            OrbitLinkButton(title: "Write with \(model)") { widget.write() }
                        }
                    }
                    if let note = widget.note { Text(note).font(OrbitType.caption).foregroundStyle(Theme.tertiary).lineLimit(2) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
