import AppKit

Pref.register()

// `RAMWatch --dump` prints one reading to the terminal (handy for checking numbers
// against Activity Monitor without opening the menu).
if CommandLine.arguments.contains("--dump") {
    let sampler = MemorySampler()
    _ = sampler.sample()
    Thread.sleep(forTimeInterval: 1)
    guard let s = sampler.sample() else { fatalError("Could not read memory stats") }
    print("""
    Total        \(formatBytes(s.total))
    Used         \(formatBytes(s.used))  (\(Int(s.usedFraction * 100))%)
      App        \(formatBytes(s.app))
      Wired      \(formatBytes(s.wired))
      Compressed \(formatBytes(s.compressed))
    Cached files \(formatBytes(s.cached))
    Free         \(formatBytes(s.free))
    Swap         \(formatBytes(s.swapUsed)) of \(formatBytes(s.swapTotal))
    Swap rate    out \(formatRate(s.swapOutRate)), in \(formatRate(s.swapInRate))
    Pressure     \(s.pressure.label)
    Health       \(evaluateHealth(s).title)

    Top apps:
    """)
    for app in ProcessMemory.topApps(limit: 10) {
        let name = app.name.padding(toLength: 32, withPad: " ", startingAt: 0)
        print("  \(name) \(formatBytes(app.bytes))\t(\(app.processCount) proc)")
    }
    exit(0)
}

// `RAMWatch --tabs [safari|chrome|brave|edge]` prints a browser's tabs (tests the AppleScript bridge).
if let i = CommandLine.arguments.firstIndex(of: "--tabs") {
    let name = CommandLine.arguments.dropFirst(i + 1).first ?? "safari"
    guard let browser = Browser(rawValue: name) else { fatalError("Unknown browser \(name)") }
    Task {
        let r = await BrowserTabs.fetch(browser)
        print("Status: \(r.status), asleep: \(r.unloadedCount), total: \(r.totalBytes.map(formatBytes) ?? "-")")
        for t in r.tabs {
            let title = String(t.title.prefix(44)).padding(toLength: 44, withPad: " ", startingAt: 0)
            print("  \(title) \(t.bytes.map(formatBytes) ?? "")\tid \(t.tabID)\(t.pid)\t\(t.host)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

// `RAMWatch --close-tab chrome <windowID> <tabID> <url>` closes one Chromium tab (testing).
if let i = CommandLine.arguments.firstIndex(of: "--close-tab") {
    let a = Array(CommandLine.arguments.dropFirst(i + 1))
    guard a.count == 4, let browser = Browser(rawValue: a[0]) else { fatalError("usage: --close-tab <browser> <window> <tab> <url>") }
    Task {
        let tab = BrowserTab(browser: browser, windowID: a[1], index: 0, tabID: a[2], pid: 0, title: "", url: a[3])
        print(await BrowserTabs.close(tab).map { "\($0)" } ?? "ok")
        exit(0)
    }
    RunLoop.main.run()
}

// `RAMWatch --spotify-cache [clear]` lists the Spotify cache folders and their size; `clear` empties them.
if let i = CommandLine.arguments.firstIndex(of: "--spotify-cache") {
    let target = CacheTarget.spotify
    Task {
        for folder in target.folders() { print("  \(folder.path)") }
        print("Size: \(formatDiskBytes(await target.size()))\(target.isRunning ? "  (Spotify is open)" : "")")
        if CommandLine.arguments.dropFirst(i + 1).first == "clear" {
            if target.isRunning { print("Quit Spotify first.") }
            else { print("Freed \(formatDiskBytes(await target.clear()))") }
        }
        exit(0)
    }
    RunLoop.main.run()
}

// `RAMWatch --update` checks GitHub and, if there's a newer release, installs it over this copy.
if CommandLine.arguments.contains("--update") {
    Task {
        let updater = Updater()
        await updater.check(userInitiated: true)
        print("Installed \(updater.currentVersion): \(updater.state)")
        if case .available(let r) = updater.state {
            await updater.install(r, relaunch: false)
            print("After install: \(updater.state)")
        }
        exit(0)
    }
    RunLoop.main.run()
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
