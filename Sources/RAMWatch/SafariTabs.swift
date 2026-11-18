import AppKit
import Foundation

struct SafariTab: Identifiable {
    let windowID: Int
    let index: Int
    let pid: pid_t
    let title: String
    let url: String
    var bytes: UInt64 = 0
    var sharedWith = 0     // other tabs backed by the same WebContent process
    var id: String { "\(windowID)-\(index)-\(pid)" }

    var host: String {
        URL(string: url)?.host()?.replacing(/^www\./, with: "") ?? url
    }
}

enum TabsStatus: Equatable {
    case idle, loading, notRunning, denied, loaded
    case failed(String)
}

/// Reads Safari's tabs over AppleScript. Each tab exposes a (hidden) `pid` for the
/// WebContent process that renders it, whose memory footprint we can measure directly.
/// Runs through /usr/bin/osascript so a busy or hung Safari can never freeze the menu.
enum SafariTabs {
    static let bundleID = "com.apple.Safari"

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    struct Result {
        var status: TabsStatus
        var tabs: [SafariTab] = []
        var unloadedCount = 0
    }

    static func fetch() async -> Result {
        guard isRunning else { return Result(status: .notRunning) }
        let r = await OSAScript.run(listScript, timeout: .seconds(60))
        if let failure = classify(r) { return Result(status: failure) }

        var tabs: [SafariTab] = []
        var unloaded = 0
        for record in r.output.split(separator: "\u{1E}") {
            let f = record.split(separator: "\u{1F}", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 5, let wid = Int(f[0]), let idx = Int(f[1]) else { continue }
            let pid = pid_t(f[2].trimmingCharacters(in: .whitespaces)) ?? 0
            if pid <= 0 { unloaded += 1; continue }
            tabs.append(SafariTab(windowID: wid, index: idx, pid: pid, title: f[3], url: f[4]))
        }

        // Attach per-process memory; several tabs of the same site can share a process.
        let counts = Dictionary(grouping: tabs, by: \.pid).mapValues(\.count)
        var footprints: [pid_t: UInt64] = [:]
        for i in tabs.indices {
            let pid = tabs[i].pid
            if footprints[pid] == nil { footprints[pid] = ProcessMemory.footprint(of: pid) ?? 0 }
            tabs[i].bytes = footprints[pid] ?? 0
            tabs[i].sharedWith = (counts[pid] ?? 1) - 1
        }
        tabs.sort { $0.bytes > $1.bytes }
        return Result(status: .loaded, tabs: tabs, unloadedCount: unloaded)
    }

    /// Closes a tab, after checking it's still the same tab (same position, process and URL).
    static func close(_ tab: SafariTab) async -> TabsStatus? {
        let r = await OSAScript.run(
            closeScript,
            arguments: [String(tab.windowID), String(tab.index), String(tab.pid), tab.url],
            timeout: .seconds(10))
        return classify(r)
    }

    static func openAutomationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") {
            NSWorkspace.shared.open(url)
        }
    }

    private static func classify(_ r: OSAScript.Output) -> TabsStatus? {
        guard r.status != 0 else { return nil }
        if r.error.contains("-1743") || r.error.contains("-1744") { return .denied }
        if r.error.contains("-600") || r.error.contains("-609") { return .notRunning }
        return .failed(r.error.isEmpty ? "Couldn't read Safari's tabs." : r.error)
    }

    private static let listScript = """
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

    private static let closeScript = """
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
