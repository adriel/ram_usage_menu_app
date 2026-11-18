import AppKit
import Observation
import SwiftUI

enum Health: Int, Comparable {
    case good      // green
    case tight     // orange
    case swapping  // red

    static func < (a: Health, b: Health) -> Bool { a.rawValue < b.rawValue }

    /// Accent colour used in the popover (dots, labels).
    var color: Color {
        switch self {
        case .good: .green
        case .tight: .orange
        case .swapping: .red
        }
    }

    /// Solid fill for the menu bar badge. Slightly deeper than the system colours
    /// so the white glyph/text on top stays readable over any wallpaper.
    var badgeFill: NSColor {
        switch self {
        case .good: NSColor(srgbRed: 0.12, green: 0.62, blue: 0.29, alpha: 1)
        case .tight: NSColor(srgbRed: 0.93, green: 0.47, blue: 0.02, alpha: 1)
        case .swapping: NSColor(srgbRed: 0.84, green: 0.11, blue: 0.11, alpha: 1)
        }
    }

    var title: String {
        switch self {
        case .good: "Memory is fine"
        case .tight: "Memory is getting full"
        case .swapping: "Out of memory: using swap"
        }
    }

    var advice: String {
        switch self {
        case .good: "There's plenty of room. Carry on."
        case .tight: "Think about closing tabs or apps you aren't using."
        case .swapping: "Your Mac is using the disk as extra memory, which slows everything down. Close some browser tabs or apps."
        }
    }
}

enum PopoverSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case apps = "Apps"
    case tabs = "Safari Tabs"
    var id: Self { self }
}

@Observable
final class AppModel {
    var snapshot: MemorySnapshot?
    var apps: [AppMemoryUsage] = []
    /// Colour from memory alone (popover header).
    var memoryHealth: Health = .good
    /// Colour shown in the menu bar: memory, bumped to orange by low disk space.
    var health: Health = .good
    var disk: DiskStatus?
    var diskLow = false
    let history = MemoryHistory()

    var tabs: [SafariTab] = []
    var unloadedTabs = 0
    var tabsStatus: TabsStatus = .idle

    var section: PopoverSection =
        PopoverSection(rawValue: UserDefaults.standard.string(forKey: Pref.popoverSection) ?? "") ?? .overview {
        didSet {
            UserDefaults.standard.set(section.rawValue, forKey: Pref.popoverSection)
            if section == .tabs { refreshTabs() }
        }
    }

    @ObservationIgnored private var tabsTask: Task<Void, Never>?
    @ObservationIgnored private var lastTabsFetch = Date.distantPast

    // Wired up by AppDelegate.
    @ObservationIgnored var openSettings: () -> Void = {}
    @ObservationIgnored var refreshApps: () -> Void = {}

    /// Re-reads Safari's tabs unless a read is already running (or ran very recently).
    func refreshTabs(force: Bool = false) {
        guard tabsTask == nil else { return }
        guard force || Date.now.timeIntervalSince(lastTabsFetch) > 2.5 else { return }
        if tabs.isEmpty { tabsStatus = .loading }
        tabsTask = Task {
            let result = await SafariTabs.fetch()
            tabs = result.tabs
            unloadedTabs = result.unloadedCount
            tabsStatus = result.status
            lastTabsFetch = .now
            tabsTask = nil
        }
    }

    func close(_ tab: SafariTab) {
        tabs.removeAll { $0.id == tab.id }   // feels instant; the refresh below corrects it
        Task {
            if let failure = await SafariTabs.close(tab) { tabsStatus = failure }
            try? await Task.sleep(for: .milliseconds(700))
            refreshTabs(force: true)
            refreshApps()
        }
    }
}

/// Decides the traffic-light colour from a snapshot and the user's settings.
func evaluateHealth(_ s: MemorySnapshot, defaults d: UserDefaults = .standard) -> Health {
    let swapLimit = UInt64(max(0, d.integer(forKey: Pref.swapWarningMB))) * 1_048_576
    let pressureHigh = s.pressure != .normal || s.isActivelySwapping

    var swapOverLimit = s.swapUsed > swapLimit
    if d.bool(forKey: Pref.requirePressure) { swapOverLimit = swapOverLimit && pressureHigh }

    if swapOverLimit || s.pressure == .critical { return .swapping }

    let orangePct = Double(d.integer(forKey: Pref.orangeUsedPercent)) / 100
    if s.usedFraction >= orangePct
        || s.pressure == .warning
        || (d.bool(forKey: Pref.orangeOnAnySwap) && s.swapUsed > 0) {
        return .tight
    }
    return .good
}
