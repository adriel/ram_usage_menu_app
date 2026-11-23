import Charts
import Foundation
import Observation
import SwiftUI

/// One reading, 12 bytes. Kept small because a week of history is about 17,000 of them.
struct HistoryPoint {
    let t: UInt32      // seconds since 1970
    let used: Float    // GB
    let swap: Float    // GB
    var time: TimeInterval { TimeInterval(t) }
    var total: Float { used + swap }
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
/// point per minute (each minute's peak). Saved as raw 12-byte records (about 200 KB),
/// which loads and saves without building any temporary objects.
@Observable
final class MemoryHistory {
    private(set) var points: [HistoryPoint] = []

    @ObservationIgnored private let interval: TimeInterval = 10
    @ObservationIgnored private let keep: TimeInterval = 7 * 24 * 3600
    @ObservationIgnored private let fullDetail: TimeInterval = 24 * 3600
    @ObservationIgnored private let thinnedStep: TimeInterval = 60
    @ObservationIgnored private var lastSave = Date.distantPast

    private static let directory: URL = {
        let dir = URL.applicationSupportDirectory.appending(path: "RAM Watch", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private static let fileURL = directory.appending(path: "history.bin")
    /// Format used up to 1.1.6, read once and then removed.
    private static let legacyURL = directory.appending(path: "history.json")

    init() {
        // An old-format file is the newest data if one exists (it's only written by 1.1.6 and earlier).
        if let data = try? Data(contentsOf: Self.legacyURL) {
            if let saved = try? JSONDecoder().decode([LegacyPoint].self, from: data) {
                points = saved.map { HistoryPoint(t: UInt32(clamping: Int($0.t)), used: Float($0.used), swap: Float($0.swap)) }
                save()
            }
            try? FileManager.default.removeItem(at: Self.legacyURL)
        } else if let data = try? Data(contentsOf: Self.fileURL) {
            let stride = MemoryLayout<HistoryPoint>.stride
            points = [HistoryPoint](unsafeUninitializedCapacity: data.count / stride) { buffer, count in
                count = data.copyBytes(to: buffer) / stride
            }
        }
        if !points.isEmpty {
            points.sort { $0.t < $1.t }
            compact()
        }
    }

    private struct LegacyPoint: Decodable {
        let t: Double
        let used: Double
        let swap: Double
    }

    func record(_ s: MemorySnapshot) {
        let now = Date.now.timeIntervalSince1970.rounded()
        if let last = points.last, now - last.time < interval - 0.5 { return }
        points.append(HistoryPoint(t: UInt32(now), used: round2(gb(s.used)), swap: round2(gb(s.swapUsed))))
        if Date.now.timeIntervalSince(lastSave) > 300 {
            compact()
            save()
        }
    }

    func save() {
        lastSave = .now
        let data = points.withUnsafeBufferPointer { Data(buffer: $0) }
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Drops points older than 7 days and thins those older than 24 h to one per minute.
    private func compact() {
        let now = Date.now.timeIntervalSince1970
        let oldest = now - keep, detailed = now - fullDetail
        var result: [HistoryPoint] = []
        result.reserveCapacity(points.count)
        var bucket: (key: Int, peak: HistoryPoint)?
        for p in points where p.time >= oldest {
            guard p.time < detailed else {
                if let b = bucket { result.append(b.peak); bucket = nil }
                result.append(p)
                continue
            }
            let key = Int(p.time / thinnedStep)
            if let b = bucket, b.key == key {
                if p.total > b.peak.total { bucket = (key, p) }
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
    /// About two pixels per point across the menu's width: enough to look smooth, and each
    /// point costs three chart marks while the menu is open.
    func chartPoints(lastSeconds seconds: TimeInterval, maxCount: Int = 160) -> [ChartPoint] {
        let now = Date.now.timeIntervalSince1970
        let cutoff = now - seconds
        let recent = points.drop { $0.time < cutoff }
        let slot = max(interval, seconds / Double(maxCount))

        var thinned: [HistoryPoint] = []
        thinned.reserveCapacity(min(recent.count, maxCount + 1))
        var current: (key: Int, peak: HistoryPoint)?
        for p in recent {
            let key = Int((p.time - cutoff) / slot)
            if let c = current, c.key == key {
                if p.total > c.peak.total { current = (key, p) }
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
            let spacing = max(slot, now - p.time > fullDetail ? thinnedStep : interval)
            if let previous, p.time - previous > spacing * 3 { segment += 1 }
            previous = p.time
            return ChartPoint(date: Date(timeIntervalSince1970: p.time), used: Double(p.used), swap: Double(p.swap), segment: segment)
        }
    }

    private func gb(_ bytes: UInt64) -> Float { Float(Double(bytes) / 1_073_741_824) }
    private func round2(_ x: Float) -> Float { (x * 100).rounded() / 100 }
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
