// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("UsageAggregation")
struct UsageAggregationTests {
    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func event(
        id: String,
        hour: Int,
        minute: Int = 0,
        model: String = "claude-sonnet-5",
        project: String? = "/Users/dev/projects/demo-app",
        total: Int = 10
    ) -> UsageEvent {
        let timestamp = utcCalendar.date(from: DateComponents(
            year: 2026, month: 7, day: 1, hour: hour, minute: minute
        ))!
        return UsageEvent(
            id: id,
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: timestamp,
            model: model,
            project: project,
            tokens: TokenCounts(output: total)
        )
    }

    @Test("hourly bins group by hour and model")
    func hourlyBins() {
        let rows = UsageAggregation.timeBins(
            events: [
                event(id: "a", hour: 9, minute: 5, model: "claude-sonnet-5", total: 10),
                event(id: "b", hour: 9, minute: 45, model: "claude-sonnet-5", total: 20),
                event(id: "c", hour: 9, minute: 50, model: "claude-opus-4-8", total: 5),
                event(id: "d", hour: 11, minute: 0, model: "claude-sonnet-5", total: 40),
            ],
            component: .hour,
            calendar: utcCalendar
        )

        #expect(rows.count == 3)
        // Sorted by bin start, then model name.
        #expect(rows[0].model == "claude-opus-4-8")
        #expect(rows[0].tokens == 5)
        #expect(rows[1].model == "claude-sonnet-5")
        #expect(rows[1].tokens == 30)
        #expect(rows[2].tokens == 40)
        #expect(utcCalendar.component(.hour, from: rows[2].binStart) == 11)
    }

    @Test("daily bins collapse a whole day into one bin per model")
    func dailyBins() {
        let rows = UsageAggregation.timeBins(
            events: [
                event(id: "a", hour: 0, total: 1),
                event(id: "b", hour: 12, total: 2),
                event(id: "c", hour: 23, minute: 59, total: 4),
            ],
            component: .day,
            calendar: utcCalendar
        )
        #expect(rows.count == 1)
        #expect(rows[0].tokens == 7)
    }

    @Test("totals sort descending with nil keys grouped under the label")
    func categoryTotals() {
        let rows = UsageAggregation.totals(
            events: [
                event(id: "a", hour: 9, project: "/p/alpha", total: 10),
                event(id: "b", hour: 10, project: "/p/beta", total: 100),
                event(id: "c", hour: 11, project: "/p/alpha", total: 15),
                event(id: "d", hour: 12, project: nil, total: 3),
            ],
            nilLabel: "No project",
            key: \.project
        )

        #expect(rows.map(\.key) == ["/p/beta", "/p/alpha", "No project"])
        #expect(rows.map(\.tokens) == [100, 25, 3])
        #expect(rows.map(\.eventCount) == [1, 2, 1])
    }

    @Test("equal totals tie-break alphabetically for stable display")
    func stableTieBreak() {
        let rows = UsageAggregation.totals(
            events: [
                event(id: "a", hour: 9, model: "zeta", total: 10),
                event(id: "b", hour: 10, model: "alpha", total: 10),
            ],
            key: \.model
        )
        #expect(rows.map(\.key) == ["alpha", "zeta"])
    }
}
