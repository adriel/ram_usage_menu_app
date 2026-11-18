import Foundation

struct DiskStatus {
    let free: UInt64
    let total: UInt64
    var usedFraction: Double { total == 0 ? 0 : 1 - Double(free) / Double(total) }
}

enum DiskSpace {
    /// Free space on the startup disk, the same figure Finder shows: it counts
    /// purgeable space (e.g. iCloud caches) that macOS frees automatically.
    static func read() -> DiskStatus? {
        let values = try? URL.homeDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
        ])
        guard let free = values?.volumeAvailableCapacityForImportantUsage,
              let total = values?.volumeTotalCapacity else { return nil }
        return DiskStatus(free: UInt64(max(0, free)), total: UInt64(max(0, total)))
    }

    static func isLow(_ disk: DiskStatus?, defaults d: UserDefaults = .standard) -> Bool {
        guard let disk, d.bool(forKey: Pref.diskWarningEnabled) else { return false }
        return disk.free < UInt64(d.integer(forKey: Pref.diskWarningGB)) * 1_073_741_824
    }
}
