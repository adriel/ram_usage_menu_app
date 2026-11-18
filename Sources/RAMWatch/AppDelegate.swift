import AppKit
import SwiftUI
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = AppModel()
    private let sampler = MemorySampler()
    private var statusItem: NSStatusItem!
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
        let health = max(memoryHealth, diskLow ? .tight : .good)

        model.snapshot = snap
        model.memoryHealth = memoryHealth
        model.health = health
        model.diskLow = diskLow
        model.history.record(snap)

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
        let red = health == .swapping
        defer { warningActive = red }
        // Notify once when it turns red (and again at most every 30 minutes while it stays red).
        guard red, UserDefaults.standard.bool(forKey: Pref.warningEnabled) else { return }
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
        content.body = "Only \(formatBytes(disk.free)) free. Your Mac needs free space to use as extra memory, so it will get slow. Empty the Trash or delete large files you don't need."
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

        if health == .swapping {
            // Red: everything inside one solid red pill with white text, readable on any wallpaper.
            button.image = StatusIcon.pill(
                fill: health.badgeFill, symbol: "memorychip.fill",
                text: showText ? formatBytes(snap.swapUsed) : nil)
            button.title = ""
        } else {
            // Green / orange: coloured badge + % in the normal menu bar text colour.
            // A drive glyph when it's low disk space (not memory) making it orange.
            let diskOnly = model.diskLow && model.memoryHealth < .tight
            button.image = StatusIcon.badge(fill: health.badgeFill, symbol: diskOnly ? "internaldrive.fill" : "memorychip.fill")
            button.title = showText ? " \(Int((snap.usedFraction * 100).rounded()))%" : ""
            button.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        }

        var tip = "\(model.memoryHealth.title): \(formatBytes(snap.used)) of \(formatBytes(snap.total)) used, swap \(formatBytes(snap.swapUsed))"
        if model.diskLow, let disk = model.disk { tip += "\nLow disk space: \(formatBytes(disk.free)) free" }
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
            let window = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(updater: model.updater)))
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
