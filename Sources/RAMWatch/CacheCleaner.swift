import AppKit
import Foundation
import Observation

/// Cache folders that are safe to empty: the app rebuilds them on its own.
/// They're only touched while the app is closed, so it never sees files vanish under it.
nonisolated struct CacheTarget: Sendable {
    let name: String
    let bundleID: String
    /// Folders whose contents get deleted (the folders themselves stay).
    let folders: @Sendable () -> [URL]

    /// Spotify keeps streamed songs in its "Storage" folder (the same one its own
    /// Settings → Storage → Clear cache empties), plus a large web-player cache for its UI.
    /// Not touched: settings, login, and the PersistentCache/Users database.
    static let spotify = CacheTarget(name: "Spotify", bundleID: "com.spotify.client") {
        let home = URL.homeDirectory
        let caches = home.appending(path: "Library/Caches/com.spotify.client")
        let support = home.appending(path: "Library/Application Support/Spotify")
        var folders = [
            caches.appending(path: "Data"),                     // song cache, newer versions
            caches.appending(path: "Storage"),
            support.appending(path: "PersistentCache/Storage"), // song cache, older versions
            caches.appending(path: "Browser/Cache"),            // web-player HTTP cache
            caches.appending(path: "Browser/Code Cache"),
            caches.appending(path: "Browser/GPUCache"),
        ]
        // If the cache was moved (Settings → Storage → Change location), follow it.
        if let prefs = try? String(contentsOf: support.appending(path: "prefs"), encoding: .utf8),
           let line = prefs.split(separator: "\n").first(where: { $0.hasPrefix("storage.last-location=") }) {
            let path = line.dropFirst("storage.last-location=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let url = URL(filePath: path, directoryHint: .isDirectory)
            // Only a folder called Storage, so a bad prefs value can't point us at something else.
            if url.lastPathComponent == "Storage" { folders.append(url) }
        }
        var seen = Set<String>()
        return folders.filter {
            seen.insert($0.standardizedFileURL.path(percentEncoded: false)).inserted
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }

    var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// Bytes on disk used by all the folders.
    @concurrent
    func size() async -> UInt64 {
        folders().reduce(0) { $0 + Self.allocatedSize(of: $1) }
    }

    /// Deletes everything inside the folders. Returns the bytes freed.
    @concurrent
    func clear() async -> UInt64 {
        let fm = FileManager.default
        var freed: UInt64 = 0
        for folder in folders() {
            let items = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            for item in items {
                let bytes = Self.allocatedSize(of: item)
                if (try? fm.removeItem(at: item)) != nil { freed += bytes }
            }
        }
        return freed
    }

    private static func allocatedSize(of url: URL) -> UInt64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isDirectoryKey]
        guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return 0 }
        if values.isDirectory != true { return UInt64(values.totalFileAllocatedSize ?? 0) }
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total: UInt64 = 0
        for case let file as URL in walker {
            total += UInt64((try? file.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Empties Spotify's cache on a schedule. If Spotify is open when it's due,
/// it waits and cleans right after Spotify quits.
@Observable
final class SpotifyCacheCleaner {
    enum State: Equatable {
        case idle
        case measuring
        case cleaning
        case cleaned(freed: UInt64)
        case waitingForQuit
    }

    private(set) var state: State = .idle
    private(set) var size: UInt64?
    @ObservationIgnored let target = CacheTarget.spotify

    var lastCleaned: Date? {
        let t = UserDefaults.standard.double(forKey: Pref.spotifyLastCleaned)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    var isDue: Bool {
        let d = UserDefaults.standard
        guard d.bool(forKey: Pref.spotifyCleanEnabled) else { return false }
        let every = TimeInterval(max(1, d.integer(forKey: Pref.spotifyCleanDays))) * 86400
        return Date.now.timeIntervalSince(lastCleaned ?? .distantPast) >= every
    }

    init() {
        // Clean as soon as Spotify quits, if a clean is due.
        Task { [weak self] in
            let center = NSWorkspace.shared.notificationCenter
            for await note in center.notifications(named: NSWorkspace.didTerminateApplicationNotification) {
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                guard let self, app?.bundleIdentifier == self.target.bundleID else { continue }
                try? await Task.sleep(for: .seconds(3))   // let it finish writing
                if self.state == .waitingForQuit || self.isDue { await self.clean() }
            }
        }
    }

    func refreshSize() async {
        guard state != .cleaning else { return }
        if size == nil { state = .measuring }
        size = await target.size()
        if state == .measuring { state = .idle }
    }

    func cleanIfDue() async {
        guard isDue else { return }
        await clean()
    }

    /// Cleans now, unless Spotify is open (then it waits for Spotify to quit when scheduled).
    func clean() async {
        guard state != .cleaning else { return }
        if target.isRunning {
            state = .waitingForQuit
            return
        }
        state = .cleaning
        let freed = await target.clear()
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Pref.spotifyLastCleaned)
        size = await target.size()
        state = .cleaned(freed: freed)
    }
}
