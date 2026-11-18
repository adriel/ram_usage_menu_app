import Charts
import Foundation
import Observation
import SwiftUI

struct HistoryPoint: Codable, Identifiable {
    let t: TimeInterval   // seconds since 1970
    let used: Double      // GB
    let swap: Double      // GB
    var id: TimeInterval { t }
    var date: Date { Date(timeIntervalSince1970: t) }
}

/// Rolling 24 h record of memory used + swap, one point every 10 s,
/// saved to Application Support so the graph survives restarts.
@Observable
final class MemoryHistory {
    private(set) var points: [HistoryPoint] = []

    @ObservationIgnored private let interval: TimeInterval = 10
    @ObservationIgnored private let keep: TimeInterval = 24 * 3600
    @ObservationIgnored private var lastSave = Date.distantPast

    private static let fileURL: URL = {
        let dir = URL.applicationSupportDirectory.appending(path: "RAM Watch", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([HistoryPoint].self, from: data) {
            let cutoff = Date.now.timeIntervalSince1970 - keep
            points = saved.filter { $0.t >= cutoff }
        }
    }

    func record(_ s: MemorySnapshot) {
        let now = Date.now.timeIntervalSince1970
        if let last = points.last, now - last.t < interval - 0.5 { return }
        points.append(HistoryPoint(t: now, used: gb(s.used), swap: gb(s.swapUsed)))
        let cutoff = now - keep
        if let first = points.first, first.t < cutoff {
            points.removeAll { $0.t < cutoff }
        }
        if Date.now.timeIntervalSince(lastSave) > 300 { save() }
    }

    func save() {
        lastSave = .now
        if let data = try? JSONEncoder().encode(points) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// Points from the last `seconds`, thinned to at most `maxCount` by keeping each bucket's peak.
    func points(lastSeconds seconds: TimeInterval, maxCount: Int = 240) -> [HistoryPoint] {
        let cutoff = Date.now.timeIntervalSince1970 - seconds
        let recent = points.drop { $0.t < cutoff }
        guard recent.count > maxCount else { return Array(recent) }
        let bucket = Int((Double(recent.count) / Double(maxCount)).rounded(.up))
        return stride(from: recent.startIndex, to: recent.endIndex, by: bucket).compactMap { start in
            recent[start..<min(start + bucket, recent.endIndex)].max { $0.used + $0.swap < $1.used + $1.swap }
        }
    }

    private func gb(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }
}

enum HistoryRange: Int, CaseIterable, Identifiable {
    case quarterHour = 900, hour = 3600, sixHours = 21600, day = 86400
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .quarterHour: "15m"
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        }
    }
}

struct HistoryChart: View {
    let history: MemoryHistory
    let totalBytes: UInt64
    @AppStorage("historyRange") private var range = HistoryRange.hour

    private var totalGB: Double { Double(totalBytes) / 1_073_741_824 }

    var body: some View {
        let pts = history.points(lastSeconds: TimeInterval(range.rawValue))
        let peak = pts.map { $0.used + $0.swap }.max() ?? 0
        let top = max(totalGB, peak) * 1.08

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("History").font(.subheadline.weight(.semibold))
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.mini)
                .fixedSize()
            }

            if pts.count < 2 {
                Text("Collecting data… the graph fills in over the next minute.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                Chart {
                    ForEach(pts) { p in
                        AreaMark(
                            x: .value("Time", p.date),
                            yStart: .value("GB", 0), yEnd: .value("GB", p.used),
                            series: .value("Series", "Used"))
                            .foregroundStyle(Color.blue.opacity(0.28))
                        AreaMark(
                            x: .value("Time", p.date),
                            yStart: .value("GB", p.used), yEnd: .value("GB", p.used + p.swap),
                            series: .value("Series", "Swap"))
                            .foregroundStyle(Color.red.opacity(0.6))
                        LineMark(
                            x: .value("Time", p.date), y: .value("GB", p.used),
                            series: .value("Series", "UsedLine"))
                            .foregroundStyle(Color.blue)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                    }
                    RuleMark(y: .value("RAM", totalGB))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.secondary)
                        .annotation(position: .top, alignment: .leading, spacing: 1) {
                            Text("\(Int(totalGB.rounded())) GB RAM").font(.caption2).foregroundStyle(.secondary)
                        }
                }
                .chartYScale(domain: 0...top)
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine()
                        AxisValueLabel { if let v = value.as(Double.self) { Text("\(Int(v)) GB") } }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                        AxisGridLine()
                        AxisValueLabel(format: .dateTime.hour().minute())
                    }
                }
                .frame(height: 110)

                HStack(spacing: 12) {
                    legend(Color.blue, "Memory used")
                    legend(Color.red.opacity(0.7), "Swap (on top of RAM)")
                    Spacer()
                }
                .font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(text)
        }
    }
}
