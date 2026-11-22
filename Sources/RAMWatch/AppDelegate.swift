import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let sampler = MemorySampler()
    private var statusItem: NSStatusItem!
    private let swapDot = SwapDotView()
    private var lastSwapActivity = Date.distantPast
    /// Swapping comes in bursts, so keep the dot up between them.
    private let swapDotLinger: TimeInterval = 10
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?

    private var sampleTask: Task<Void, Never>?

    // Warning episode state
    private var warningActive = false
    private var lastNotifiedAt: Date?
    private let minNotifyGap: TimeInterval = 30 * 60
    private var lastDiskCheck = Date.distantPast
    private var lastDiskNotifiedAt: Date?
    private let diskNotifyGap: TimeInterval = 6 * 3600

    func applicationDidFinishLaunching(_ notification: Notification) {
        Pref.register()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.target = self
            button.action = #selector(togglePopover(_:))
            button.imagePosition = .imageLeading
            button.setAccessibilityLabel("RAM Watch")
            swapDot.frame = button.bounds
            swapDot.autoresizingMask = [.width, .height]
            button.addSubview(swapDot)
        }

        model.openSettings = { [weak self] in self?.openSettings() }
        model.refreshApps = { [weak self] in self?.model.apps = ProcessMemory.topApps(limit: 8) }

        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = .preferredContentSize
        popover.contentViewController = host
        popover.behavior = .transient

        startSampling()

        // React immediately to settings changes (and pick up a new refresh interval).
        Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UserDefaults.didChangeNotification) {
                self?.tick()
            }
        }

        // Daily update check (first one shortly after launch). Never restarts while the menu is open.
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(20))
            while let self, !Task.isCancelled {
                await self.model.updater.checkIfDue(canInstall: !self.popover.isShown)
                try? await Task.sleep(for: .seconds(3600))
            }
        }

        // Scheduled Spotify cache clean, checked hourly (and whenever Spotify quits; see SpotifyCacheCleaner).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            while let self, !Task.isCancelled {
                await self.model.spotifyCleaner.cleanIfDue()
                try? await Task.sleep(for: .seconds(3600))
            }
        }

        if UserDefaults.standard.bool(forKey: Pref.warningEnabled) || UserDefaults.standard.bool(forKey: Pref.diskWarningEnabled) {
            Task { _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.history.save()
    }

    // MARK: - Sampling

    private func startSampling() {
        sampleTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                let seconds = max(1, UserDefaults.standard.double(forKey: Pref.refreshSeconds))
                try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(seconds * 0.2))
            }
        }
    }

    private func tick() {
        guard let snap = sampler.sample() else { return }

        if Date.now.timeIntervalSince(lastDiskCheck) > 30 {
            lastDiskCheck = .now
            model.disk = DiskSpace.read()
        }
        let diskLow = DiskSpace.isLow(model.disk)
        let memoryHealth = evaluateHealth(snap)
        let health = memoryHealth   // low disk space gets its own badge

        model.snapshot = snap
        model.memoryHealth = memoryHealth
        model.health = health
        model.diskLow = diskLow
        model.history.record(snap)
        if snap.isActivelySwapping { lastSwapActivity = .now }

        if popover.isShown {
            switch model.section {
            case .overview, .apps: model.apps = ProcessMemory.topApps(limit: 8)
            case .tabs: model.refreshTabs()
            }
        }
        handleWarning(health: memoryHealth, snapshot: snap)
        handleDiskWarning(diskLow: diskLow)
        updateButton()
    }

    // MARK: - Warnings (notifications)

    private func handleWarning(health: Health, snapshot: MemorySnapshot) {
        let warn = shouldWarn(snapshot, health: health)
        defer { warningActive = warn }
        // Notify at most every 30 minutes while red or swapping over the red level.
        guard warn, UserDefaults.standard.bool(forKey: Pref.warningEnabled) else { return }
        if let last = lastNotifiedAt, Date.now.timeIntervalSince(last) < minNotifyGap { return }
        lastNotifiedAt = .now
        sendNotification(snapshot)
    }

    private func handleDiskWarning(diskLow: Bool) {
        guard diskLow, let disk = model.disk else { return }
        if let last = lastDiskNotifiedAt, Date.now.timeIntervalSince(last) < diskNotifyGap { return }
        lastDiskNotifiedAt = .now

        let content = UNMutableNotificationContent()
        content.title = "Low disk space"
        content.body = "Only \(formatDiskBytes(disk.free)) free. Your Mac needs free space to use as extra memory, so it will get slow. Empty the Trash or delete large files you don't need."
        content.sound = .default
        let request = UNNotificationRequest(identifier: "disk-warning", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    private func sendNotification(_ s: MemorySnapshot) {
        var body = "Your Mac is using \(formatBytes(s.swapUsed)) of swap, so things will feel slow."
        if let top = ProcessMemory.topApps(limit: 1).first {
            body += " \(top.name) is using the most memory (\(formatBytes(top.bytes)))."
        }
        body += " Close some tabs or apps to speed it up."

        let content = UNMutableNotificationContent()
        content.title = "Running out of memory"
        content.body = body
        content.sound = .default
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: "swap-warning", content: content, trigger: nil)
        Task { try? await UNUserNotificationCenter.current().add(request) }
    }

    // MARK: - Menu bar button

    private func updateButton() {
        guard let button = statusItem.button, let snap = model.snapshot else { return }
        let health = model.health
        let showText = UserDefaults.standard.bool(forKey: Pref.showText)
        let lowDisk = model.diskLow ? model.disk : nil
        let percent = "\(Int((snap.usedFraction * 100).rounded()))%"

        // Memory badge. Red: one solid red pill with the swap amount, readable on any wallpaper.
        let memory: NSImage
        if health == .swapping {
            memory = StatusIcon.pill(fill: health.badgeFill, symbol: "memorychip.fill",
                                     text: showText ? formatBytes(snap.swapUsed) : nil)
        } else if lowDisk != nil {
            // Next to the disk badge, the % goes inside the pill too so the two read as a pair.
            memory = StatusIcon.pill(fill: health.badgeFill, symbol: "memorychip.fill", text: showText ? percent : nil)
        } else {
            memory = StatusIcon.badge(fill: health.badgeFill)
        }

        if lowDisk != nil {
            // Low disk space: an orange drive badge, inside the same menu bar
            // item (a second item would land behind the menu bar's overflow on a crowded bar).
            // Icon only, to keep the item narrow; the free space is in the tooltip and the menu.
            let drive = StatusIcon.badge(fill: Health.tight.badgeFill, symbol: "internaldrive.fill")
            button.image = StatusIcon.joined([memory, drive], gap: 3)
            button.title = ""
        } else {
            button.image = memory
            // Green / orange: % in the normal menu bar text colour.
            button.title = health == .swapping || !showText ? "" : " \(percent)"
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        }

        let showDot = Date.now.timeIntervalSince(lastSwapActivity) < swapDotLinger
        let chipHasText = showText && (health == .swapping || lowDisk != nil)
        swapDot.update(visible: showDot, center: StatusIcon.swapDotCenter(hasText: chipHasText))

        var tip = "\(model.memoryHealth.title): \(formatBytes(snap.used)) of \(formatBytes(snap.total)) used, swap \(formatBytes(snap.swapUsed))"
        if let disk = lowDisk {
            tip += "\nLow disk space: \(formatDiskBytes(disk.free)) free (warns below \(UserDefaults.standard.integer(forKey: Pref.diskWarningGB)) GB)"
        }
        if showDot { tip += "\nRed dot: your Mac is reading or writing swap" }
        button.toolTip = tip
    }

    // MARK: - Popover & settings

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
        } else if let button = statusItem.button {
            model.apps = ProcessMemory.topApps(limit: 8)
            if model.section == .tabs { model.refreshTabs(force: true) }
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    private func openSettings() {
        popover.performClose(nil)
        if settingsWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(updater: model.updater, spotify: model.spotifyCleaner)))
            window.title = "RAM Watch Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }
}
