import AppKit
import Charts
import RushesKit
import SwiftUI

struct HistoryPage: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        let records = app.history
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if records.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "Nothing copied yet", text: "Every card you copy is listed here, with what it held and how it checked out.")
                        .frame(height: 320)
                } else {
                    Totals(records: records)
                    MonthChart(records: records)
                    VStack(spacing: 0) {
                        ForEach(Array(records.enumerated()), id: \.element.id) { offset, record in
                            HistoryRow(record: record, compact: false)
                            if offset < records.count - 1 { Divider().padding(.leading, 56) }
                        }
                    }
                    .surface(radius: Metrics.card)
                }
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 30)
            .padding(.top, 6)
        }
        .navigationTitle("Imports")
    }
}

private struct Totals: View {
    let records: [Ledger.ImportRecord]

    var body: some View {
        let done = records.filter { $0.status == Ledger.ImportStatus.done }
        let copied = done.reduce(UInt64(0)) { $0 + $1.bytes }
        let saved = done.reduce(UInt64(0)) { $0 + $1.skippedBytes }
        let files = done.reduce(0) { $0 + $1.files }
        HStack(spacing: 14) {
            StatTile(title: "Copied", value: Format.bytes(copied), detail: String(localized: "\(done.count) cards"), symbol: "square.and.arrow.down.fill")
            StatTile(title: "Left out", value: Format.bytes(saved), detail: String(localized: "never touched your disk"), symbol: "leaf.fill", tint: VerdictStyle.keep)
            StatTile(title: "Files checked", value: files.formatted(), detail: String(localized: "every one read back"), symbol: "checkmark.shield.fill", tint: Palette.roseInk)
        }
    }
}

private struct MonthChart: View {
    let records: [Ledger.ImportRecord]

    private struct Point: Identifiable {
        let month: Date
        let kind: String
        let gigabytes: Double
        var id: String { "\(month.timeIntervalSince1970)\(kind)" }
    }

    var body: some View {
        let calendar = Calendar.current
        var points: [Point] = []
        let byMonth = Dictionary(grouping: records.filter { $0.status == Ledger.ImportStatus.done }) {
            calendar.date(from: calendar.dateComponents([.year, .month], from: $0.started)) ?? $0.started
        }
        for (month, list) in byMonth {
            points.append(Point(month: month, kind: String(localized: "Copied"), gigabytes: Double(list.reduce(UInt64(0)) { $0 + $1.bytes }) / 1e9))
            points.append(Point(month: month, kind: String(localized: "Left out"), gigabytes: Double(list.reduce(UInt64(0)) { $0 + $1.skippedBytes }) / 1e9))
        }
        return Card(padding: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Per month").font(.headline)
                Chart(points) { point in
                    BarMark(x: .value("Month", point.month, unit: .month), y: .value("GB", point.gigabytes))
                        .foregroundStyle(by: .value("Kind", point.kind))
                        .position(by: .value("Kind", point.kind))
                        .cornerRadius(5)
                }
                .chartForegroundStyleScale([String(localized: "Copied"): Palette.indigo, String(localized: "Left out"): VerdictStyle.keep])
                .chartYAxisLabel("GB")
                .frame(height: 150)
            }
        }
    }
}

struct HistoryRow: View {
    @Environment(AppModel.self) private var app
    let record: Ledger.ImportRecord
    var compact: Bool
    @LocalState private var sending = false
    @LocalState private var message: String?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 36, height: 36)
                .background(tint.opacity(0.14), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Text(record.label).font(.callout.weight(.semibold))
                    if record.backupFolder != nil { Chip(text: String(localized: "2 copies"), symbol: "square.on.square", tint: Palette.accent) }
                    if record.sentToResolve { Chip(text: "DaVinci", symbol: "film.stack", tint: Palette.roseInk) }
                }
                Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if let message { Text(message).font(.caption).foregroundStyle(.tertiary).lineLimit(2) }
            }
            Spacer(minLength: 8)
            if !compact {
                Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: record.folder)]) } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.icon)
                .help("Show in Finder")
                Button {
                    app.page = .library
                    app.library.selectedID = record.folder
                } label: { Image(systemName: "square.grid.2x2") }
                    .buttonStyle(.icon)
                    .help("Look through it")
                if Prefs.bool(PrefKey.resolveEnabled), record.status == Ledger.ImportStatus.done {
                    Button {
                        sending = true
                        Task {
                            let outcome = await app.sendToResolve(record: record)
                            message = outcome.message
                            sending = false
                        }
                    } label: {
                        if sending { ProgressView().controlSize(.small) } else { Image(systemName: "film.stack") }
                    }
                    .buttonStyle(.icon)
                    .help("Send to DaVinci")
                    .disabled(sending)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var icon: String {
        switch record.status {
        case Ledger.ImportStatus.done: "checkmark"
        case Ledger.ImportStatus.running: "arrow.down"
        default: "exclamationmark"
        }
    }

    private var tint: Color {
        switch record.status {
        case Ledger.ImportStatus.done: VerdictStyle.keep
        case Ledger.ImportStatus.running: Palette.indigo
        default: VerdictStyle.hint
        }
    }

    private var detail: String {
        var parts = [record.started.formatted(date: .abbreviated, time: .shortened)]
        parts.append("\(record.files) " + String(localized: "files") + ", " + Format.bytes(record.bytes))
        if record.skippedBytes > 0 { parts.append(String(localized: "\(Format.bytes(record.skippedBytes)) left out")) }
        if record.duration > 1, record.bytes > 0 {
            parts.append("\(Format.bytes(UInt64(Double(record.bytes) / record.duration)))/s")
        }
        if record.status != Ledger.ImportStatus.done { parts.append(record.status == Ledger.ImportStatus.cancelled ? String(localized: "stopped") : String(localized: "not complete")) }
        return parts.joined(separator: "  ·  ")
    }
}
