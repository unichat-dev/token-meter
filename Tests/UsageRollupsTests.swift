// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("UsageRollups")
struct UsageRollupsTests {
    // MARK: - Helpers

    private func event(id: String, at timestamp: Date, output: Int = 10) -> UsageEvent {
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

    /// UTC date builder.
    private func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0, _ second: Int = 0) throws -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        return try #require(calendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour, minute: minute, second: second
        )))
    }

    // MARK: - Block boundaries

    @Test("block start floors to the full UTC hour")
    func blockStartFlooring() throws {
        let first = try utc(2026, 7, 1, 9, 58, 12)
        let blocks = UsageRollups.blocks(from: [event(id: "a", at: first)])

        #expect(blocks.count == 1)
        #expect(blocks[0].start == (try utc(2026, 7, 1, 9)))
        #expect(blocks[0].end == (try utc(2026, 7, 1, 14)))
    }

    @Test("events within five hours of block start share the block")
    func sameBlockGrouping() throws {
        let events = [
            event(id: "a", at: try utc(2026, 7, 1, 9, 58), output: 10),
            event(id: "b", at: try utc(2026, 7, 1, 10, 31), output: 20),
            event(id: "c", at: try utc(2026, 7, 1, 13, 59, 59), output: 40),
        ]
        let blocks = UsageRollups.blocks(from: events)

        #expect(blocks.count == 1)
        #expect(blocks[0].eventCount == 3)
        #expect(blocks[0].tokens.output == 70)
    }

    @Test("an event at exactly block end starts the next block")
    func boundaryIsExclusive() throws {
        let events = [
            event(id: "a", at: try utc(2026, 7, 1, 9, 0)),
            event(id: "b", at: try utc(2026, 7, 1, 14, 0)), // == end of 09:00 block
        ]
        let blocks = UsageRollups.blocks(from: events)

        #expect(blocks.count == 2)
        #expect(blocks[1].start == (try utc(2026, 7, 1, 14)))
        #expect(blocks[1].end == (try utc(2026, 7, 1, 19)))
    }

    @Test("a gap after block end starts a fresh block floored to its own hour")
    func gapStartsFreshBlock() throws {
        let events = [
            event(id: "a", at: try utc(2026, 7, 1, 9, 58)),
            event(id: "b", at: try utc(2026, 7, 1, 15, 12, 44)), // block 1 ended 14:00
        ]
        let blocks = UsageRollups.blocks(from: events)

        #expect(blocks.count == 2)
        #expect(blocks[1].start == (try utc(2026, 7, 1, 15)))
    }

    @Test("unsorted input produces the same blocks as sorted input")
    func sortsInternally() throws {
        let sorted = [
            event(id: "a", at: try utc(2026, 7, 1, 9, 0)),
            event(id: "b", at: try utc(2026, 7, 1, 10, 0)),
            event(id: "c", at: try utc(2026, 7, 1, 16, 0)),
        ]
        #expect(UsageRollups.blocks(from: sorted) == UsageRollups.blocks(from: sorted.reversed()))
    }

    // MARK: - Active block & peak

    @Test("active block is returned only while now is inside it")
    func activeBlock() throws {
        let blocks = UsageRollups.blocks(from: [event(id: "a", at: try utc(2026, 7, 1, 9, 30))])

        let during = try utc(2026, 7, 1, 13, 59)
        let after = try utc(2026, 7, 1, 14, 0)
        #expect(UsageRollups.activeBlock(in: blocks, now: during) != nil)
        #expect(UsageRollups.activeBlock(in: blocks, now: after) == nil)
        #expect(UsageRollups.activeBlock(in: [], now: during) == nil)
    }

    @Test("peak excludes the active block")
    func peakExcludesActive() throws {
        let events = [
            event(id: "a", at: try utc(2026, 7, 1, 9, 0), output: 100), // completed
            event(id: "b", at: try utc(2026, 7, 2, 9, 0), output: 999), // active
        ]
        let blocks = UsageRollups.blocks(from: events)
        let now = try utc(2026, 7, 2, 9, 30)

        #expect(UsageRollups.peakBlockTokens(in: blocks, now: now) == 100)
        // Once the big block completes, it becomes the peak.
        let later = try utc(2026, 7, 2, 20, 0)
        #expect(UsageRollups.peakBlockTokens(in: blocks, now: later) == 999)
    }

    // MARK: - DST / timezone edge cases

    @Test("block duration is exactly 5 wall-clock hours across a DST spring-forward")
    func blockAcrossSpringForward() throws {
        // US DST 2026: clocks jump 02:00 → 03:00 on March 8 (America/New_York,
        // UTC-5 → UTC-4). 06:30 UTC = 01:30 EST, mid-jump locally.
        let first = try utc(2026, 3, 8, 6, 30)
        let blocks = UsageRollups.blocks(from: [event(id: "a", at: first)])

        #expect(blocks[0].end.timeIntervalSince(blocks[0].start) == 5 * 3600)
        #expect(blocks[0].start == (try utc(2026, 3, 8, 6)))
        #expect(blocks[0].end == (try utc(2026, 3, 8, 11)))
    }

    @Test("daily aggregation respects the local calendar day, DST included")
    func dailyOnDSTDay() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))

        // March 8 2026 is a 23-hour day in New York.
        let beforeJump = try utc(2026, 3, 8, 6, 30)   // 01:30 EST Mar 8
        let afterJump = try utc(2026, 3, 8, 7, 30)    // 03:30 EDT Mar 8
        let nextDayUTCsameLocalDay = try utc(2026, 3, 9, 3, 0) // 23:00 EDT Mar 8 (!)
        let trulyNextDay = try utc(2026, 3, 9, 5, 0)  // 01:00 EDT Mar 9

        let summary = UsageSummary.daily(
            from: [
                event(id: "a", at: beforeJump, output: 1),
                event(id: "b", at: afterJump, output: 2),
                event(id: "c", at: nextDayUTCsameLocalDay, output: 4),
                event(id: "d", at: trulyNextDay, output: 8),
            ],
            on: beforeJump,
            calendar: newYork
        )

        // a, b, c are all "March 8" in New York even though c is March 9 UTC.
        #expect(summary.eventCount == 3)
        #expect(summary.tokens.output == 7)
    }

    // MARK: - Weekly aggregation

    @Test("weekly aggregation uses the calendar's week boundaries and timezone")
    func weeklyBoundaries() throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        newYork.firstWeekday = 1 // Sunday, US default

        // Week of Sunday 2026-07-05 … Saturday 2026-07-11 (New York).
        let saturdayNight = try utc(2026, 7, 5, 3, 59)   // Sat Jul 4, 23:59 EDT — previous week
        let sundayMorning = try utc(2026, 7, 5, 4, 1)    // Sun Jul 5, 00:01 EDT — this week
        let midWeek = try utc(2026, 7, 8, 12, 0)
        let nextSunday = try utc(2026, 7, 12, 4, 1)      // Sun Jul 12, 00:01 EDT — next week

        let summary = UsageRollups.weekly(
            from: [
                event(id: "a", at: saturdayNight, output: 1),
                event(id: "b", at: sundayMorning, output: 2),
                event(id: "c", at: midWeek, output: 4),
                event(id: "d", at: nextSunday, output: 8),
            ],
            containing: midWeek,
            calendar: newYork
        )

        #expect(summary.eventCount == 2)
        #expect(summary.tokens.output == 6)
    }

    @Test("weekly respects a Monday-first calendar")
    func weeklyMondayFirst() throws {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        utcCalendar.firstWeekday = 2 // Monday (ISO / most of Europe)

        // 2026-07-05 is a Sunday: Monday-first week runs Jun 29 … Jul 5.
        let sunday = try utc(2026, 7, 5, 12, 0)
        let monday = try utc(2026, 7, 6, 0, 1)

        let sundayWeek = UsageRollups.weekly(
            from: [event(id: "a", at: sunday, output: 1), event(id: "b", at: monday, output: 2)],
            containing: sunday,
            calendar: utcCalendar
        )
        #expect(sundayWeek.tokens.output == 1) // Monday belongs to the next week
    }
}
