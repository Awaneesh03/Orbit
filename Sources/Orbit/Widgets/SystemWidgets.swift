import Network
import SwiftUI

/// CPU load and memory in use. Live (Mach statistics, no permission). Samples
/// every few seconds only while visible; a CPU percentage needs two samples.
@MainActor @Observable
final class SystemWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "system", title: "CPU & memory", description: "Processor load and memory in use",
        symbol: "cpu", category: .system, availability: .live,
        presentations: [.compact, .expanded], sectionPresentation: .expanded, isEnabledByDefault: false)
    private(set) var cpu: Double?
    private(set) var memory: MemoryUsage?
    private(set) var state = WidgetState.loading
    @ObservationIgnored private var lastTicks: CPUTicks?
    @ObservationIgnored private var task: Task<Void, Never>?
    private let interval: Duration
    private let readTicks: () -> CPUTicks?
    private let readMemory: () -> MemoryUsage?

    var isSampling: Bool { task != nil }

    init(interval: Duration = .seconds(3),
         readTicks: @escaping () -> CPUTicks? = SystemStats.cpuTicks,
         readMemory: @escaping () -> MemoryUsage? = SystemStats.memory) {
        self.interval = interval
        self.readTicks = readTicks
        self.readMemory = readMemory
    }

    func start() {
        guard task == nil else { return }
        sample()
        task = Task { [weak self, interval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard !Task.isCancelled else { return }
                self?.sample()
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        lastTicks = nil
    }

    func sample() {
        let ticks = readTicks()
        if let lastTicks, let ticks, let usage = SystemStats.cpuUsage(from: lastTicks, to: ticks) { cpu = usage }
        lastTicks = ticks
        memory = readMemory()
        state = ticks == nil && memory == nil ? .unavailable("System statistics unavailable") : .ready
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        let memoryText = memory.map {
            "\(Int64($0.used).formatted(.byteCount(style: .memory))) of \(Int64($0.total).formatted(.byteCount(style: .memory)))"
        } ?? "—"
        let meters = Group {
            Meter(label: "CPU", value: cpu.map { "\(Int(($0 * 100).rounded()))%" } ?? "Measuring…", fraction: cpu)
            Meter(label: "Memory", value: memoryText,
                  fraction: memory.map { Double($0.used) / Double(max($0.total, 1)) })
        }
        return presentation == .compact
            ? AnyView(VStack(alignment: .leading, spacing: 10) { meters })
            : AnyView(HStack(alignment: .top, spacing: 16) { meters })
    }
}

/// Free space on the startup disk. Live; read each time it appears.
@MainActor @Observable
final class StorageWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "storage", title: "Storage", description: "Free space on the startup disk",
        symbol: "internaldrive", category: .system, availability: .live, isEnabledByDefault: false)
    private(set) var usage: StorageUsage?
    private(set) var state = WidgetState.loading
    private let read: () -> StorageUsage?

    init(read: @escaping () -> StorageUsage? = { SystemStats.storage() }) {
        self.read = read
    }

    func start() {
        usage = read()
        state = usage == nil ? .unavailable("Disk information unavailable") : .ready
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        guard let usage else { return AnyView(EmptyView()) }
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            Text("\(usage.available.formatted(.byteCount(style: .file))) free")
                .font(OrbitType.metric)
            MeterBar(fraction: 1 - Double(usage.available) / Double(max(usage.total, 1)))
            Text("of \(usage.total.formatted(.byteCount(style: .file)))")
                .foregroundStyle(Theme.secondary)
        })
    }
}

struct NetworkSummary: Equatable, Sendable {
    enum Link: String, Sendable {
        case wifi = "Wi-Fi", ethernet = "Ethernet", cellular = "Cellular", other = "Connected"
    }

    var isOnline: Bool
    var link: Link?
    var isExpensive: Bool
    var isLowData: Bool

    var title: String { isOnline ? "Online" : "Offline" }

    var detail: String {
        guard isOnline else { return "No connection" }
        let notes = [isExpensive ? "metered" : nil, isLowData ? "Low Data Mode" : nil].compactMap { $0 }
        return ([link?.rawValue ?? "Connected"] + notes).joined(separator: " · ")
    }

    var symbol: String {
        guard isOnline else { return "wifi.slash" }
        return switch link {
        case .ethernet: "cable.connector"
        case .cellular: "antenna.radiowaves.left.and.right"
        default: "wifi"
        }
    }
}

extension NetworkSummary {
    init(path: NWPath) {
        let link: Link? =
            path.usesInterfaceType(.wifi) ? .wifi
            : path.usesInterfaceType(.wiredEthernet) ? .ethernet
            : path.usesInterfaceType(.cellular) ? .cellular
            : path.status == .satisfied ? .other : nil
        self.init(isOnline: path.status == .satisfied, link: link,
                  isExpensive: path.isExpensive, isLowData: path.isConstrained)
    }
}

/// Connection status. Live and push-driven: `NWPathMonitor` while visible,
/// no polling. The Wi-Fi network name is not shown (it needs Location access).
@MainActor @Observable
final class NetworkWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "network", title: "Network", description: "Connection status",
        symbol: "network", category: .system, availability: .live,
        presentations: [.compact, .expanded], sectionPresentation: .expanded, isEnabledByDefault: false)
    private(set) var summary: NetworkSummary?
    @ObservationIgnored private var monitor: NWPathMonitor?

    var state: WidgetState { summary == nil ? .loading : .ready }
    var isMonitoring: Bool { monitor != nil }

    func start() {
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let summary = NetworkSummary(path: path)
            MainActor.assumeIsolated { self?.summary = summary }  // delivered on the main queue
        }
        monitor.start(queue: .main)
        self.monitor = monitor
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        guard let summary else { return AnyView(EmptyView()) }
        return AnyView(HStack(spacing: 12) {
            Image(systemName: summary.symbol)
                .font(.system(size: 24))
                .foregroundStyle(summary.isOnline ? Theme.accent : .red)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.title).font(.system(size: 18, weight: .semibold, design: .rounded))
                Text(summary.detail).foregroundStyle(Theme.secondary)
            }
        })
    }
}

/// Label, value and a bar.
struct Meter: View {
    let label: String
    let value: String
    let fraction: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label).foregroundStyle(Theme.secondary)
                Spacer()
                Text(value).monospacedDigit()
            }
            MeterBar(fraction: fraction ?? 0)
        }
    }
}
