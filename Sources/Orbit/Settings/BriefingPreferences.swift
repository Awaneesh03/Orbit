import Foundation
import Observation

/// Daily Briefing settings, in their own file (briefing.json) so they never
/// touch preferences.json or the widget layout. The Briefing is a tab of its
/// own (Stage 3.8): off until the user turns it on, and turning it on or off
/// never changes the Overview's layout.
struct BriefingPreferences: Codable, Equatable, Sendable {
    static let fileName = "briefing.json"
    static let currentVersion = 2
    /// The widgets the briefing is made of, in order, two rows of three cells:
    /// Weather, Calendar (expanded); Clock, Daily Goals, Tasks (all compact:
    /// expanded Tasks already lists the goals).
    static let defaultWidgets: [WidgetID] = ["weather", "events", "clock", "goals", "tasks"]
    /// Version 1's list (never shown in Settings): files that still have it move to the new one.
    static let version1Widgets: [WidgetID] = ["clock", "weather", "events", "tasks"]
    /// Per-widget size, in `options[id]`; absent means compact.
    static let presentationKey = "presentation"
    static let defaultOptions: [WidgetID: [String: String]] = ["events": [presentationKey: WidgetPresentation.expanded.rawValue]]

    var version = currentVersion
    var dailyBriefingEnabled = false
    var widgets = defaultWidgets
    /// Per-widget settings as plain strings, so new keys never break older
    /// files: the size (`presentationKey`), later e.g. a weather city.
    var options = defaultOptions

    init() {}

    /// The size `id` takes in the briefing: compact unless set otherwise.
    func presentation(for id: WidgetID) -> WidgetPresentation {
        options[id]?[Self.presentationKey].flatMap(WidgetPresentation.init(rawValue:)) ?? .compact
    }

    mutating func setPresentation(_ presentation: WidgetPresentation, for id: WidgetID) {
        options[id, default: [:]][Self.presentationKey] = presentation.rawValue
    }

    func isShown(_ id: WidgetID) -> Bool { widgets.contains(id) }

    /// Shows or hides `id`. Hiding keeps its size; showing puts it back in its
    /// place in the approved order (other ids, known or not, stay where they are).
    mutating func setShown(_ id: WidgetID, _ shown: Bool) {
        guard shown != isShown(id) else { return }
        guard shown else { return widgets.removeAll { $0 == id } }
        let rank = Self.defaultWidgets.firstIndex(of: id) ?? Self.defaultWidgets.count
        let next = widgets.firstIndex { (Self.defaultWidgets.firstIndex(of: $0) ?? Int.max) > rank } ?? widgets.count
        widgets.insert(id, at: next)
    }

    /// Tolerant: a missing or invalid field takes its default, every valid
    /// field is kept and unknown keys (from newer versions) are ignored.
    /// Version 1 (or no version) with version 1's default list moves to the
    /// current defaults, keeping any other options; a customised list is kept.
    /// Nothing is written by decoding: the file changes only when a preference does.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = BriefingPreferences()
        let fileVersion = (try? container.decode(Int.self, forKey: .version)) ?? 1
        let storedWidgets = (try? container.decode([WidgetID].self, forKey: .widgets)).map(Self.cleaned)
        let storedOptions = try? container.decode([WidgetID: [String: String]].self, forKey: .options)
        dailyBriefingEnabled = (try? container.decode(Bool.self, forKey: .dailyBriefingEnabled)) ?? defaults.dailyBriefingEnabled
        widgets = storedWidgets ?? defaults.widgets
        options = storedOptions ?? defaults.options
        version = max(fileVersion, Self.currentVersion)
        guard fileVersion < Self.currentVersion, storedWidgets == nil || storedWidgets == Self.version1Widgets else { return }
        widgets = defaults.widgets
        for (id, values) in Self.defaultOptions {  // the new sizes, without overwriting a setting the file has
            for (key, value) in values where options[id]?[key] == nil { options[id, default: [:]][key] = value }
        }
    }

    /// No empty or repeated ids (unknown ids are kept: the registry decides what exists).
    static func cleaned(_ ids: [WidgetID]) -> [WidgetID] {
        var seen = Set<WidgetID>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}

/// briefing.json through `Persisted`: atomic writes, nothing written until
/// something changes, and an unreadable file left untouched until an
/// explicit reset (which moves it aside first).
@MainActor @Observable
final class BriefingPreferencesModel {
    private var stored: Persisted<BriefingPreferences>

    var value: BriefingPreferences { stored.value }
    var problem: String? { stored.problem }
    /// After each real change or reset (the app pushes it to the dashboard).
    @ObservationIgnored var onChange: ((BriefingPreferences) -> Void)?

    /// `nil` keeps them in memory only (tests).
    init(file: JSONFile<BriefingPreferences>?) {
        stored = file.map { Persisted($0, initial: BriefingPreferences()) } ?? Persisted(memory: BriefingPreferences())
    }

    static func file(in directory: URL) -> JSONFile<BriefingPreferences> {
        JSONFile(url: directory.appending(path: BriefingPreferences.fileName))
    }

    /// Saves only a real change: a no-op update writes nothing.
    func update(_ change: (inout BriefingPreferences) -> Void) {
        var changed = stored.value
        change(&changed)
        changed.widgets = BriefingPreferences.cleaned(changed.widgets)
        guard changed != stored.value else { return }
        stored.update { $0 = changed }
        onChange?(value)
    }

    /// The approved defaults again, briefing.json only (off, the two-row preset).
    func resetAll() {
        stored.replace(with: BriefingPreferences())
        onChange?(value)
    }
}
