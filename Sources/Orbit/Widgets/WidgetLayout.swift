import Foundation

/// The user's widget arrangement: order, on/off and presentation per widget.
/// Always normalised against the registry, so stale or hand-edited data can
/// never break the dashboard.
struct WidgetLayout: Codable, Equatable, Sendable {
    struct Item: Codable, Equatable, Sendable {
        var id: WidgetID
        var isEnabled: Bool
        var presentation: WidgetPresentation
    }

    var items: [Item]

    static func defaults(for metadata: [WidgetMetadata]) -> WidgetLayout {
        WidgetLayout(items: metadata.map {
            Item(id: $0.id, isEnabled: $0.isEnabledByDefault, presentation: .compact)
        })
    }

    /// Drops unknown and duplicate ids, resets unsupported presentations to
    /// compact, and appends registered widgets the layout doesn't mention yet.
    func normalized(for metadata: [WidgetMetadata]) -> WidgetLayout {
        let known = Dictionary(metadata.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<WidgetID>()
        var result: [Item] = []
        for var item in items {
            guard let meta = known[item.id], seen.insert(item.id).inserted else { continue }
            if !meta.presentations.contains(item.presentation) { item.presentation = .compact }
            result.append(item)
        }
        for meta in metadata where seen.insert(meta.id).inserted {
            result.append(Item(id: meta.id, isEnabled: meta.isEnabledByDefault, presentation: .compact))
        }
        return WidgetLayout(items: result)
    }

    mutating func setEnabled(_ id: WidgetID, _ isEnabled: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isEnabled = isEnabled
    }

    mutating func setPresentation(_ id: WidgetID, _ presentation: WidgetPresentation) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].presentation = presentation
    }

    /// Moves a widget to `index`, clamped to the valid range.
    mutating func move(_ id: WidgetID, to index: Int) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let item = items.remove(at: from)
        items.insert(item, at: min(max(index, 0), items.count))
    }
}

/// Persists the layout as JSON: a few dozen bytes need no database.
struct WidgetLayoutStore {
    private let read: () -> Data?
    private let write: (Data) -> Void

    init(read: @escaping () -> Data?, write: @escaping (Data) -> Void) {
        self.read = read
        self.write = write
    }

    /// The app's store: Orbit's preferences, key `widgetLayout`.
    init(defaults: UserDefaults, key: String = "widgetLayout") {
        self.init(read: { defaults.data(forKey: key) }, write: { defaults.set($0, forKey: key) })
    }

    /// nil when nothing is stored or the stored data can't be decoded.
    func load() -> WidgetLayout? {
        read().flatMap { try? JSONDecoder().decode(WidgetLayout.self, from: $0) }
    }

    func save(_ layout: WidgetLayout) {
        if let data = try? JSONEncoder().encode(layout) { write(data) }
    }
}

/// Packs widgets into rows of `columns` cells without reordering them: a
/// widget that doesn't fit the current row starts the next one.
enum WidgetGridPacking {
    static func rows(spans: [Int], columns: Int) -> [[Int]] {
        var rows: [[Int]] = []
        var current: [Int] = []
        var used = 0
        for (index, rawSpan) in spans.enumerated() {
            let span = min(max(rawSpan, 1), columns)
            if used + span > columns {
                rows.append(current)
                current = []
                used = 0
            }
            current.append(index)
            used += span
        }
        if !current.isEmpty { rows.append(current) }
        return rows
    }
}
