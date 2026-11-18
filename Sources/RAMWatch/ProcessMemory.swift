import AppKit
import Darwin

/// Memory used by one app, including all of its helper processes
/// (e.g. Safari + every "Safari Web Content" tab process).
struct AppMemoryUsage: Identifiable {
    let id: pid_t
    let name: String
    let icon: NSImage?
    let bytes: UInt64
    let processCount: Int
    let canQuit: Bool
}

enum ProcessMemory {
    private typealias ResponsibleFn = @convention(c) (pid_t) -> pid_t

    /// Private-but-stable libsystem call Activity Monitor uses to attribute helper
    /// processes (WebContent, renderers, XPC services) to the app that launched them.
    private static let responsibleFor: ResponsibleFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let sym = dlsym(rtldDefault, "responsibility_get_pid_responsible_for_pid") else { return nil }
        return unsafeBitCast(sym, to: ResponsibleFn.self)
    }()

    static func allPids() -> [pid_t] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimate) + 128)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard n > 0 else { return [] }
        return pids.prefix(Int(n)).filter { $0 > 0 }
    }

    /// Physical footprint — the "Memory" column in Activity Monitor.
    static func footprint(of pid: pid_t) -> UInt64? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, RUSAGE_INFO_V4, $0)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : nil
    }

    static func executablePath(of pid: pid_t) -> String? {
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = proc_pidpath(pid, &buf, UInt32(buf.count))
        return n > 0 ? String(decoding: buf.prefix(Int(n)), as: UTF8.self) : nil
    }

    /// Outermost .app bundle containing the executable, if any.
    static func appBundlePath(from path: String) -> String? {
        guard let r = path.range(of: ".app/") else { return nil }
        return String(path[..<r.lowerBound]) + ".app"
    }

    /// Top apps by memory, grouping helper processes under their owning app.
    /// Processes owned by other users (root/system) can't be read without admin rights and are skipped.
    static func topApps(limit: Int) -> [AppMemoryUsage] {
        let me = getpid()
        var groups: [pid_t: (bytes: UInt64, count: Int)] = [:]

        for pid in allPids() {
            guard let fp = footprint(of: pid), fp > 0 else { continue }
            var owner = responsibleFor?(pid) ?? pid
            if owner <= 1 { owner = pid }
            groups[owner, default: (0, 0)].bytes += fp
            groups[owner, default: (0, 0)].count += 1
        }

        return groups
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(limit)
            .map { owner, value in
                var name: String?
                var icon: NSImage?
                var canQuit = false

                if let running = NSRunningApplication(processIdentifier: owner) {
                    name = running.localizedName
                    icon = running.icon
                    canQuit = running.activationPolicy == .regular && owner != me
                }
                if name == nil || icon == nil, let path = executablePath(of: owner) {
                    if let bundle = appBundlePath(from: path) {
                        name = name ?? (bundle as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
                        icon = icon ?? NSWorkspace.shared.icon(forFile: bundle)
                    } else {
                        name = name ?? (path as NSString).lastPathComponent
                    }
                }

                return AppMemoryUsage(
                    id: owner,
                    name: name ?? "pid \(owner)",
                    icon: icon,
                    bytes: value.bytes,
                    processCount: value.count,
                    canQuit: canQuit
                )
            }
    }
}
