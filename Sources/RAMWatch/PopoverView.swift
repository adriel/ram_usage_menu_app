import AppKit
import SwiftUI

private enum Seg {
    static let app = Color.blue
    static let wired = Color.purple
    static let compressed = Color.teal
    static let cached = Color.gray.opacity(0.55)
    static let free = Color.primary.opacity(0.08)
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
                case .tabs: SafariTabsSection(model: model)
                }

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

    var body: some View {
        let s = snapshot
        VStack(alignment: .leading, spacing: 12) {
            HistoryChart(history: model.history, totalBytes: s.total)
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

            StackedBar(total: s.total, segments: [
                (s.app, Seg.app), (s.wired, Seg.wired), (s.compressed, Seg.compressed),
                (s.cached, Seg.cached), (s.free, Seg.free),
            ])
            .frame(height: 12)

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 4) {
                row("App memory", s.app, Seg.app, help: "Memory used by apps and browser tabs.")
                row("Wired", s.wired, Seg.wired, help: "Used by macOS itself; can't be freed or swapped.")
                row("Compressed", s.compressed, Seg.compressed, help: "Memory macOS squeezed to make room. High = RAM is tight.")
                row("Cached files", s.cached, Seg.cached, help: "Recently used files. macOS frees this instantly when needed.")
                row("Free", s.free, Seg.free, help: "Completely unused memory.")
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

    private func row(_ label: String, _ bytes: UInt64, _ color: Color, help: String) -> some View {
        GridRow {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
            Spacer()
            Text(formatBytes(bytes)).monospacedDigit().gridColumnAlignment(.trailing)
        }
        .help(help)
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
            ProgressView(value: Double(min(s.swapUsed, max(limit, 1))), total: Double(max(limit, 1)))
                .tint(overLimit ? .red : .orange)
            HStack {
                Text(limit == 0 ? "Warns on any swap" : "Warns above \(formatBytes(limit))")
                Spacer()
                if s.isActivelySwapping {
                    Text("Swapping now: \(formatRate(s.swapOutRate + s.swapInRate))").foregroundStyle(.red)
                } else {
                    Text("No swap activity right now")
                }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
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

// MARK: - Safari tabs

private struct SafariTabsSection: View {
    let model: AppModel
    private let maxRows = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Safari tabs by memory").font(.subheadline.weight(.semibold))
                Spacer()
                if model.tabsStatus == .loaded {
                    Text("\(formatBytes(totalBytes)) total").font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            }

            switch model.tabsStatus {
            case .idle, .loading:
                message("Reading Safari's tabs…", detail: "The first time, macOS asks whether RAM Watch may control Safari. Click OK so it can list and close tabs.")
            case .notRunning:
                message("Safari isn't open.")
            case .denied:
                message("RAM Watch isn't allowed to see Safari's tabs.",
                        detail: "Turn on Safari under RAM Watch in System Settings → Privacy & Security → Automation.")
                Button("Open Automation Settings") { SafariTabs.openAutomationSettings() }
                    .controlSize(.small)
            case .failed(let error):
                message("Couldn't read Safari's tabs.", detail: error)
            case .loaded where model.tabs.isEmpty:
                message("No open tabs are using memory.")
            case .loaded:
                ForEach(model.tabs.prefix(maxRows)) { tab in
                    TabRow(tab: tab) { model.close(tab) }
                }
                footnote
            }
        }
    }

    private var totalBytes: UInt64 {
        // Count each WebContent process once, even if several tabs share it.
        var seen = Set<pid_t>()
        return model.tabs.reduce(0) { sum, t in seen.insert(t.pid).inserted ? sum + t.bytes : sum }
    }

    @ViewBuilder private var footnote: some View {
        let more = model.tabs.count - maxRows
        let parts = [
            more > 0 ? "\(more) more tab\(more == 1 ? "" : "s") not shown." : nil,
            model.unloadedTabs > 0 ? "\(model.unloadedTabs) tab\(model.unloadedTabs == 1 ? " is" : "s are") asleep and using no memory." : nil,
        ].compactMap { $0 }
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
    let tab: SafariTab
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
            Text(formatBytes(tab.bytes)).monospacedDigit()
                .foregroundStyle(tab.bytes > 1_073_741_824 ? Color.red : (tab.bytes > 500 * 1_048_576 ? .orange : .primary))
        }
        .font(.callout)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(tab.url)
    }
}

// MARK: - Shared

private struct StackedBar: View {
    let total: UInt64
    let segments: [(UInt64, Color)]

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    Rectangle()
                        .fill(seg.1)
                        .frame(width: total == 0 ? 0 : geo.size.width * CGFloat(Double(seg.0) / Double(total)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}
