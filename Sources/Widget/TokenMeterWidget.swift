// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import WidgetKit

@main
struct TokenMeterWidgetBundle: WidgetBundle {
    var body: some Widget {
        TokenMeterUsageWidget()
    }
}

/// Desktop / Notification Center widget: today's tokens + estimated cost at
/// a glance, with block/week context in the medium size.
///
/// Refresh cadence: widgets aren't real-time — WidgetKit budgets refreshes.
/// The timeline re-reads the shared snapshot every 15 minutes, and the app
/// additionally requests a reload when numbers change (throttled). Live
/// numbers are in the menu bar; the widget is the ambient readout.
struct TokenMeterUsageWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "TokenMeterUsageWidget",
            provider: SnapshotTimelineProvider()
        ) { entry in
            WidgetContentView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Token Meter")
        .description("Today's AI token usage and estimated cost. Updates about every 15 minutes.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Timeline

struct SnapshotEntry: TimelineEntry {
    let date: Date
    /// `nil` when the app hasn't written a snapshot yet (never launched, or
    /// the group container isn't available).
    let snapshot: WidgetSnapshot?
}

struct SnapshotTimelineProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .placeholder)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(
            date: .now,
            snapshot: WidgetSnapshot.load() ?? (context.isPreview ? .placeholder : nil)
        ))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let entry = SnapshotEntry(date: .now, snapshot: WidgetSnapshot.load())
        completion(Timeline(
            entries: [entry],
            policy: .after(Date.now.addingTimeInterval(15 * 60))
        ))
    }
}

// MARK: - Views

struct WidgetContentView: View {
    @Environment(\.widgetFamily) private var family
    let entry: SnapshotEntry

    var body: some View {
        if let snapshot = entry.snapshot {
            switch family {
            case .systemMedium:
                MediumWidgetView(snapshot: snapshot)
            default:
                SmallWidgetView(snapshot: snapshot)
            }
        } else {
            emptyState
        }
    }

    private var emptyState: some View {
        VStack(spacing: 4) {
            Image(systemName: "gauge.with.needle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open Token Meter to start tracking")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct SmallWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Today", systemImage: "gauge.with.needle")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(snapshot.todayTokens, format: .number.notation(.compactName))
                .font(.system(.title, design: .rounded, weight: .bold))
                .minimumScaleFactor(0.6)
            Text(costText)
                .font(.callout.weight(.medium))
                .foregroundStyle(snapshot.todayCostUSD == nil ? .tertiary : .secondary)
            Spacer(minLength: 0)
            footer
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var costText: String {
        snapshot.todayCostUSD.map { "≈" + $0.formatted(.currency(code: "USD")) } ?? "—"
    }

    private var footer: some View {
        Text("est · \(snapshot.updatedAt, format: .dateTime.hour().minute())")
            .font(.caption2)
            .foregroundStyle(.tertiary)
    }
}

private struct MediumWidgetView: View {
    let snapshot: WidgetSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 12) {
                column(
                    title: "Today",
                    value: snapshot.todayTokens,
                    detail: snapshot.todayCostUSD.map {
                        "≈" + $0.formatted(.currency(code: "USD"))
                    } ?? "—"
                )
                Divider()
                column(
                    title: "5-hr block",
                    value: snapshot.blockTokens,
                    detail: snapshot.blockEndsAt.map {
                        "ends \($0.formatted(.dateTime.hour().minute()))"
                    } ?? "none active"
                )
                Divider()
                column(
                    title: "This week",
                    value: snapshot.weekTokens,
                    detail: snapshot.localTokens > 0
                        ? "local \(snapshot.localTokens.formatted(.number.notation(.compactName)))"
                        : " "
                )
            }
            Spacer(minLength: 0)
            Text("estimated — not your real quota · as of \(snapshot.updatedAt, format: .dateTime.hour().minute())")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func column(title: String, value: Int?, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value ?? 0, format: .number.notation(.compactName))
                .font(.system(.title3, design: .rounded, weight: .semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
