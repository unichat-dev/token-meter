// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Pre-binned aggregates for charting. Charts must never receive raw events —
/// a month of history is tens of thousands of marks; binned it's dozens.
enum UsageAggregation {
    /// One (time bin × model) cell of the time-series chart.
    struct TimeBinRow: Equatable, Identifiable, Sendable {
        var binStart: Date
        var model: String
        var tokens: Int

        var id: String { "\(binStart.timeIntervalSince1970)|\(model)" }
    }

    /// One row of a categorical breakdown (per-model / per-project).
    struct CategoryRow: Equatable, Identifiable, Sendable {
        var key: String
        var tokens: Int
        var eventCount: Int

        var id: String { key }
    }

    /// Groups events into calendar bins (`.hour` for a day view, `.day` for
    /// week/month views), split by model. Rows are sorted by bin, then model.
    static func timeBins(
        events: [UsageEvent],
        component: Calendar.Component,
        calendar: Calendar
    ) -> [TimeBinRow] {
        var cells: [String: TimeBinRow] = [:]
        for event in events {
            guard let bin = calendar.dateInterval(of: component, for: event.timestamp)?.start else {
                continue
            }
            let key = "\(bin.timeIntervalSince1970)|\(event.model)"
            cells[key, default: TimeBinRow(binStart: bin, model: event.model, tokens: 0)]
                .tokens += event.tokens.total
        }
        return cells.values.sorted {
            ($0.binStart, $0.model) < ($1.binStart, $1.model)
        }
    }

    /// One (time bin × model) cell for an arbitrary numeric value (e.g. cost
    /// in USD). Same shape as ``TimeBinRow`` with a `Double` payload for
    /// charting.
    struct ValueBinRow: Equatable, Identifiable, Sendable {
        var binStart: Date
        var model: String
        var value: Double

        var id: String { "\(binStart.timeIntervalSince1970)|\(model)" }
    }

    /// Like ``timeBins(events:component:calendar:)`` but summing a derived
    /// value per event. Events where `value` returns `nil` are skipped
    /// (e.g. unpriced models in a cost chart — no guessed bars).
    static func valueTimeBins(
        events: [UsageEvent],
        component: Calendar.Component,
        calendar: Calendar,
        value: (UsageEvent) -> Double?
    ) -> [ValueBinRow] {
        var cells: [String: ValueBinRow] = [:]
        for event in events {
            guard
                let amount = value(event),
                let bin = calendar.dateInterval(of: component, for: event.timestamp)?.start
            else { continue }
            let key = "\(bin.timeIntervalSince1970)|\(event.model)"
            cells[key, default: ValueBinRow(binStart: bin, model: event.model, value: 0)]
                .value += amount
        }
        return cells.values.sorted {
            ($0.binStart, $0.model) < ($1.binStart, $1.model)
        }
    }

    /// Totals grouped by an arbitrary key (model, project…), biggest first.
    /// `nil` keys are grouped under `nilLabel`.
    static func totals(
        events: [UsageEvent],
        nilLabel: String = "—",
        key: (UsageEvent) -> String?
    ) -> [CategoryRow] {
        var rows: [String: CategoryRow] = [:]
        for event in events {
            let label = key(event) ?? nilLabel
            rows[label, default: CategoryRow(key: label, tokens: 0, eventCount: 0)].tokens += event.tokens.total
            rows[label]?.eventCount += 1
        }
        return rows.values.sorted {
            if $0.tokens != $1.tokens { return $0.tokens > $1.tokens }
            return $0.key < $1.key
        }
    }
}
