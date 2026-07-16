// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("UsageSummary")
struct UsageSummaryTests {
    private func event(id: String, timestamp: Date, output: Int) -> UsageEvent {
        UsageEvent(
            id: id,
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: timestamp,
            model: "claude-sonnet-5",
            project: nil,
            tokens: TokenCounts(output: output)
        )
    }

    @Test("daily summary only counts events on the given day")
    func dayBoundary() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))

        let day = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 12)))
        let sameDayEarly = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 2, hour: 0, minute: 0, second: 1)))
        let dayBefore = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 1, hour: 23, minute: 59)))
        let dayAfter = try #require(calendar.date(from: DateComponents(year: 2026, month: 7, day: 3, hour: 0, minute: 1)))

        let summary = UsageSummary.daily(
            from: [
                event(id: "a", timestamp: sameDayEarly, output: 10),
                event(id: "b", timestamp: day, output: 20),
                event(id: "c", timestamp: dayBefore, output: 40),
                event(id: "d", timestamp: dayAfter, output: 80),
            ],
            on: day,
            calendar: calendar
        )

        #expect(summary.eventCount == 2)
        #expect(summary.tokens.output == 30)
        #expect(summary.lastEventAt == day)
        #expect(summary.hasData)
    }

    @Test("include accumulates tokens and tracks the latest timestamp")
    func include() {
        var summary = UsageSummary.empty
        let earlier = Date(timeIntervalSince1970: 1_000)
        let later = Date(timeIntervalSince1970: 2_000)

        summary.include(event(id: "x", timestamp: later, output: 5))
        summary.include(event(id: "y", timestamp: earlier, output: 7))

        #expect(summary.eventCount == 2)
        #expect(summary.tokens.output == 12)
        #expect(summary.lastEventAt == later) // out-of-order arrival handled
        #expect(summary.estimatedCostUSD == nil) // no fabricated costs
    }
}
