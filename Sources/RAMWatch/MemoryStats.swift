import Foundation
import Darwin

/// macOS memory pressure as reported by the kernel (same signal Activity Monitor's graph uses).
enum PressureLevel: Int {
    case normal = 1
    case warning = 2
    case critical = 4

    var label: String {
        switch self {
        case .normal: return "Normal"
        case .warning: return "Warning"
        case .critical: return "Critical"
        }
    }
}

/// One reading of system memory, broken down the same way Activity Monitor does.
struct MemorySnapshot {
    let total: UInt64
    let app: UInt64          // anonymous memory owned by apps (minus purgeable)
    let wired: UInt64        // kernel / locked memory that can never be compressed or swapped
    let compressed: UInt64   // physical RAM holding compressed pages
    let cached: UInt64       // file-backed + purgeable pages, reclaimable on demand
    let swapUsed: UInt64
    let swapTotal: UInt64
    let pressure: PressureLevel
    let swapOutRate: Double  // bytes per second written to swap since last sample
    let swapInRate: Double   // bytes per second read back from swap since last sample

    /// "Memory Used" in Activity Monitor terms.
    var used: UInt64 { app + wired + compressed }
    var free: UInt64 { total > used + cached ? total - used - cached : 0 }
    var usedFraction: Double { total == 0 ? 0 : min(1, Double(used) / Double(total)) }
    var isActivelySwapping: Bool { swapOutRate + swapInRate > 1_048_576 } // > 1 MB/s
}

final class MemorySampler {
    private let host = mach_host_self()
    private let pageSize: UInt64
    private let totalRAM = ProcessInfo.processInfo.physicalMemory
    private var last: (swapOuts: UInt64, swapIns: UInt64, time: TimeInterval)?

    init() {
        var size: vm_size_t = 0
        host_page_size(host, &size)
        pageSize = UInt64(size == 0 ? 4096 : size)
    }

    func sample() -> MemorySnapshot? {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(host, HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }

        let p = pageSize
        let anonPages = UInt64(stats.internal_page_count)
        let purgeable = UInt64(stats.purgeable_count)
        let app = (anonPages > purgeable ? anonPages - purgeable : 0) * p
        let wired = UInt64(stats.wire_count) * p
        let compressed = UInt64(stats.compressor_page_count) * p
        let cached = (UInt64(stats.external_page_count) + purgeable) * p

        // Swap usage
        var swap = xsw_usage()
        var swapSize = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &swapSize, nil, 0) != 0 {
            swap = xsw_usage()
        }

        // Memory pressure level
        var level: Int32 = 1
        var levelSize = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &levelSize, nil, 0)

        // Swap activity rate (pages moved to/from swap since the previous sample)
        let now = ProcessInfo.processInfo.systemUptime
        var outRate = 0.0, inRate = 0.0
        if let last, now > last.time {
            let dt = now - last.time
            outRate = Double(stats.swapouts &- last.swapOuts) * Double(p) / dt
            inRate = Double(stats.swapins &- last.swapIns) * Double(p) / dt
        }
        last = (stats.swapouts, stats.swapins, now)

        return MemorySnapshot(
            total: totalRAM,
            app: app,
            wired: wired,
            compressed: compressed,
            cached: cached,
            swapUsed: swap.xsu_used,
            swapTotal: swap.xsu_total,
            pressure: PressureLevel(rawValue: Int(level)) ?? .normal,
            swapOutRate: outRate,
            swapInRate: inRate
        )
    }
}

func formatBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1_073_741_824
    if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
    let mb = Double(bytes) / 1_048_576
    return String(format: "%.0f MB", mb)
}

/// Disk sizes in decimal GB, the way Finder and System Settings show them
/// (memory uses binary GB, like Activity Monitor).
func formatDiskBytes(_ bytes: UInt64) -> String {
    let gb = Double(bytes) / 1e9
    if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
    return String(format: "%.0f MB", Double(bytes) / 1e6)
}

func formatRate(_ bytesPerSec: Double) -> String {
    formatBytes(UInt64(max(0, bytesPerSec))) + "/s"
}
