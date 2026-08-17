// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Aggregated usage for one display window (e.g. "today"). This is what the
/// menu-bar header and summary tiles render.
///
/// `estimatedCostUSD` is filled in by the cost engine; `nil` means nothing
/// could be priced — the UI renders a placeholder ("—"), never a fabricated
/// number.
struct UsageSummary: Sendable, Equatable {
    var tokens = TokenCounts()
    var estimatedCostUSD: Decimal?
    var eventCount = 0
    var lastEventAt: Date?

    static let empty = UsageSummary()

    var hasData: Bool { eventCount > 0 }

    /// Folds one event into the summary (no date filtering — callers decide
    /// membership).
    mutating func include(_ event: UsageEvent) {
        tokens += event.tokens
        eventCount += 1
        if lastEventAt.map({ event.timestamp > $0 }) ?? true {
            lastEventAt = event.timestamp
        }
    }

    /// Sums the events that fall on the same calendar day as `day`.
    /// Cost is left `nil` here; the cost engine fills it in.
    static func daily(
        from events: [UsageEvent],
        on day: Date = .now,
        calendar: Calendar = .current
    ) -> UsageSummary {
        var summary = UsageSummary()
        for event in events where calendar.isDate(event.timestamp, inSameDayAs: day) {
            summary.include(event)
        }
        return summary
    }
}
