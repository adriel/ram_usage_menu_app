import AppKit
import Foundation

/// Browsers whose tabs RAM Watch can list and close over AppleScript.
enum Browser: String, CaseIterable, Identifiable {
    case safari, chrome, brave, edge
    var id: Self { self }

    var bundleID: String {
        switch self {
        case .safari: "com.apple.Safari"
        case .chrome: "com.google.Chrome"
        case .brave: "com.brave.Browser"
        case .edge: "com.microsoft.edgemac"
        }
    }

    var name: String {
        switch self {
        case .safari: "Safari"
        case .chrome: "Chrome"
        case .brave: "Brave"
        case .edge: "Edge"
        }
    }

    /// Chrome, Brave and Edge share Chromium's scripting dictionary.
    var isChromium: Bool { self != .safari }

    var runningApp: NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    static var running: [Browser] { allCases.filter { $0.runningApp != nil } }
}

struct BrowserTab: Identifiable {
    let browser: Browser
    let windowID: String
    let index: Int
    let tabID: String      // Chromium's stable tab id ("" for Safari)
    let pid: pid_t         // Safari's WebContent process (0 for Chromium)
    let title: String
    let url: String
    /// Memory of the process drawing this tab. nil when the browser doesn't reveal it (Chromium).
    var bytes: UInt64?
    var sharedWith = 0     // other tabs backed by the same process
    var id: String { "\(browser.rawValue)-\(windowID)-\(index)-\(tabID)-\(pid)" }

    var host: String {
        URL(string: url)?.host()?.replacing(/^www\./, with: "") ?? url
    }
}

enum TabsStatus: Equatable {
    case idle, loading, notRunning, denied, loaded
    case failed(String)
}

/// Reads and closes browser tabs over AppleScript, through /usr/bin/osascript so a
/// busy or hung browser can never freeze the menu.
///
/// Safari exposes a hidden `pid` on each tab: the WebContent process that renders it,
/// whose memory we can measure directly. Chromium browsers don't say which renderer
/// process belongs to which tab, so for them we list tabs plus the total of all their
/// tab processes.
enum BrowserTabs {
    struct Result {
        var status: TabsStatus
        var tabs: [BrowserTab] = []
        var unloadedCount = 0
        /// Chromium: memory of all tab (renderer) processes together.
        var totalBytes: UInt64?
    }

    static func fetch(_ browser: Browser) async -> Result {
        guard let app = browser.runningApp else { return Result(status: .notRunning) }
        let r = await OSAScript.run(browser.isChromium ? chromiumListScript(browser) : safariListScript, timeout: .seconds(60))
        if let failure = classify(r) { return Result(status: failure) }

        var tabs: [BrowserTab] = []
        var unloaded = 0
        for record in r.output.split(separator: "\u{1E}") {
            let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let idx = Int(f[1]) else { continue }
            if browser.isChromium {
                tabs.append(BrowserTab(browser: browser, windowID: f[0], index: idx, tabID: f[2], pid: 0, title: f[3], url: f[4]))
            } else {
                let pid = pid_t(f[2].trimmingCharacters(in: .whitespaces)) ?? 0
                if pid <= 0 { unloaded += 1; continue }
                tabs.append(BrowserTab(browser: browser, windowID: f[0], index: idx, tabID: "", pid: pid, title: f[3], url: f[4]))
            }
        }

        if browser.isChromium {
            return Result(status: .loaded, tabs: tabs, totalBytes: chromiumTabProcessBytes(parent: app.processIdentifier))
        }

        // Safari: attach per-process memory; several tabs of the same site can share a process.
        let counts = Dictionary(grouping: tabs, by: \.pid).mapValues(\.count)
        var footprints: [pid_t: UInt64] = [:]
        for i in tabs.indices {
            let pid = tabs[i].pid
            if footprints[pid] == nil { footprints[pid] = ProcessMemory.footprint(of: pid) ?? 0 }
            tabs[i].bytes = footprints[pid] ?? 0
            tabs[i].sharedWith = (counts[pid] ?? 1) - 1
        }
        tabs.sort { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
        return Result(status: .loaded, tabs: tabs, unloadedCount: unloaded)
    }

    /// Closes a tab, after checking it's still the same tab (so a reordered window can't
    /// make us close the wrong one).
    static func close(_ tab: BrowserTab) async -> TabsStatus? {
        let r = if tab.browser.isChromium {
            await OSAScript.run(chromiumCloseScript(tab.browser), arguments: [tab.windowID, tab.tabID, tab.url], timeout: .seconds(10))
        } else {
            await OSAScript.run(safariCloseScript, arguments: [tab.windowID, String(tab.index), String(tab.pid), tab.url], timeout: .seconds(10))
        }
        return classify(r)
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    /// Sum of a Chromium browser's renderer processes that draw web pages
    /// (not its own UI or extensions).
    private static func chromiumTabProcessBytes(parent: pid_t) -> UInt64 {
        var total: UInt64 = 0
        for pid in ProcessMemory.allPids() where ProcessMemory.parent(of: pid) == parent {
            guard let args = ProcessMemory.arguments(of: pid), args.contains("--type=renderer"),
                  !args.contains("--extension-process"), !args.contains("--top-chrome-webui") else { continue }
            total += ProcessMemory.footprint(of: pid) ?? 0
        }
        return total
    }

    private static func classify(_ r: OSAScript.Output) -> TabsStatus? {
        guard r.status != 0 else { return nil }
        if r.error.contains("-1743") || r.error.contains("-1744") { return .denied }
        if r.error.contains("-600") || r.error.contains("-609") { return .notRunning }
        return .failed(r.error.isEmpty ? "Couldn't read the browser's tabs." : r.error)
    }

    // MARK: Scripts

    private static let safariListScript = """
    set RS to character id 30
    set FS to character id 31
    set out to ""
    tell application id "com.apple.Safari"
        repeat with w in windows
            try
                set wid to id of w
                tell w to set {ns, us} to {name of every tab, URL of every tab}
                set ps to {}
                try
                    tell w to set ps to pid of every tab
                end try
                repeat with i from 1 to count of ns
                    set p to 0
                    if (count of ps) ≥ i then set p to item i of ps
                    set n to item i of ns
                    set u to item i of us
                    if n is missing value then set n to ""
                    if u is missing value then set u to ""
                    if p is missing value then set p to 0
                    set out to out & wid & FS & i & FS & p & FS & n & FS & u & RS
                end repeat
            end try
        end repeat
    end tell
    return out
    """

    private static let safariCloseScript = """
    on run argv
        set wid to (item 1 of argv) as integer
        set idx to (item 2 of argv) as integer
        set wantPid to (item 3 of argv) as integer
        set wantURL to item 4 of argv
        tell application id "com.apple.Safari"
            set t to tab idx of window id wid
            set p to 0
            try
                set p to pid of t
            end try
            set u to URL of t
            if u is missing value then set u to ""
            if p is wantPid and u is wantURL then
                close t
                return "closed"
            end if
            return "moved"
        end tell
    end run
    """

    // The bundle id is spliced in as a literal so osascript can load that browser's terms.
    private static func chromiumListScript(_ b: Browser) -> String { """
    set RS to character id 30
    set FS to character id 31
    set out to ""
    tell application id "\(b.bundleID)"
        repeat with w in windows
            try
                set wid to id of w
                tell w to set {ids, ns, us} to {id of every tab, title of every tab, URL of every tab}
                repeat with i from 1 to count of ids
                    set n to item i of ns
                    set u to item i of us
                    if n is missing value then set n to ""
                    if u is missing value then set u to ""
                    set out to out & wid & FS & i & FS & (item i of ids) & FS & n & FS & u & RS
                end repeat
            end try
        end repeat
    end tell
    return out
    """ }

    private static func chromiumCloseScript(_ b: Browser) -> String { """
    on run argv
        set wid to item 1 of argv
        set tid to item 2 of argv
        set wantURL to item 3 of argv
        tell application id "\(b.bundleID)"
            repeat with w in windows
                if (id of w as text) is wid then
                    repeat with t in tabs of w
                        if (id of t as text) is tid then
                            if (URL of t) is wantURL then
                                close t
                                return "closed"
                            end if
                            return "changed"
                        end if
                    end repeat
                end if
            end repeat
        end tell
        return "gone"
    end run
    """ }
}

/// Runs an AppleScript in a child osascript process with a timeout.
nonisolated enum OSAScript {
    struct Output: Sendable {
        let status: Int32
        let output: String
        let error: String
    }

    private final class Box: @unchecked Sendable {
        let process = Process()
    }

    @concurrent
    static func run(_ source: String, arguments: [String] = [], timeout: Duration) async -> Output {
        let box = Box()
        let p = box.process
        p.executableURL = URL(filePath: "/usr/bin/osascript")
        p.arguments = ["-e", source] + arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch {
            return Output(status: -1, output: "", error: error.localizedDescription)
        }

        let watchdog = Task.detached {
            try? await Task.sleep(for: timeout)
            if box.process.isRunning { box.process.terminate() }
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        watchdog.cancel()

        var text = String(decoding: outData, as: UTF8.self)
        if text.hasSuffix("\n") { text.removeLast() }
        return Output(
            status: p.terminationStatus,
            output: text,
            error: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
