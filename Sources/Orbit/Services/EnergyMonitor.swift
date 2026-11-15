import AppKit
import Darwin
import Observation

// "Apps Using Significant Energy" (Milestone 16), from public APIs only.
// - macOS keeps a per-process energy counter, `ri_energy_nj` in
//   `rusage_info_v6`, read with `proc_pid_rusage` (public libproc header; no
//   privileges). It's the kernel's own estimate from the CPU's performance
//   counters, in nanojoules: Orbit shows its rate as "≈ W" and calls it
//   macOS's estimate. It's NOT Activity Monitor's "Energy Impact" (a
//   different, unpublished model), and it covers CPU work only (no GPU, display
//   or radio share). Other users' and root processes (WindowServer,
//   kernel_task) can't be read without privileges: left out, never guessed.
// - Grouping: a helper inside an app's bundle counts for the outermost .app
//   (Brave's renderers count as Brave); a command-line tool counts for the
//   nearest app among its parents (a compiler run from VS Code's terminal
//   counts as VS Code). Activity Monitor uses private "coalitions" for this;
//   the parent chain is the public approximation.
// - If a Mac reports no energy at all, the ranking falls back to CPU time and
//   says so ("CPU estimate"): never relabelled as battery use.
// - Sampled only while something shows it (5 s apart), off the main thread.

struct ProcessSample: Equatable, Sendable {
    let pid: pid_t
    let ppid: pid_t
    let path: String?
    let energyNJ: UInt64
    /// User + system CPU, nanoseconds.
    let cpuNs: UInt64
    let wakeups: UInt64
}

protocol ProcessReading: Sendable {
    func samples() -> [ProcessSample]
}

/// The real reader: every process this user may read.
struct LibprocReader: ProcessReading {
    func samples() -> [ProcessSample] {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        let toNs = { (ticks: UInt64) -> UInt64 in ticks &* UInt64(timebase.numer) / UInt64(max(timebase.denom, 1)) }
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        var result: [ProcessSample] = []
        result.reserveCapacity(Int(got))
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        for pid in pids.prefix(Int(max(got, 0))) where pid > 0 {
            var info = rusage_info_v6()
            let ok = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            guard ok == 0 else { continue }  // another user's or root's process: not readable, not guessed
            var bsd = proc_bsdinfo()
            let bsdSize = Int32(MemoryLayout<proc_bsdinfo>.size)
            let ppid: pid_t = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &bsd, bsdSize) == bsdSize ? pid_t(bsd.pbi_ppid) : 0
            let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : nil
            result.append(ProcessSample(pid: pid, ppid: ppid, path: path, energyNJ: info.ri_energy_nj,
                                        cpuNs: toNs(info.ri_user_time &+ info.ri_system_time),
                                        wakeups: info.ri_interrupt_wkups &+ info.ri_pkg_idle_wkups))
        }
        return result
    }
}

struct AppEnergy: Identifiable, Equatable, Sendable {
    enum Level: String, Sendable { case high, moderate }
    /// The app bundle's path, or "process:<name>" for a tool with no app.
    let id: String
    let name: String
    let bundlePath: String?
    /// Average power over the last interval (macOS's estimate), watts. nil in CPU-estimate mode.
    let watts: Double?
    /// Share of one CPU core, percent (100 = one core busy).
    let cpuPercent: Double
    let wakeupsPerSecond: Double
    let processes: Int
    let level: Level
}

enum EnergyAttribution {
    /// Watts at or above which an app counts as "significant" / "high".
    static let significantWatts = 0.25
    static let highWatts = 1.0
    /// CPU-estimate mode: percent of one core.
    static let significantCPU = 10.0
    static let highCPU = 50.0

    /// The outermost `.app` in a path (a helper inside Brave Browser.app counts as Brave).
    static func appPath(_ path: String?) -> String? {
        guard let path else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = parts.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + parts[...index].joined(separator: "/")
    }

    /// Ranked apps from two samples `interval` seconds apart. `measured` is false when no process reported
    /// any energy (the counters aren't there): then the ranking is by CPU time, and says so.
    static func rank(previous: [ProcessSample], current: [ProcessSample], interval: TimeInterval,
                     limit: Int = 6) -> (apps: [AppEnergy], measured: Bool) {
        guard interval > 0 else { return ([], false) }
        let before = Dictionary(previous.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        let byPID = Dictionary(current.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
        func owner(_ sample: ProcessSample) -> String? {
            var cursor: ProcessSample? = sample
            for _ in 0 ..< 10 {
                guard let here = cursor else { return nil }
                if let app = appPath(here.path) { return app }
                guard here.ppid > 1 else { return nil }
                cursor = byPID[here.ppid]
            }
            return nil
        }
        struct Totals { var energy: UInt64 = 0; var cpu: UInt64 = 0; var wakeups: UInt64 = 0; var count = 0; var name = "" }
        var groups: [String: Totals] = [:]
        var anyEnergy = false
        for sample in current {
            guard let old = before[sample.pid], sample.energyNJ >= old.energyNJ, sample.cpuNs >= old.cpuNs else { continue }  // new or reused pid
            let energy = sample.energyNJ - old.energyNJ
            if energy > 0 { anyEnergy = true }
            let key: String
            let name: String
            if let app = owner(sample) {
                key = app
                name = ((app as NSString).lastPathComponent as NSString).deletingPathExtension
            } else {
                // A process with no app among its parents: system daemons (under /System, /usr) aren't apps; skip them.
                guard let path = sample.path, !path.hasPrefix("/System/"), !path.hasPrefix("/usr/"), !path.hasPrefix("/sbin/") else { continue }
                name = (path as NSString).lastPathComponent
                key = "process:" + name
            }
            var totals = groups[key, default: Totals()]
            totals.energy &+= energy
            totals.cpu &+= sample.cpuNs - old.cpuNs
            totals.wakeups &+= sample.wakeups &- min(old.wakeups, sample.wakeups)
            totals.count += 1
            totals.name = name
            groups[key] = totals
        }
        let apps = groups.compactMap { key, totals -> AppEnergy? in
            let watts = Double(totals.energy) / 1e9 / interval
            let cpu = Double(totals.cpu) / 1e9 / interval * 100
            let level: AppEnergy.Level
            if anyEnergy {
                guard watts >= significantWatts else { return nil }
                level = watts >= highWatts ? .high : .moderate
            } else {
                guard cpu >= significantCPU else { return nil }
                level = cpu >= highCPU ? .high : .moderate
            }
            return AppEnergy(id: key, name: totals.name, bundlePath: key.hasPrefix("process:") ? nil : key, watts: anyEnergy ? watts : nil,
                             cpuPercent: cpu, wakeupsPerSecond: Double(totals.wakeups) / interval, processes: totals.count, level: level)
        }
        let sorted = apps.sorted { anyEnergy ? ($0.watts ?? 0) > ($1.watts ?? 0) : $0.cpuPercent > $1.cpuPercent }
        return (Array(sorted.prefix(limit)), anyEnergy)
    }

    /// Bundle identifiers of browsers (energy is the browser's; which website isn't knowable).
    static let browsers: Set<String> = ["com.brave.Browser", "com.google.Chrome", "com.apple.Safari", "company.thebrowser.Browser",
                                        "com.microsoft.edgemac", "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi"]
}

@MainActor @Observable
final class EnergyMonitor {
    enum State: Equatable {
        case idle
        /// The first sample is taken; a rate needs two.
        case measuring
        case ready(apps: [AppEnergy], measured: Bool, at: Date)
        case unavailable(String)
    }

    static let shared = EnergyMonitor()
    static let interval: Duration = .seconds(5)

    private(set) var state = State.idle
    @ObservationIgnored private let reader: any ProcessReading
    @ObservationIgnored private let interval: Duration
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var clients: Set<String> = []
    /// How long the last sample took (performance audit).
    private(set) var lastSampleDuration: Duration = .zero

    init(reader: any ProcessReading = LibprocReader(), interval: Duration = EnergyMonitor.interval) {
        self.reader = reader
        self.interval = interval
    }

    var isRunning: Bool { task != nil }

    /// Sampling runs while at least one client (a visible widget or pane) wants it; the last result stays cached.
    func start(client: String) {
        clients.insert(client)
        guard task == nil else { return }
        if case .ready = state {} else { state = .measuring }
        let reader = reader, interval = interval
        task = Task { [weak self] in
            var previous = await Self.read(reader)
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                let current = await Self.read(reader)
                let seconds = current.at.timeIntervalSince(previous.at)
                let ranked = EnergyAttribution.rank(previous: previous.samples, current: current.samples, interval: seconds)
                guard let self else { return }
                self.lastSampleDuration = current.took
                if current.samples.isEmpty {
                    self.state = .unavailable("macOS didn't let Orbit read any process.")
                } else {
                    self.state = .ready(apps: ranked.apps, measured: ranked.measured, at: current.at)
                }
                previous = current
            }
        }
    }

    func stop(client: String) {
        clients.remove(client)
        guard clients.isEmpty else { return }
        task?.cancel()
        task = nil
    }

    private nonisolated static func read(_ reader: any ProcessReading) async -> (samples: [ProcessSample], at: Date, took: Duration) {
        await Task.detached(priority: .utility) {
            let clock = ContinuousClock()
            let start = clock.now
            let samples = reader.samples()
            return (samples, Date(), start.duration(to: clock.now))
        }.value
    }
}
