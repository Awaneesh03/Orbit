import Foundation
import Observation

// Shared plumbing for widgets whose data comes from somewhere (a framework, a
// file, the network): a data source, explicit errors, an optional cache and a
// refresher that follows the widget's visibility. No global polling: each
// widget refreshes when it appears and its data is stale, or when asked.

/// Why a fetch failed. Each is shown differently, and none hides data that
/// was already loaded.
enum DataSourceError: Error, Equatable, Sendable {
    /// A permission the user hasn't granted (and can grant).
    case needsAccess(String)
    /// The source doesn't exist here (not installed, no hardware).
    case unavailable(String)
    /// No network.
    case offline
    case failed(String)

    /// Maps any thrown error; nil for cancellation, which isn't a failure.
    static func from(_ error: any Error) -> DataSourceError? {
        if error is CancellationError { return nil }
        if let error = error as? DataSourceError { return error }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return nil
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost, .cannotConnectToHost,
                 .dataNotAllowed, .internationalRoamingOff:
                return .offline
            default: return .failed("Couldn't load the latest data.")
            }
        }
        return .failed("Couldn't load the latest data.")
    }
}

/// Where one widget's data comes from. Implementations must be `Sendable`,
/// do their work off the main actor and honour task cancellation.
protocol DataSource<Value>: Sendable {
    associatedtype Value: Sendable
    func fetch() async throws -> Value
}

// MARK: Cache

struct CachedValue<Value: Codable & Sendable>: Codable, Sendable {
    var value: Value
    var storedAt: Date

    func age(at now: Date) -> TimeInterval { now.timeIntervalSince(storedAt) }
}

/// The last value a widget loaded, in memory and optionally in a JSON file.
/// Only for data that's safe at rest (a forecast); never calendar events,
/// music or anything else personal: use `memoryOnly()` for those. A cache is
/// derived data, so an unreadable file is ignored and replaced on the next
/// store. Nothing is written until something is stored.
@MainActor
final class DataCache<Value: Codable & Sendable> {
    private let file: JSONFile<CachedValue<Value>>?
    private var memory: CachedValue<Value>?
    private var didReadFile = false

    init(file: JSONFile<CachedValue<Value>>?) {
        self.file = file
    }

    static func memoryOnly() -> DataCache { DataCache(file: nil) }

    /// The cached value, whatever its age (callers decide what's stale).
    var latest: CachedValue<Value>? {
        if !didReadFile {
            didReadFile = true
            if memory == nil { memory = try? file?.load() }  // unreadable: treated as no cache
        }
        return memory
    }

    /// The cached value only if it's younger than `maxAge`.
    func value(notOlderThan maxAge: TimeInterval, now: Date = .now) -> Value? {
        guard let latest, latest.age(at: now) < maxAge else { return nil }
        return latest.value
    }

    func store(_ value: Value, at now: Date = .now) {
        let entry = CachedValue(value: value, storedAt: now)
        memory = entry
        didReadFile = true
        try? file?.save(entry)  // atomic; a cache that can't be written is just a cache miss later
    }

    func clear() {
        memory = nil
        didReadFile = true
        if let url = file?.url { try? FileManager.default.removeItem(at: url) }
    }
}

// MARK: Refresher

/// Loads a widget's data from a `DataSource` and keeps it fresh while the
/// widget is visible:
/// - becoming visible refreshes only if the data is stale (older than
///   `maxAge`, or marked stale by an observer while hidden);
/// - one refresh at a time: asking again joins the running one;
/// - becoming hidden cancels a running refresh and stops the optional interval;
/// - a failed refresh keeps the previous data and reports it as a note.
@MainActor @Observable
final class Refresher<Value: Sendable> {
    struct Policy {
        /// Data older than this is refreshed when the widget appears.
        var maxAge: TimeInterval
        /// Also refresh this often while visible (only where genuinely needed).
        var interval: Duration?
        /// Cancel a running refresh when the widget is hidden.
        var cancelsWhenHidden = true
    }

    private(set) var value: Value?
    private(set) var updatedAt: Date?
    private(set) var error: DataSourceError?
    private(set) var isRefreshing = false
    private(set) var isVisible = false
    private(set) var isMarkedStale = false

    @ObservationIgnored let policy: Policy
    @ObservationIgnored private let fetch: @Sendable () async throws -> Value
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let store: ((Value, Date) -> Void)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var intervalTask: Task<Void, Never>?
    /// Bumped by every refresh and cancel, so a late result can't land.
    @ObservationIgnored private var generation = 0

    init<Source: DataSource>(source: Source, policy: Policy, clock: @escaping () -> Date = { .now })
    where Source.Value == Value {
        fetch = { try await source.fetch() }
        self.policy = policy
        self.clock = clock
        store = nil
    }

    /// Starts from the cached value (shown at once, marked stale if old) and
    /// stores every successful refresh in the cache.
    init<Source: DataSource>(source: Source, policy: Policy, cache: DataCache<Value>,
                             clock: @escaping () -> Date = { .now })
    where Source.Value == Value, Value: Codable {
        fetch = { try await source.fetch() }
        self.policy = policy
        self.clock = clock
        store = { cache.store($0, at: $1) }
        if let cached = cache.latest {
            value = cached.value
            updatedAt = cached.storedAt
        }
    }

    var isStale: Bool {
        guard let updatedAt else { return true }
        return isMarkedStale || clock().timeIntervalSince(updatedAt) >= policy.maxAge
    }

    var isIntervalRunning: Bool { intervalTask != nil }

    // MARK: Lifecycle (call from the widget's start/stop)

    func becameVisible() {
        guard !isVisible else { return }
        isVisible = true
        if isStale { refresh() }
        startInterval()
    }

    func becameHidden() {
        guard isVisible else { return }
        isVisible = false
        intervalTask?.cancel()
        intervalTask = nil
        if policy.cancelsWhenHidden { cancel() }
    }

    /// For lightweight observers (a change notification): refresh now if
    /// visible, otherwise on the next appearance.
    func markStale() {
        isMarkedStale = true
        if isVisible { refresh() }
    }

    // MARK: Refreshing

    /// Starts a refresh, or returns the one already running.
    @discardableResult
    func refresh() -> Task<Void, Never> {
        if let task { return task }
        generation += 1
        let current = generation
        isRefreshing = true
        let fetch = self.fetch
        let task = Task { [weak self] in
            let result: Result<Value, any Error>
            do { result = .success(try await fetch()) } catch { result = .failure(error) }
            self?.finish(result, generation: current)
        }
        self.task = task
        return task
    }

    /// Forgets everything loaded (for personal data that mustn't linger) and
    /// stops any refresh; the next appearance loads afresh.
    func reset() {
        cancel()
        value = nil
        updatedAt = nil
        error = nil
        isMarkedStale = false
    }

    /// Stops the running refresh; its result, if it still arrives, is dropped.
    func cancel() {
        task?.cancel()
        task = nil
        generation += 1
        isRefreshing = false
    }

    private func finish(_ result: Result<Value, any Error>, generation finished: Int) {
        guard finished == generation else { return }  // cancelled or superseded
        task = nil
        isRefreshing = false
        switch result {
        case .success(let fresh):
            let now = clock()
            value = fresh
            updatedAt = now
            error = nil
            isMarkedStale = false
            store?(fresh, now)
        case .failure(let failure):
            if let mapped = DataSourceError.from(failure) { error = mapped }  // previous value kept
        }
    }

    private func startInterval() {
        guard let interval = policy.interval, intervalTask == nil else { return }
        intervalTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.refresh()
            }
        }
    }

    // MARK: Presentation

    /// What the widget shows: its data whenever there is any (fresh or not);
    /// otherwise loading, or why there's nothing.
    func widgetState(empty: (Value) -> String? = { _ in nil }) -> WidgetState {
        if let value { return empty(value).map(WidgetState.empty) ?? .ready }
        switch error {
        case nil: return .loading
        case .needsAccess(let reason): return .needsAccess(reason)
        case .unavailable(let reason): return .unavailable(reason)
        case .offline: return .failed("You're offline.")
        case .failed(let message): return .failed(message)
        }
    }

    /// Under ready data: how old it is, and why it couldn't be refreshed.
    var statusNote: WidgetNote? {
        guard value != nil, let updatedAt else { return nil }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        let age = formatter.localizedString(for: updatedAt, relativeTo: clock())
        switch error {
        case .offline?: return WidgetNote(text: "Updated \(age) · Offline", symbol: "wifi.slash")
        case .some: return WidgetNote(text: "Updated \(age) · Couldn't refresh", symbol: "exclamationmark.arrow.circlepath")
        case nil: return isStale ? WidgetNote(text: "Updated \(age)") : nil
        }
    }

    /// Retry after a failure. Not for missing access (the widget offers its
    /// own way to grant it) or an unavailable source (nothing to retry).
    var retryAction: WidgetAction? {
        switch error {
        case .offline?, .failed?: WidgetAction(title: "Retry") { [weak self] in self?.refresh() }
        default: nil
        }
    }
}
