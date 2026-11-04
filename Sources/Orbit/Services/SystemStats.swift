import Darwin
import Foundation

struct CPUTicks: Equatable, Sendable {
    var busy: UInt64
    var total: UInt64
}

struct MemoryUsage: Equatable, Sendable {
    var used: UInt64
    var total: UInt64
}

struct StorageUsage: Equatable, Sendable {
    var available: Int64
    var total: Int64
}

/// Point-in-time readings from Mach and the file system. No permission needed.
enum SystemStats {
    static func cpuTicks() -> CPUTicks? {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        let ticks = info.cpu_ticks  // (user, system, idle, nice)
        let user = UInt64(ticks.0), system = UInt64(ticks.1), idle = UInt64(ticks.2), nice = UInt64(ticks.3)
        return CPUTicks(busy: user + system + nice, total: user + system + idle + nice)
    }

    /// Share of time the CPU was busy between two samples (0...1); nil if no time passed.
    static func cpuUsage(from old: CPUTicks, to new: CPUTicks) -> Double? {
        guard new.total > old.total, new.busy >= old.busy else { return nil }
        return Double(new.busy - old.busy) / Double(new.total - old.total)
    }

    static func memory() -> MemoryUsage? {
        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        return memoryUsage(
            internalPages: UInt64(stats.internal_page_count), purgeablePages: UInt64(stats.purgeable_count),
            wiredPages: UInt64(stats.wire_count), compressedPages: UInt64(stats.compressor_page_count),
            pageSize: UInt64(getpagesize()), total: ProcessInfo.processInfo.physicalMemory)
    }

    /// Activity Monitor's "Memory Used": app memory (internal − purgeable) + wired + compressed.
    static func memoryUsage(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                            compressedPages: UInt64, pageSize: UInt64, total: UInt64) -> MemoryUsage {
        let appPages = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return MemoryUsage(used: min((appPages + wiredPages + compressedPages) * pageSize, total), total: total)
    }

    static func storage(at url: URL = URL(filePath: "/")) -> StorageUsage? {
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]),
              let total = values.volumeTotalCapacity,
              let available = values.volumeAvailableCapacityForImportantUsage
        else { return nil }
        return StorageUsage(available: available, total: Int64(total))
    }
}
