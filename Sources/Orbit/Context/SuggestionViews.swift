import SwiftUI

/// "Suggested for You" at the top of the Overview (Milestone 17): the engine's ranked suggestions (2 by
/// default), only when there are any, so the widget grid keeps its room otherwise.
struct SuggestionStrip: View {
    let engine: ContextEngine
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        let shown = engine.shown
        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                Text("Suggested for You").font(OrbitType.eyebrow).foregroundStyle(Theme.tertiary).textCase(.uppercase)
                    .accessibilityAddTraits(.isHeader)
                HStack(spacing: 8) {
                    ForEach(shown) { ranked in
                        SuggestionCard(engine: engine, suggestion: ranked.suggestion, roomy: shown.count == 1)
                            .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.97)))
                    }
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: shown.map(\.id))
        }
    }
}

struct SuggestionCard: View {
    let engine: ContextEngine
    let suggestion: Suggestion
    /// Alone in the strip: the secondary action gets its own button (otherwise it's first in the menu).
    var roomy = true
    var highContrast: Bool { HubAppearance.shared.increasedContrast }

    static func tint(_ category: Suggestion.Category) -> Color {
        switch category {
        case .attention: HubTokens.attention
        case .calendar: Color(red: 0.45, green: 0.72, blue: 1.0)
        case .agents: Theme.accent
        case .productivity: Color(red: 0.42, green: 0.84, blue: 0.62)
        case .workspace: Color(red: 0.78, green: 0.62, blue: 1.0)
        case .battery: BatteryStyle.charging
        }
    }

    var body: some View {
        let tint = Self.tint(suggestion.category)
        HStack(alignment: .center, spacing: 9) {
            Image(systemName: suggestion.symbol).font(.system(size: 12, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 26, height: 26).background(tint.opacity(0.16), in: .circle)
            VStack(alignment: .leading, spacing: 1) {
                Text(suggestion.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                Text(suggestion.detail).font(.system(size: 10.5)).foregroundStyle(Theme.secondary).lineLimit(1)
            }
            .help("Why: " + suggestion.reason)
            Spacer(minLength: 4)
            Button(suggestion.primary.label) { engine.accept(suggestion.id) }
                .buttonStyle(SuggestionButtonStyle(tint: tint, prominent: true))
            if roomy, let secondary = suggestion.secondary {
                Button(secondary.label) { engine.accept(suggestion.id, secondary: true) }
                    .buttonStyle(SuggestionButtonStyle(tint: tint, prominent: false))
            }
            Menu {
                Text("Why: \(suggestion.reason)")
                Divider()
                if !roomy, let secondary = suggestion.secondary {
                    Button(secondary.label) { engine.accept(suggestion.id, secondary: true) }
                    Divider()
                }
                Button("Snooze for \(Self.snoozeText(engine.preferences.snoozeMinutes))") { engine.snooze(suggestion.id) }
                Button("Dismiss") { engine.dismiss(suggestion.id) }
                Button("Not Relevant") { engine.markIrrelevant(suggestion.id) }
                Divider()
                Button("Turn Off “\(suggestion.category.title)”") { engine.disableCategory(suggestion.category) }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .accessibilityLabel("More options for \(suggestion.title)")
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .background(OrbitGlass.surfaceFill, in: .rect(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(
            suggestion.priority >= 90 ? tint.opacity(0.55) : .white.opacity(highContrast ? 0.4 : 0.07), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(suggestion.title). \(suggestion.detail). Why: \(suggestion.reason)")
    }

    static func snoozeText(_ minutes: Int) -> String {
        minutes < 60 ? "\(minutes) Minutes" : minutes % 60 == 0 ? "\(minutes / 60) Hour\(minutes == 60 ? "" : "s")" : "\(minutes) Minutes"
    }
}

private struct SuggestionButtonStyle: ButtonStyle {
    let tint: Color
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
            .foregroundStyle(prominent ? Color.black : .white.opacity(0.9))
            .padding(.horizontal, 9).frame(height: 22)
            .background(prominent ? tint : Color.white.opacity(configuration.isPressed ? 0.2 : 0.11), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(.capsule)
    }
}

// MARK: Settings › Suggestions and Settings › Context Inspector

struct SuggestionSettings: View {
    let model: SettingsModel

    private func pref<T>(_ key: WritableKeyPath<SuggestionPreferences, T>) -> Binding<T> {
        Binding(get: { model.preferences.value.suggestions[keyPath: key] }, set: { value in model.preferences.update { $0.suggestions[keyPath: key] = value } })
    }

    var body: some View {
        let value = model.preferences.value.suggestions
        Form {
            Section {
                Toggle(isOn: pref(\.enabled)) {
                    Text("Proactive suggestions")
                    Text("“Suggested for You” at the top of the Overview, from what Orbit already knows. Suggestions never do anything until you click.")
                }
                Picker("How many", selection: pref(\.frequency)) {
                    ForEach(SuggestionPreferences.Frequency.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .disabled(!value.enabled)
                Picker("Snooze for", selection: pref(\.snoozeMinutes)) {
                    ForEach([30, 60, 180, 480], id: \.self) { Text(SuggestionCard.snoozeText($0)).tag($0) }
                }
                .disabled(!value.enabled)
            }
            Section("Categories") {
                ForEach(Suggestion.Category.allCases, id: \.self) { category in
                    Toggle(category.title, isOn: Binding(
                        get: { !model.preferences.value.suggestions.disabledCategories.contains(category) },
                        set: { on in model.preferences.update { prefs in
                            prefs.suggestions.disabledCategories.removeAll { $0 == category }
                            if !on { prefs.suggestions.disabledCategories.append(category) }
                        } }))
                }
                Toggle(isOn: pref(\.workspaceRecommendations)) {
                    Text("Workspace recommendations")
                    Text("From your calendar, agents working in a workspace's projects, its schedule or its tasks. Orbit never switches by itself.")
                }
                Toggle(isOn: pref(\.smartFocus)) {
                    Text("Smart Focus")
                    Text("Suggests a 25- or 50-minute session when tasks pile up, offers to resume a paused one and sums up a finished one. Nothing is blocked.")
                }
                Toggle(isOn: pref(\.dailyBriefing)) {
                    Text("Daily Intelligence Briefing")
                    Text("Adds your workspace, agents, focus and today's suggestions to the Daily Digest (facts and suggestions kept apart).")
                }
            }
            Section {
                if let engine = model.context {
                    if engine.feedback.history.isEmpty {
                        Text("Nothing yet.").foregroundStyle(.secondary)
                    }
                    ForEach(engine.feedback.history.prefix(12)) { entry in
                        LabeledContent(entry.title) {
                            Text("\(entry.outcome) · \(entry.at.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                        }
                    }
                    if !engine.feedback.irrelevant.isEmpty {
                        LabeledContent("Marked not relevant", value: engine.feedback.irrelevant.sorted().joined(separator: ", "))
                    }
                    Button("Clear History and Reset Learning", role: .destructive) { engine.resetLearning() }
                        .disabled(engine.feedback == SuggestionFeedbackStore())
                }
            } header: {
                Text("History and Learning")
            } footer: {
                Text("Only what you click (accept, dismiss, snooze, not relevant) is remembered, in suggestions.json on this Mac. Nothing is uploaded; Orbit never reads keystrokes, screen contents or browser history.")
            }
        }
    }
}

struct ContextInspectorSettings: View {
    let model: SettingsModel

    var body: some View {
        Form {
            if let engine = model.context {
                let s = engine.snapshot
                Section("Status") {
                    LabeledContent("Last update", value: engine.lastUpdate.map { $0.formatted(date: .omitted, time: .standard) } ?? "Never")
                    LabeledContent("Updates", value: "\(engine.updates) · last took \(engine.lastDuration.formatted(.units(allowed: [.milliseconds, .microseconds], width: .narrow)))")
                    LabeledContent("Sources", value: "\(engine.sources.count) registered" + (engine.errors.isEmpty ? ", no errors" : ""))
                    ForEach(engine.errors.sorted(by: { $0.key < $1.key }), id: \.key) { error in
                        LabeledContent(error.key, value: error.value).foregroundStyle(.orange)
                    }
                    Button("Refresh Now") { engine.refresh() }
                }
                Section("Current context") {
                    LabeledContent("Workspace", value: s.workspace?.name ?? "None")
                    LabeledContent("Agents (24 h)", value: "\(s.agents.count) · \(s.waitingAgents.count) waiting · \(s.workingAgents.count) working")
                    LabeledContent("Meeting", value: s.meeting.map { "\($0.title), \($0.phase)" } ?? "None in the heads-up window")
                    LabeledContent("Today's events", value: "\(s.todayEvents.count)")
                    LabeledContent("Tasks", value: "\(s.openTasks.count) open · \(s.doneToday.count) done today")
                    LabeledContent("Goals", value: "\(s.goals.filter(\.isDone).count) of \(s.goals.count) done")
                    LabeledContent("Focus", value: ContextDiff.describe(s.focus) + " · \(s.focusSessionsToday) today")
                    LabeledContent("Battery", value: s.battery.map { "\($0.percent)%, \(BatteryStyle.label($0.chargeState))" } ?? "Unavailable")
                    LabeledContent("High energy", value: s.energyHog ?? "Not known (sampled only while the Battery widget shows)")
                    LabeledContent("Music", value: s.music == nil ? "Not playing" : "Playing")
                    LabeledContent("Displays", value: "\(s.displays)" + (s.externalDisplay ? " (external connected)" : ""))
                }
                Section("Suggestions shown") {
                    if engine.shown.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(engine.shown) { ranked in
                        LabeledContent(ranked.suggestion.title, value: "score \(ranked.score) (\(ranked.breakdown)) · \(ranked.suggestion.category.title)")
                    }
                }
                Section("Held back") {
                    if engine.suppressed.isEmpty { Text("None").foregroundStyle(.secondary) }
                    ForEach(engine.suppressed) { item in LabeledContent(item.suggestion.title, value: item.reason) }
                }
                Section("Active rules (automations)") {
                    let rules = s.automations.filter(\.isEnabled)
                    if rules.isEmpty { Text("None. Add them in General › Automations.").foregroundStyle(.secondary) }
                    ForEach(rules) { rule in
                        LabeledContent(rule.trigger.title, value: "\(rule.condition.title) → \(rule.action.title)")
                    }
                }
                Section {
                    Toggle("Record context events", isOn: Binding(get: { model.preferences.value.suggestions.diagnostics },
                                                                  set: { value in model.preferences.update { $0.suggestions.diagnostics = value } }))
                    if engine.events.isEmpty { Text(model.preferences.value.suggestions.diagnostics ? "No events yet." : "Recording is off.").foregroundStyle(.secondary) }
                    ForEach(engine.events.prefix(40)) { event in
                        LabeledContent {
                            Text(event.text).lineLimit(2)
                        } label: {
                            Text("\(event.at.formatted(date: .omitted, time: .standard)) · \(event.kind == .automation ? "automation" : event.source)")
                        }
                    }
                    if !engine.events.isEmpty { Button("Clear Events") { engine.clearEvents() } }
                } header: {
                    Text("Recent events")
                } footer: {
                    Text("Kept in memory only (the last 80) and never written to disk. Titles and names only: no file contents.")
                }
            } else {
                Text("The Context Engine starts with Orbit.").foregroundStyle(.secondary)
            }
        }
    }
}
