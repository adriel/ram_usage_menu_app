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

// `RAMWatch --tabs` prints Safari's tabs with memory (tests the AppleScript bridge).
if CommandLine.arguments.contains("--tabs") {
    Task {
        let r = await SafariTabs.fetch()
        print("Status: \(r.status), asleep: \(r.unloadedCount)")
        for t in r.tabs {
            let title = String(t.title.prefix(44)).padding(toLength: 44, withPad: " ", startingAt: 0)
            print("  \(title) \(formatBytes(t.bytes))\tpid \(t.pid)\t\(t.host)\(t.sharedWith > 0 ? " (shared)" : "")")
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
