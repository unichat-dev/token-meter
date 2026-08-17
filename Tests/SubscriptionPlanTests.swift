// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("SubscriptionPlan & PlanValue")
struct SubscriptionPlanTests {
    /// Fixed UTC calendar so period boundaries don't move with the test machine.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(iso)
    }

    private func event(
        id: String,
        at iso: String,
        model: String = "claude-opus-5",
        tokens: TokenCounts = TokenCounts(input: 1_000_000)
    ) -> UsageEvent {
        UsageEvent(
            id: id,
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: date(iso),
            model: model,
            project: nil,
            tokens: tokens
        )
    }

    private let resolver = ResolvedPricing(base: [
        "claude-opus-5": ModelPricing(inputPerMTok: 5, outputPerMTok: 25)
    ])

    // MARK: - Billing period

    @Test("period starting on the 1st is the calendar month")
    func calendarMonthPeriod() {
        let period = BillingPeriod.current(
            containing: date("2026-08-17T12:00:00Z"), cycleStartDay: 1, calendar: calendar
        )
        #expect(period.start == date("2026-08-01T00:00:00Z"))
        #expect(period.end == date("2026-09-01T00:00:00Z"))
    }

    @Test("before the cycle day, the period began last month")
    func periodSpansMonthBoundary() {
        let period = BillingPeriod.current(
            containing: date("2026-08-03T09:00:00Z"), cycleStartDay: 12, calendar: calendar
        )
        #expect(period.start == date("2026-07-12T00:00:00Z"))
        #expect(period.end == date("2026-08-12T00:00:00Z"))
    }

    @Test("on the cycle day itself the new period has already started")
    func cycleDayBoundaryIsInclusive() {
        let period = BillingPeriod.current(
            containing: date("2026-08-12T00:30:00Z"), cycleStartDay: 12, calendar: calendar
        )
        #expect(period.start == date("2026-08-12T00:00:00Z"))
    }

    @Test("cycle day is clamped so February always has it")
    func februaryClamping() {
        // Day 31 clamps to 28. On Feb 20 we're before the 28th, so the period
        // is the one that opened on Jan 28.
        let period = BillingPeriod.current(
            containing: date("2026-02-20T12:00:00Z"), cycleStartDay: 31, calendar: calendar
        )
        #expect(period.start == date("2026-01-28T00:00:00Z"))
        #expect(period.end == date("2026-02-28T00:00:00Z"))
    }

    @Test("an out-of-range cycle day never yields an empty period")
    func invalidCycleDayIsSafe() {
        for day in [-5, 0, 29, 99] {
            let period = BillingPeriod.current(
                containing: date("2026-08-17T12:00:00Z"), cycleStartDay: day, calendar: calendar
            )
            #expect(period.duration > 0, "cycleStartDay \(day) produced an empty period")
            #expect(period.contains(date("2026-08-17T12:00:00Z")))
        }
    }

    @Test("a January period rolls back into the previous year")
    func yearBoundary() {
        let period = BillingPeriod.current(
            containing: date("2026-01-05T12:00:00Z"), cycleStartDay: 15, calendar: calendar
        )
        #expect(period.start == date("2025-12-15T00:00:00Z"))
        #expect(period.end == date("2026-01-15T00:00:00Z"))
    }

    // MARK: - Value

    @Test("value multiple divides observed usage by the plan fee")
    func valueMultiple() {
        // 20 events × 1M input × $5/MTok = $100 of usage on a $20 plan.
        let events = (0..<20).map { event(id: "e\($0)", at: "2026-08-10T12:00:00Z") }
        let value = PlanValue.make(
            plan: .claudePro,
            monthlyPriceUSD: 20,
            events: events,
            now: date("2026-08-17T12:00:00Z"),
            cycleStartDay: 1,
            resolver: resolver,
            earliestHistoryAt: date("2026-07-01T00:00:00Z"),
            calendar: calendar
        )

        #expect(value.observedCostUSD == 100)
        #expect(value.valueMultiple == 5)
        #expect(value.netUSD == 80)
        #expect(value.hasBrokenEven)
        #expect(value.eventCount == 20)
        #expect(!value.isPartialPeriod)
    }

    @Test("events outside the period are excluded")
    func periodFiltering() {
        let events = [
            event(id: "before", at: "2026-07-31T23:00:00Z"),
            event(id: "inside", at: "2026-08-05T10:00:00Z"),
            event(id: "after", at: "2026-09-01T00:30:00Z"),
        ]
        let value = PlanValue.make(
            plan: .claudePro,
            monthlyPriceUSD: 20,
            events: events,
            now: date("2026-08-17T12:00:00Z"),
            cycleStartDay: 1,
            resolver: resolver,
            earliestHistoryAt: date("2026-07-01T00:00:00Z"),
            calendar: calendar
        )
        #expect(value.eventCount == 1)
        #expect(value.observedCostUSD == 5)
    }

    @Test("history starting mid-period is flagged as partial")
    func partialPeriodFlagged() {
        let value = PlanValue.make(
            plan: .claudeMax5,
            monthlyPriceUSD: 100,
            events: [event(id: "a", at: "2026-08-10T12:00:00Z")],
            now: date("2026-08-17T12:00:00Z"),
            cycleStartDay: 1,
            resolver: resolver,
            earliestHistoryAt: date("2026-08-09T00:00:00Z"), // after period start
            calendar: calendar
        )
        #expect(value.isPartialPeriod)
        #expect(PlanValueFormat.caveat(for: value).contains("higher"))
    }

    @Test("unpriced models are surfaced, not silently swallowed")
    func unpricedSurfaced() {
        let value = PlanValue.make(
            plan: .claudePro,
            monthlyPriceUSD: 20,
            events: [
                event(id: "a", at: "2026-08-10T12:00:00Z"),
                event(id: "b", at: "2026-08-10T13:00:00Z", model: "mystery-model"),
            ],
            now: date("2026-08-17T12:00:00Z"),
            cycleStartDay: 1,
            resolver: resolver,
            earliestHistoryAt: date("2026-07-01T00:00:00Z"),
            calendar: calendar
        )
        #expect(value.unpricedModels == ["mystery-model"])
        #expect(PlanValueFormat.caveat(for: value).contains("mystery-model"))
    }

    @Test("local Ollama usage never inflates the plan comparison")
    func ollamaExcluded() {
        let local = UsageEvent(
            id: "local",
            provider: .ollama,
            accuracy: .measured,
            timestamp: date("2026-08-10T12:00:00Z"),
            model: "llama3.2:3b",
            project: nil,
            tokens: TokenCounts(input: 9_000_000)
        )
        let value = PlanValue.make(
            plan: .claudePro,
            monthlyPriceUSD: 20,
            events: [local],
            now: date("2026-08-17T12:00:00Z"),
            cycleStartDay: 1,
            resolver: resolver,
            earliestHistoryAt: date("2026-07-01T00:00:00Z"),
            calendar: calendar
        )
        #expect(value.eventCount == 0)
        #expect(value.observedCostUSD == 0)
    }

    @Test("pay-as-you-go and unset show no multiple — there's no fee to beat")
    func noComparisonForMeteredBilling() {
        for plan in [SubscriptionPlan.payAsYouGo, .unset] {
            let value = PlanValue.make(
                plan: plan,
                monthlyPriceUSD: 0,
                events: [event(id: "a", at: "2026-08-10T12:00:00Z")],
                now: date("2026-08-17T12:00:00Z"),
                cycleStartDay: 1,
                resolver: resolver,
                earliestHistoryAt: nil,
                calendar: calendar
            )
            #expect(value.valueMultiple == nil)
            #expect(value.netUSD == nil)
            #expect(!plan.showsValueComparison)
        }
    }

    @Test("a zero price never divides by zero")
    func zeroPriceIsSafe() {
        let value = PlanValue.make(
            plan: .custom,
            monthlyPriceUSD: 0,
            events: [event(id: "a", at: "2026-08-10T12:00:00Z")],
            now: date("2026-08-17T12:00:00Z"),
            cycleStartDay: 1,
            resolver: resolver,
            earliestHistoryAt: nil,
            calendar: calendar
        )
        #expect(value.valueMultiple == nil)
    }

    // MARK: - Presets & formatting

    @Test("presets carry the expected list prices")
    func presetPrices() {
        #expect(SubscriptionPlan.claudePro.defaultMonthlyPriceUSD == 20)
        #expect(SubscriptionPlan.claudeMax5.defaultMonthlyPriceUSD == 100)
        #expect(SubscriptionPlan.claudeMax20.defaultMonthlyPriceUSD == 200)
        #expect(SubscriptionPlan.payAsYouGo.defaultMonthlyPriceUSD == nil)
        #expect(SubscriptionPlan.unset.defaultMonthlyPriceUSD == nil)
    }

    /// Pinned to en_US: the separator is locale-dependent by design, so
    /// asserting against the machine's locale would fail on, say, a Turkish or
    /// German Mac for a formatter that is behaving correctly.
    @Test("multiple formats coarsely when large, finely when small")
    func multipleFormatting() {
        let us = Locale(identifier: "en_US")
        #expect(PlanValueFormat.multiple(126, locale: us) == "126×")
        #expect(PlanValueFormat.multiple(Decimal(string: "2.5")!, locale: us) == "2.5×")
        // Rounds to whole numbers only once it's past the readable threshold.
        #expect(PlanValueFormat.multiple(Decimal(string: "9.94")!, locale: us) == "9.9×")

        let de = Locale(identifier: "de_DE")
        #expect(PlanValueFormat.multiple(Decimal(string: "2.5")!, locale: de) == "2,5×")
    }

    @Test("the caveat never claims the number is a bill or a refund")
    func caveatStaysHonest() {
        let value = PlanValue.make(
            plan: .claudePro,
            monthlyPriceUSD: 20,
            events: [event(id: "a", at: "2026-08-10T12:00:00Z")],
            now: date("2026-08-17T12:00:00Z"),
            cycleStartDay: 1,
            resolver: resolver,
            earliestHistoryAt: date("2026-07-01T00:00:00Z"),
            calendar: calendar
        )
        let caveat = PlanValueFormat.caveat(for: value)
        #expect(caveat.contains("Estimated"))
        #expect(caveat.contains("not a bill"))
    }
}
