import AppKit
import SwiftUI

/// The parts of RAM shown in the stacked bar, with plain-language explanations.
enum MemoryPart: CaseIterable, Identifiable {
    case app, wired, compressed, cached, free
    var id: Self { self }

    var label: String {
        switch self {
        case .app: "App memory"
        case .wired: "Wired"
        case .compressed: "Compressed"
        case .cached: "Cached files"
        case .free: "Free"
        }
    }

    var color: Color {
        switch self {
        case .app: .blue
        case .wired: .purple
        case .compressed: .teal
        case .cached: .gray.opacity(0.55)
        case .free: .primary.opacity(0.08)
        }
    }

    var explanation: String {
        switch self {
        case .app:
            "Memory apps and browser tabs are using right now. This is the part you can free up by closing tabs and apps."
        case .wired:
            "Memory macOS keeps for itself: the system core, drivers and graphics. It can't be compressed, swapped or freed."
        case .compressed:
            "App memory macOS has squeezed to make room, rather than writing it to disk. A lot of compressed memory means RAM is running short."
        case .cached:
            "Copies of recently used files kept in spare RAM so they open faster. macOS hands this back to apps instantly, so it's effectively free."
        case .free:
            "Memory nothing is using. Little free memory is normal: macOS fills spare RAM with cached files to speed things up."
        }
    }

    func bytes(in s: MemorySnapshot) -> UInt64 {
        switch self {
        case .app: s.app
        case .wired: s.wired
        case .compressed: s.compressed
        case .cached: s.cached
        case .free: s.free
        }
    }
}

struct PopoverView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let s = model.snapshot {
                header
                if model.diskLow, let disk = model.disk { diskBanner(disk) }

                Picker("Section", selection: $model.section) {
                    ForEach(PopoverSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                switch model.section {
                case .overview: OverviewSection(model: model, snapshot: s)
                case .apps: AppsSection(model: model)
                case .tabs: TabsSection(model: model)
                }

                if case .available(let release) = model.updater.state { updateBanner(release) }
                Divider()
                footer
            } else {
                Text("Reading memory…").foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(width: 360)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle().fill(model.memoryHealth.color).frame(width: 12, height: 12).padding(.top, 4)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.memoryHealth.title).font(.headline)
                Text(model.memoryHealth.advice)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func diskBanner(_ disk: DiskStatus) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "internaldrive.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Low disk space: \(formatBytes(disk.free)) free").font(.callout.weight(.semibold))
                Text("Your Mac needs free space to use as extra memory. Empty the Trash or delete large files.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func updateBanner(_ release: Updater.Release) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
            Text("RAM Watch \(release.version) is available").font(.callout)
            Spacer()
            Button("Install") { Task { await model.updater.install(release) } }
                .controlSize(.small)
        }
        .padding(8)
        .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private var footer: some View {
        HStack {
            Button("Activity Monitor") {
                NSWorkspace.shared.open(URL(filePath: "/System/Applications/Utilities/Activity Monitor.app"))
            }
            Spacer()
            Button("Settings…") { model.openSettings() }
            Button("Quit") { NSApp.terminate(nil) }
        }
        .controlSize(.small)
    }
}

// MARK: - Overview

private struct OverviewSection: View {
    let model: AppModel
    let snapshot: MemorySnapshot
    @AppStorage(Pref.swapWarningMB) private var swapWarningMB = 1024
    @State private var hovered: MemoryPart?

    var body: some View {
        let s = snapshot
        VStack(alignment: .leading, spacing: 12) {
            HistoryChart(history: model.history, totalBytes: s.total)
                // Hovering a part of the memory bar (or its row) explains it, floating over the graph.
                .overlay(alignment: .bottom) {
                    if let hovered {
                        MemoryPartCard(part: hovered, snapshot: s, apps: model.apps)
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.12), value: hovered)
                .zIndex(1)
            Divider()
            memory(s)
            Divider()
            swap(s)
            if let disk = model.disk {
                Divider()
                diskRow(disk)
            }
        }
    }

    private func memory(_ s: MemorySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Memory").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(formatBytes(s.used)) of \(formatBytes(s.total)) used")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
            }

            MemoryBar(snapshot: s, hovered: $hovered)
                .frame(height: 12)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                ForEach(MemoryPart.allCases) { part in
                    GridRow {
                        RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 10, height: 10)
                        Text(part.label)
                        Spacer()
                        Text(formatBytes(part.bytes(in: s))).monospacedDigit().gridColumnAlignment(.trailing)
                    }
                    .fontWeight(hovered == part ? .semibold : .regular)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = part } else if hovered == part { hovered = nil }
                    }
                }
                GridRow {
                    Color.clear.frame(width: 10, height: 10)
                    Text("Memory pressure")
                    Spacer()
                    Text(s.pressure.label)
                        .foregroundStyle(s.pressure == .normal ? Color.secondary : (s.pressure == .warning ? .orange : .red))
                        .gridColumnAlignment(.trailing)
                }
            }
            .font(.callout)
        }
    }

    private func swap(_ s: MemorySnapshot) -> some View {
        let limit = UInt64(swapWarningMB) * 1_048_576
        let overLimit = s.swapUsed > limit
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Swap").font(.subheadline.weight(.semibold))
                Spacer()
                Text(s.swapTotal > 0 ? "\(formatBytes(s.swapUsed)) of \(formatBytes(s.swapTotal))" : "None")
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(overLimit ? Color.red : (s.swapUsed > 0 ? .orange : .secondary))
            }
            SwapBar(used: s.swapUsed, total: s.swapTotal, limit: limit, overLimit: overLimit)
                .frame(height: 8)
            HStack(spacing: 5) {
                if limit > 0 && limit < s.swapTotal {
                    Rectangle().fill(Color.primary.opacity(0.6)).frame(width: 2, height: 9)
                }
                Text(limit == 0 ? "Turns red on any swap" : "Turns red above \(formatBytes(limit))")
                Spacer()
                if s.isActivelySwapping {
                    Text("Swapping now: \(formatRate(s.swapOutRate + s.swapInRate))").foregroundStyle(.red)
                } else {
                    Text("No swap activity right now")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .help("Swap is disk space macOS uses as overflow memory. It adds more swap as needed, so the total grows and shrinks.")
    }

    private func diskRow(_ disk: DiskStatus) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Disk").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(formatBytes(disk.free)) free of \(formatBytes(disk.total))")
                    .font(.subheadline).monospacedDigit()
                    .foregroundStyle(model.diskLow ? Color.orange : .secondary)
            }
            ProgressView(value: disk.usedFraction)
                .tint(model.diskLow ? .orange : .accentColor)
        }
    }
}

// MARK: - Apps

private struct AppsSection: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Using the most memory").font(.subheadline.weight(.semibold))
            if model.apps.isEmpty {
                Text("Loading…").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(model.apps) { app in
                AppRow(app: app, onQuit: {
                    NSRunningApplication(processIdentifier: app.id)?.terminate()
                    Task { try? await Task.sleep(for: .seconds(1.5)); model.refreshApps() }
                })
            }
            Text("Includes each app's helper processes (e.g. one per browser tab). System processes aren't listed.")
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct AppRow: View {
    let app: AppMemoryUsage
    let onQuit: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = app.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "gearshape").resizable().foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, height: 18)

            VStack(alignment: .leading, spacing: 0) {
                Text(app.name).lineLimit(1).truncationMode(.tail)
                if app.processCount > 1 {
                    Text("\(app.processCount) processes").font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if hovering && app.canQuit {
                Button("Quit", action: onQuit)
                    .controlSize(.mini)
                    .help("Ask \(app.name) to quit (it will prompt to save anything unsaved).")
            }
            Text(formatBytes(app.bytes)).monospacedDigit()
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}

// MARK: - Browser tabs

private struct TabsSection: View {
    @Bindable var model: AppModel
    private let scrollAfter = 9

    private var name: String { model.browser.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if model.runningBrowsers.count > 1 {
                Picker("Browser", selection: $model.browser) {
                    ForEach(model.runningBrowsers) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.bottom, 2)
            }

            HStack {
                Text(model.browser.isChromium ? "\(name) tabs" : "\(name) tabs by memory")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if model.tabsStatus == .loaded, let total = totalBytes {
                    Text("\(formatBytes(total)) total").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            switch model.tabsStatus {
            case .idle, .loading:
                message("Reading \(name)'s tabs…", detail: "The first time, macOS asks whether RAM Watch may control \(name). Click OK so it can list and close tabs.")
            case .notRunning:
                message("No browser is open.", detail: "RAM Watch can show tabs from Safari, Chrome, Brave and Edge.")
            case .denied:
                message("RAM Watch isn't allowed to see \(name)'s tabs.",
                        detail: "Turn on \(name) under RAM Watch in System Settings → Privacy & Security → Automation.")
                Button("Open Automation Settings") { BrowserTabs.openAutomationSettings() }
                    .controlSize(.small)
            case .failed(let error):
                message("Couldn't read \(name)'s tabs.", detail: error)
            case .loaded where model.tabs.isEmpty:
                message("No open tabs are using memory.")
            case .loaded:
                if model.tabs.count > scrollAfter {
                    ScrollView {
                        rows.padding(.trailing, 10)
                    }
                    .frame(height: 320)
                } else {
                    rows
                }
                footnote
            }
        }
    }

    private var rows: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(model.tabs) { tab in
                TabRow(tab: tab) { model.close(tab) }
            }
        }
    }

    private var totalBytes: UInt64? {
        if model.browser.isChromium { return model.tabsTotalBytes }
        // Count each WebContent process once, even if several tabs share it.
        var seen = Set<pid_t>()
        return model.tabs.reduce(0) { sum, t in seen.insert(t.pid).inserted ? sum + (t.bytes ?? 0) : sum }
    }

    @ViewBuilder private var footnote: some View {
        let parts: [String] = if model.browser.isChromium {
            ["\(model.tabs.count) tabs. \(name) doesn't let other apps see how much memory each tab uses, so they're listed in order. For per-tab memory, use \(name)'s own Window → Task Manager."]
        } else {
            [model.unloadedTabs > 0 ? "\(model.unloadedTabs) more tab\(model.unloadedTabs == 1 ? " is" : "s are") asleep and using no memory." : nil].compactMap { $0 }
        }
        if !parts.isEmpty {
            Text(parts.joined(separator: " "))
                .font(.caption2).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func message(_ title: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.callout)
            if let detail {
                Text(detail).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct TabRow: View {
    let tab: BrowserTab
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(hovering ? Color.red : Color.secondary)
            }
            .buttonStyle(.plain)
            .help("Close this tab")

            VStack(alignment: .leading, spacing: 0) {
                Text(tab.title.isEmpty ? tab.host : tab.title)
                    .lineLimit(1).truncationMode(.tail)
                Text(tab.sharedWith > 0 ? "\(tab.host) · shared with \(tab.sharedWith) other tab\(tab.sharedWith == 1 ? "" : "s")" : tab.host)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let bytes = tab.bytes {
                Text(formatBytes(bytes)).monospacedDigit()
                    .foregroundStyle(bytes > 1_073_741_824 ? Color.red : (bytes > 500 * 1_048_576 ? .orange : .primary))
            }
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tab.url)
    }
}

// MARK: - Shared

/// Stacked bar of the parts of RAM. Hovering a part highlights it.
private struct MemoryBar: View {
    let snapshot: MemorySnapshot
    @Binding var hovered: MemoryPart?

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(MemoryPart.allCases) { part in
                    let fraction = snapshot.total == 0 ? 0 : Double(part.bytes(in: snapshot)) / Double(snapshot.total)
                    Rectangle()
                        .fill(part.color)
                        .opacity(hovered == nil || hovered == part ? 1 : 0.35)
                        .frame(width: geo.size.width * fraction)
                        .contentShape(Rectangle())
                        .onHover { inside in
                            if inside { hovered = part } else if hovered == part { hovered = nil }
                        }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

/// Floating explanation of one part of RAM, shown while hovering it.
private struct MemoryPartCard: View {
    let part: MemoryPart
    let snapshot: MemorySnapshot
    let apps: [AppMemoryUsage]

    var body: some View {
        let bytes = part.bytes(in: snapshot)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 2).fill(part.color).frame(width: 10, height: 10)
                Text(part.label).font(.callout.weight(.semibold))
                Spacer()
                Text("\(formatBytes(bytes)) · \(Int((Double(bytes) / Double(max(snapshot.total, 1)) * 100).rounded()))% of RAM")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            Text(part.explanation)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if part == .app, !apps.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Biggest apps (their totals include their compressed memory):")
                        .font(.caption2).foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(apps.prefix(4)) { app in
                        HStack(spacing: 6) {
                            if let icon = app.icon {
                                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
                            }
                            Text(app.name).lineLimit(1)
                            Spacer()
                            Text(formatBytes(app.bytes)).monospacedDigit()
                        }
                        .font(.caption)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.12)))
        .shadow(color: .black.opacity(0.18), radius: 8, y: 3)
    }
}

/// Swap used as a share of the swap space macOS has set aside, with a line at the red threshold.
private struct SwapBar: View {
    let used: UInt64
    let total: UInt64
    let limit: UInt64
    let overLimit: Bool

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fraction = total == 0 ? 0 : min(1, Double(used) / Double(total))
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(overLimit ? Color.red : .orange)
                    .frame(width: used == 0 ? 0 : max(geo.size.height, w * fraction))
                if limit > 0 && limit < total {
                    Rectangle().fill(Color.primary.opacity(0.6))
                        .frame(width: 2, height: geo.size.height + 4)
                        .offset(x: w * Double(limit) / Double(total) - 1)
                }
            }
        }
    }
}
