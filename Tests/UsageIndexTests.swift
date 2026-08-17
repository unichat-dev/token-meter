// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("UsageIndex")
struct UsageIndexTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(iso)
    }

    private let resolver = ResolvedPricing(base: [
        "claude-opus-5": ModelPricing(
            inputPerMTok: 5, outputPerMTok: 25,
            cacheReadPerMTok: Decimal(string: "0.5")!,
            cacheWritePerMTok: Decimal(string: "6.25")!,
            cacheWrite1hPerMTok: 10,
            webSearchPerRequest: Decimal(string: "0.01")!
        ),
        "claude-sonnet-5": ModelPricing(
            inputPerMTok: 2, outputPerMTok: 10,
            cacheReadPerMTok: Decimal(string: "0.2")!,
            cacheWritePerMTok: Decimal(string: "2.5")!
        ),
    ])

    /// Deterministic spread of events with varied tiers, models and providers.
    private func sampleEvents(_ count: Int) -> [UsageEvent] {
        let base = date("2026-08-01T00:30:00Z")
        return (0..<count).map { index in
            let isLocal = index % 11 == 0
            return UsageEvent(
                id: "e\(index)",
                provider: isLocal ? .ollama : .claudeCode,
                accuracy: isLocal ? .measured : .estimated,
                timestamp: base.addingTimeInterval(Double(index) * 3_600),
                model: isLocal
                    ? "llama3.2:3b"
                    : (index % 3 == 0 ? "claude-sonnet-5" : "claude-opus-5"),
                project: "/Users/dev/p\(index % 4)",
                tokens: TokenCounts(
                    input: index % 7,
                    output: 100 + index,
                    cacheRead: 1_000 * index,
                    cacheCreation: 500 + index,
                    cacheCreation5m: (500 + index) / 4,
                    cacheCreation1h: (500 + index) - (500 + index) / 4
                ),
                serverToolUse: ServerToolUse(
                    webSearchRequests: index % 5, webFetchRequests: index % 3
                )
            )
        }
    }

    private func buildIndex(_ events: [UsageEvent]) -> UsageIndex {
        var index = UsageIndex()
        for event in events { index.insert(event, calendar: calendar) }
        return index
    }

    // MARK: - Equivalence with the per-event path
    //
    // These are the tests that matter: aggregating before pricing is only valid
    // because cost is linear, and if that ever stops holding the numbers must
    // fail loudly here rather than drift silently in the UI.

    @Test("indexed cost equals per-event cost exactly, to the last Decimal")
    func costEquivalence() {
        let events = sampleEvents(500)
        let index = buildIndex(events)

        let perEvent = CostEngine.totals(for: events, resolver: resolver)
        let indexed = CostEngine.totals(for: index.aggregateAll(), resolver: resolver)

        #expect(indexed.cost == perEvent.cost)
        #expect(indexed.pricedEventCount == perEvent.pricedEventCount)
        #expect(indexed.unpricedModels == perEvent.unpricedModels)
    }

    @Test("indexed daily totals equal the old daily rollup")
    func dailyEquivalence() {
        let events = sampleEvents(300)
        let index = buildIndex(events)
        let day = date("2026-08-03T12:00:00Z")

        let metered = events.filter { $0.provider.isMetered }
        let old = UsageSummary.daily(from: metered, on: day, calendar: calendar)
        let new = index.aggregate(on: day, calendar: calendar).summary

        #expect(new.tokens == old.tokens)
        #expect(new.eventCount == old.eventCount)
        #expect(new.lastEventAt == old.lastEventAt)
    }

    @Test("indexed weekly totals equal the old weekly rollup")
    func weeklyEquivalence() throws {
        let events = sampleEvents(400)
        let index = buildIndex(events)
        let now = date("2026-08-10T12:00:00Z")

        let metered = events.filter { $0.provider.isMetered }
        let old = UsageRollups.weekly(from: metered, containing: now, calendar: calendar)
        let week = try #require(calendar.dateInterval(of: .weekOfYear, for: now))
        let new = index.aggregate(in: week).summary

        #expect(new.tokens == old.tokens)
        #expect(new.eventCount == old.eventCount)
    }

    @Test("indexed billing-period cost equals the per-event PlanValue")
    func planValueEquivalence() {
        let events = sampleEvents(400)
        let index = buildIndex(events)
        let now = date("2026-08-20T12:00:00Z")

        let metered = events.filter { $0.provider.isMetered }
        let old = PlanValue.make(
            plan: .claudePro, monthlyPriceUSD: 20, events: metered, now: now,
            cycleStartDay: 1, resolver: resolver,
            earliestHistoryAt: nil, calendar: calendar
        )
        let period = BillingPeriod.current(containing: now, cycleStartDay: 1, calendar: calendar)
        let indexed = CostEngine.totals(for: index.aggregate(in: period), resolver: resolver)

        #expect(indexed.cost == old.observedCostUSD)
        #expect(index.aggregate(in: period).eventCount == old.eventCount)
    }

    // MARK: - Bucketing

    @Test("events land in the calendar day they belong to")
    func dayBucketing() {
        var index = UsageIndex()
        let a = sampleEvents(1)[0]
        index.insert(a, calendar: calendar)
        #expect(index.days.count == 1)
        #expect(index.days[calendar.startOfDay(for: a.timestamp)] != nil)
    }

    @Test("local models are held apart from metered cost")
    func ollamaSeparated() {
        let local = UsageEvent(
            id: "local", provider: .ollama, accuracy: .measured,
            timestamp: date("2026-08-05T10:00:00Z"),
            model: "llama3.2:3b", project: nil,
            tokens: TokenCounts(input: 1_000_000, output: 1_000_000)
        )
        let index = buildIndex([local])
        let aggregate = index.aggregateAll()

        #expect(aggregate.ollamaTokens == 2_000_000)
        #expect(aggregate.eventCount == 0)      // metered count only
        #expect(aggregate.byModel.isEmpty)      // never priced
        #expect(CostEngine.totals(for: aggregate, resolver: resolver).cost == 0)
        // Crucially, a local model must not surface as a pricing gap.
        #expect(CostEngine.totals(for: aggregate, resolver: resolver).unpricedModels.isEmpty)
    }

    @Test("unpriced metered models are reported")
    func unpricedReported() {
        let mystery = UsageEvent(
            id: "m", provider: .claudeCode, accuracy: .estimated,
            timestamp: date("2026-08-05T10:00:00Z"),
            model: "mystery-model", project: nil,
            tokens: TokenCounts(output: 500)
        )
        let index = buildIndex([mystery])
        #expect(index.meteredModels == ["mystery-model"])
        #expect(CostEngine.totals(
            for: index.aggregateAll(), resolver: resolver
        ).unpricedModels == ["mystery-model"])
    }

    // MARK: - Removal (the re-scan refresh path)

    @Test("insert then remove returns the index to empty")
    func removeRestoresEmpty() {
        let events = sampleEvents(50)
        var index = buildIndex(events)
        for event in events { index.remove(event, calendar: calendar) }
        #expect(index.days.isEmpty)
        #expect(index.aggregateAll().tokens == TokenCounts())
    }

    @Test("superseding an event updates totals without a rebuild")
    func supersedeUpdatesTotals() {
        let original = UsageEvent(
            id: "e", provider: .claudeCode, accuracy: .estimated,
            timestamp: date("2026-08-05T10:00:00Z"),
            model: "claude-opus-5", project: nil,
            // Pre-fix shape: flat cache total, no TTL split.
            tokens: TokenCounts(cacheCreation: 1_000_000)
        )
        // Post-fix re-parse of the same log line, now with the 1h tier.
        let refreshed = UsageEvent(
            id: "e", provider: .claudeCode, accuracy: .estimated,
            timestamp: original.timestamp,
            model: "claude-opus-5", project: nil,
            tokens: TokenCounts(
                cacheCreation: 1_000_000,
                cacheCreation5m: 0,
                cacheCreation1h: 1_000_000
            )
        )

        var index = buildIndex([original])
        let before = CostEngine.totals(for: index.aggregateAll(), resolver: resolver).cost
        index.remove(original, calendar: calendar)
        index.insert(refreshed, calendar: calendar)
        let after = CostEngine.totals(for: index.aggregateAll(), resolver: resolver).cost

        #expect(before == Decimal(string: "6.25")!)   // 1M at the 5-minute rate
        #expect(after == 10)                          // 1M at the 1-hour rate
        #expect(index.aggregateAll().eventCount == 1) // not double-counted
    }

    @Test("removing the last event of a model drops the model entirely")
    func modelPrunedWhenEmpty() {
        let event = sampleEvents(1)[0]
        var index = buildIndex([event])
        index.remove(event, calendar: calendar)
        #expect(index.meteredModels.isEmpty)
    }

    @Test("removing an event that was never inserted is a no-op")
    func removeUnknownIsSafe() {
        var index = UsageIndex()
        index.remove(sampleEvents(1)[0], calendar: calendar)
        #expect(index.days.isEmpty)
    }

    // MARK: - Range queries

    @Test("aggregating a range covers exactly the days inside it")
    func rangeBoundaries() {
        let events = sampleEvents(200)
        let index = buildIndex(events)
        let interval = DateInterval(
            start: date("2026-08-03T00:00:00Z"),
            end: date("2026-08-05T00:00:00Z")
        )
        let aggregate = index.aggregate(in: interval)

        let expected = events.filter {
            $0.provider.isMetered
                && $0.timestamp >= interval.start
                && $0.timestamp < interval.end
        }
        #expect(aggregate.eventCount == expected.count)
        #expect(CostEngine.totals(for: aggregate, resolver: resolver).cost
            == CostEngine.totals(for: expected, resolver: resolver).cost)
    }

    @Test("an empty range aggregates to zero, not to everything")
    func emptyRange() {
        let index = buildIndex(sampleEvents(100))
        let aggregate = index.aggregate(in: DateInterval(
            start: date("2027-01-01T00:00:00Z"),
            end: date("2027-02-01T00:00:00Z")
        ))
        #expect(aggregate.eventCount == 0)
        #expect(aggregate.tokens == TokenCounts())
    }
}
