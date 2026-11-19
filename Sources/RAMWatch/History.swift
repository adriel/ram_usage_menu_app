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

/// A point ready to draw. `segment` changes wherever recording stopped (Mac asleep or
/// RAM Watch not running), so the graph shows a gap there instead of a line across it.
struct ChartPoint: Identifiable {
    let date: Date
    let used: Double
    let swap: Double
    let segment: Int
    var id: Date { date }
}

/// Rolling 7-day record of memory used + swap, saved to Application Support so the graph
/// survives restarts. The last 24 h keep a point every 10 s; older data is thinned to one
/// point per minute (each minute's peak), which keeps the file around 1 MB.
@Observable
final class MemoryHistory {
    private(set) var points: [HistoryPoint] = []

    @ObservationIgnored private let interval: TimeInterval = 10
    @ObservationIgnored private let keep: TimeInterval = 7 * 24 * 3600
    @ObservationIgnored private let fullDetail: TimeInterval = 24 * 3600
    @ObservationIgnored private let thinnedStep: TimeInterval = 60
    @ObservationIgnored private var lastSave = Date.distantPast

    private static let fileURL: URL = {
        let dir = URL.applicationSupportDirectory.appending(path: "RAM Watch", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.json")
    }()

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let saved = try? JSONDecoder().decode([HistoryPoint].self, from: data) {
            points = saved.sorted { $0.t < $1.t }
            compact()
        }
    }

    func record(_ s: MemorySnapshot) {
        let now = Date.now.timeIntervalSince1970.rounded()
        if let last = points.last, now - last.t < interval - 0.5 { return }
        points.append(HistoryPoint(t: now, used: round2(gb(s.used)), swap: round2(gb(s.swapUsed))))
        if Date.now.timeIntervalSince(lastSave) > 300 {
            compact()
            save()
        }
    }

    func save() {
        lastSave = .now
        if let data = try? JSONEncoder().encode(points) {
            try? data.write(to: Self.fileURL, options: .atomic)
        }
    }

    /// Drops points older than 7 days and thins those older than 24 h to one per minute.
    private func compact() {
        let now = Date.now.timeIntervalSince1970
        let oldest = now - keep, detailed = now - fullDetail
        var result: [HistoryPoint] = []
        result.reserveCapacity(points.count)
        var bucket: (key: Int, peak: HistoryPoint)?
        for p in points where p.t >= oldest {
            guard p.t < detailed else {
                if let b = bucket { result.append(b.peak); bucket = nil }
                result.append(p)
                continue
            }
            let key = Int(p.t / thinnedStep)
            if let b = bucket, b.key == key {
                if p.used + p.swap > b.peak.used + b.peak.swap { bucket = (key, p) }
            } else {
                if let b = bucket { result.append(b.peak) }
                bucket = (key, p)
            }
        }
        if let b = bucket { result.append(b.peak) }
        points = result
    }

    /// Points from the last `seconds`, thinned to at most `maxCount` by keeping each time
    /// slot's peak, and split into segments wherever recording stopped.
    func chartPoints(lastSeconds seconds: TimeInterval, maxCount: Int = 300) -> [ChartPoint] {
        let now = Date.now.timeIntervalSince1970
        let cutoff = now - seconds
        let recent = points.drop { $0.t < cutoff }
        let slot = max(interval, seconds / Double(maxCount))

        var thinned: [HistoryPoint] = []
        var current: (key: Int, peak: HistoryPoint)?
        for p in recent {
            let key = Int((p.t - cutoff) / slot)
            if let c = current, c.key == key {
                if p.used + p.swap > c.peak.used + c.peak.swap { current = (key, p) }
            } else {
                if let c = current { thinned.append(c.peak) }
                current = (key, p)
            }
        }
        if let c = current { thinned.append(c.peak) }

        // A gap is anything clearly longer than the spacing the data was recorded or thinned at.
        var segment = 0
        var previous: TimeInterval?
        return thinned.map { p in
            let spacing = max(slot, now - p.t > fullDetail ? thinnedStep : interval)
            if let previous, p.t - previous > spacing * 3 { segment += 1 }
            previous = p.t
            return ChartPoint(date: p.date, used: p.used, swap: p.swap, segment: segment)
        }
    }

    private func gb(_ bytes: UInt64) -> Double { Double(bytes) / 1_073_741_824 }
    private func round2(_ x: Double) -> Double { (x * 100).rounded() / 100 }
}

enum HistoryRange: Int, CaseIterable, Identifiable {
    case quarterHour = 900, hour = 3600, sixHours = 21600, day = 86400, week = 604800
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .quarterHour: "15m"
        case .hour: "1h"
        case .sixHours: "6h"
        case .day: "24h"
        case .week: "7d"
        }
    }
}

struct HistoryChart: View {
    let history: MemoryHistory
    let totalBytes: UInt64
    @AppStorage("historyRange") private var range = HistoryRange.hour

    private var totalGB: Double { Double(totalBytes) / 1_073_741_824 }

    var body: some View {
        let pts = history.chartPoints(lastSeconds: TimeInterval(range.rawValue))
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
                Text(range == .week && !pts.isEmpty
                     ? "Collecting data… the 7-day graph fills in as RAM Watch runs."
                     : "Collecting data… the graph fills in over the next minute.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                Chart {
                    ForEach(pts) { p in
                        AreaMark(
                            x: .value("Time", p.date),
                            yStart: .value("GB", 0), yEnd: .value("GB", p.used),
                            series: .value("Series", "Used \(p.segment)"))
                            .foregroundStyle(Color.blue.opacity(0.28))
                        AreaMark(
                            x: .value("Time", p.date),
                            yStart: .value("GB", p.used), yEnd: .value("GB", p.used + p.swap),
                            series: .value("Series", "Swap \(p.segment)"))
                            .foregroundStyle(Color.red.opacity(0.6))
                        LineMark(
                            x: .value("Time", p.date), y: .value("GB", p.used),
                            series: .value("Series", "Line \(p.segment)"))
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
                .chartXScale(domain: Date.now.addingTimeInterval(-TimeInterval(range.rawValue))...Date.now)
                .chartXAxis {
                    if range == .week {
                        AxisMarks(values: .stride(by: .day)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: .dateTime.weekday(.abbreviated), centered: true)
                        }
                    } else {
                        AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                            AxisGridLine()
                            AxisValueLabel(format: range == .day ? .dateTime.hour() : .dateTime.hour().minute())
                        }
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
