import AppKit
import CryptoKit
import Foundation
import Observation

/// Keeps RAM Watch up to date from the GitHub repo's releases.
///
/// Checks the latest release once a day. If its version is newer, downloads the attached
/// RAM-Watch.zip, checks it (GitHub's SHA-256 digest, same bundle id, expected version,
/// valid code signature), swaps it in place of the running app and relaunches.
@Observable
final class Updater {
    static let repo = "adriel/ram_usage_menu_app"
    static let assetName = "RAM-Watch.zip"
    static var releasesPage: URL { URL(string: "https://github.com/\(repo)/releases")! }

    struct Release: Equatable {
        let version: String
        let zipURL: URL
        let digest: String?
    }

    enum State: Equatable {
        case idle, checking, upToDate, installing
        case available(Release)
        case failed(String)
    }

    var state: State = .idle
    let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    var lastCheck: Date? {
        let t = UserDefaults.standard.double(forKey: Pref.lastUpdateCheck)
        return t > 0 ? Date(timeIntervalSince1970: t) : nil
    }

    /// Daily background check. Installs on its own if the user allows it and `canInstall` is true.
    func checkIfDue(canInstall: Bool) async {
        let d = UserDefaults.standard
        guard d.bool(forKey: Pref.autoCheckUpdates), state != .checking, state != .installing else { return }
        if let lastCheck, Date.now.timeIntervalSince(lastCheck) < 24 * 3600 {
            // Already checked today; still offer to install a pending update.
            if case .available(let r) = state, canInstall, d.bool(forKey: Pref.autoInstallUpdates) { await install(r) }
            return
        }
        await check(userInitiated: false)
        if case .available(let r) = state, canInstall, d.bool(forKey: Pref.autoInstallUpdates) { await install(r) }
    }

    func check(userInitiated: Bool) async {
        state = .checking
        do {
            let release = try await fetchLatest()
            UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Pref.lastUpdateCheck)
            state = Self.isNewer(release.version, than: currentVersion) ? .available(release) : .upToDate
        } catch {
            state = userInitiated ? .failed("Couldn't check for updates: \(error.localizedDescription)") : .idle
        }
    }

    func install(_ release: Release, relaunch shouldRelaunch: Bool = true) async {
        state = .installing
        do {
            try await downloadAndReplace(release)
            if shouldRelaunch { relaunch() } else { state = .upToDate }
        } catch {
            state = .failed("Update failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Steps

    private struct GitHubRelease: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
            let digest: String?
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("RAM-Watch-Updater", forHTTPHeaderField: "User-Agent")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("GitHub didn't return a release.") }
        let gh = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !gh.draft, !gh.prerelease, let asset = gh.assets.first(where: { $0.name == Self.assetName }) else {
            throw UpdateError("The latest release has no \(Self.assetName).")
        }
        return Release(version: Self.trimV(gh.tag_name), zipURL: asset.browser_download_url, digest: asset.digest)
    }

    private func downloadAndReplace(_ release: Release) async throws {
        let fm = FileManager.default
        let appURL = Bundle.main.bundleURL

        let (zip, response) = try await URLSession.shared.download(from: release.zipURL)
        defer { try? fm.removeItem(at: zip) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("Download failed.") }

        if let digest = release.digest, digest.hasPrefix("sha256:") {
            let hash = SHA256.hash(data: try Data(contentsOf: zip, options: .mappedIfSafe))
            let hex = hash.map { String(format: "%02x", $0) }.joined()
            guard "sha256:\(hex)" == digest else { throw UpdateError("The download didn't match GitHub's checksum.") }
        }

        // Unzip next to the app (same volume, so the swap is a single rename).
        let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: appURL, create: true)
        defer { try? fm.removeItem(at: work) }
        try await Tool.run("/usr/bin/ditto", ["-x", "-k", zip.path, work.path])

        guard let newApp = try fm.contentsOfDirectory(at: work, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: newApp),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier,
              Self.trimV(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "") == release.version
        else { throw UpdateError("The download isn't the expected version of RAM Watch.") }

        try await Tool.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", newApp.path])
        _ = try fm.replaceItemAt(appURL, withItemAt: newApp)
    }

    /// Opens the new copy once this one has quit.
    private func relaunch() {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(filePath: "/bin/sh")
        p.arguments = ["-c", "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\"",
                       Bundle.main.bundleURL.path]
        try? p.run()
        NSApp.terminate(nil)
    }

    // MARK: - Versions

    static func trimV(_ s: String) -> String {
        s.hasPrefix("v") ? String(s.dropFirst()) : s
    }

    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}

struct UpdateError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Runs a command-line tool off the main thread; throws if it fails.
nonisolated enum Tool {
    @concurrent
    static func run(_ path: String, _ arguments: [String]) async throws {
        let p = Process()
        p.executableURL = URL(filePath: path)
        p.arguments = arguments
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let message = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError("\((path as NSString).lastPathComponent) failed: \(message)")
        }
    }
}
