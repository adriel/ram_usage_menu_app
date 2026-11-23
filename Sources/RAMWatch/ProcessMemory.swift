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

    static func parent(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        return proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size ? pid_t(info.pbi_ppid) : nil
    }

    /// Command-line arguments of one of our own user's processes.
    static func arguments(of pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }

        // Layout: argc, executable path, NUL padding, then argc NUL-terminated strings.
        let argc = buf.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        var i = MemoryLayout<Int32>.size
        while i < size, buf[i] != 0 { i += 1 }   // skip executable path
        while i < size, buf[i] == 0 { i += 1 }   // skip padding
        var args: [String] = []
        while args.count < argc, i < size {
            let start = i
            while i < size, buf[i] != 0 { i += 1 }
            args.append(String(decoding: buf[start..<i], as: UTF8.self))
            i += 1
        }
        return args
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
        var resolved: [pid_t: pid_t] = [:]

        for pid in allPids() {
            guard let fp = footprint(of: pid), fp > 0 else { continue }
            let owner = owningApp(of: responsible(for: pid), cache: &resolved)
            groups[owner, default: (0, 0)].bytes += fp
            groups[owner, default: (0, 0)].count += 1
        }

        return groups
            .sorted { $0.value.bytes > $1.value.bytes }
            .prefix(limit)
            .map { owner, value in
                let info = identity(of: owner, me: me)
                return AppMemoryUsage(
                    id: owner,
                    name: info.name,
                    icon: info.icon,
                    bytes: value.bytes,
                    processCount: value.count,
                    canQuit: info.canQuit
                )
            }
    }

    private static func responsible(for pid: pid_t) -> pid_t {
        let owner = responsibleFor?(pid) ?? pid
        return owner <= 1 ? pid : owner
    }

    /// Some apps start helpers that give up being counted as theirs ("disclaim" responsibility),
    /// e.g. Claude starts each Claude Code session that way, so each would be listed on its own.
    /// A group whose owner was started by another process (not launchd) and isn't an app
    /// in its own right is folded into whatever owns that parent.
    private static func owningApp(of owner: pid_t, cache: inout [pid_t: pid_t]) -> pid_t {
        if let known = cache[owner] { return known }
        var current = owner
        for _ in 0..<8 {
            guard let parent = parent(of: current), parent > 1,
                  NSRunningApplication(processIdentifier: current)?.activationPolicy != .regular
            else { break }
            let next = responsible(for: parent)
            if next == current { break }
            current = next
        }
        cache[owner] = current
        return current
    }

    private struct Identity {
        let name: String
        let icon: NSImage?
        let canQuit: Bool
    }

    /// Name and icon per process, kept while the menu is open so each refresh doesn't
    /// load every app's full-size icon again.
    private static var identities: [pid_t: Identity] = [:]

    static func clearIconCache() { identities = [:] }

    private static func identity(of owner: pid_t, me: pid_t) -> Identity {
        if let cached = identities[owner] { return cached }
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
        let result = Identity(name: name ?? "pid \(owner)", icon: icon.map(thumbnail), canQuit: canQuit)
        identities[owner] = result
        return result
    }

    /// The list draws icons at 18 pt. An app icon holds images up to 1024 px, so keep
    /// one small bitmap instead (36 px covers Retina).
    private static func thumbnail(_ image: NSImage) -> NSImage {
        let px = 36
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep)
        else { return image }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
        NSGraphicsContext.restoreGraphicsState()
        let small = NSImage(size: NSSize(width: 18, height: 18))
        small.addRepresentation(rep)
        return small
    }
}
