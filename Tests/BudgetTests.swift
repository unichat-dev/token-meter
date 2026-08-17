// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("Budgets & alerts")
struct BudgetTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        try! Date.ISO8601FormatStyle().parse(iso)
    }

    private func daily(_ limit: Decimal) -> Budget {
        Budget(scope: .daily, isEnabled: true, limit: limit)
    }

    // MARK: - Threshold crossing

    @Test("no alert below the first threshold")
    func belowFirstThreshold() {
        var ledger = BudgetAlertLedger()
        let alert = BudgetEvaluator.evaluate(
            budget: daily(100), used: 40, limit: 100, windowKey: "d", ledger: &ledger
        )
        #expect(alert == nil)
        #expect(ledger.isEmpty)
    }

    @Test("crossing 50% fires once and only once")
    func firesOnceAtFifty() {
        var ledger = BudgetAlertLedger()
        let first = BudgetEvaluator.evaluate(
            budget: daily(100), used: 55, limit: 100, windowKey: "d", ledger: &ledger
        )
        #expect(first?.threshold == 50)

        // Same window, more usage but still under 80 — must stay silent.
        let second = BudgetEvaluator.evaluate(
            budget: daily(100), used: 70, limit: 100, windowKey: "d", ledger: &ledger
        )
        #expect(second == nil)
    }

    @Test("a jump past several thresholds fires only the highest")
    func noBurstOnJump() {
        var ledger = BudgetAlertLedger()
        // 0% → 90% in one tick. The user should get one 80% alert, not 50+80.
        let alert = BudgetEvaluator.evaluate(
            budget: daily(100), used: 90, limit: 100, windowKey: "d", ledger: &ledger
        )
        #expect(alert?.threshold == 80)
        #expect(ledger.hasFired(50, scope: .daily, windowKey: "d"))
        #expect(ledger.hasFired(80, scope: .daily, windowKey: "d"))
        #expect(!ledger.hasFired(100, scope: .daily, windowKey: "d"))
    }

    @Test("each threshold still fires as it is reached in turn")
    func laddersUpOneAtATime() {
        var ledger = BudgetAlertLedger()
        let budget = daily(100)
        var fired: [Int] = []
        for used in [Decimal(55), 85, 101] {
            if let alert = BudgetEvaluator.evaluate(
                budget: budget, used: used, limit: 100, windowKey: "d", ledger: &ledger
            ) {
                fired.append(alert.threshold)
            }
        }
        #expect(fired == [50, 80, 100])
    }

    @Test("exceeding the budget doesn't re-alert past 100%")
    func noRepeatAfterFull() {
        var ledger = BudgetAlertLedger()
        _ = BudgetEvaluator.evaluate(
            budget: daily(100), used: 100, limit: 100, windowKey: "d", ledger: &ledger
        )
        let again = BudgetEvaluator.evaluate(
            budget: daily(100), used: 500, limit: 100, windowKey: "d", ledger: &ledger
        )
        #expect(again == nil)
    }

    @Test("a new window starts with a clean slate")
    func newWindowResets() {
        var ledger = BudgetAlertLedger()
        _ = BudgetEvaluator.evaluate(
            budget: daily(100), used: 90, limit: 100, windowKey: "monday", ledger: &ledger
        )
        // Tomorrow: same budget, different window key.
        let tomorrow = BudgetEvaluator.evaluate(
            budget: daily(100), used: 90, limit: 100, windowKey: "tuesday", ledger: &ledger
        )
        #expect(tomorrow?.threshold == 80)
    }

    @Test("scopes don't share a ledger entry")
    func scopesAreIndependent() {
        var ledger = BudgetAlertLedger()
        _ = BudgetEvaluator.evaluate(
            budget: daily(100), used: 90, limit: 100, windowKey: "w", ledger: &ledger
        )
        let weekly = BudgetEvaluator.evaluate(
            budget: Budget(scope: .weekly, isEnabled: true, limit: 100),
            used: 90, limit: 100, windowKey: "w", ledger: &ledger
        )
        #expect(weekly?.threshold == 80)
    }

    // MARK: - Guards

    @Test("a disabled budget never alerts")
    func disabledIsSilent() {
        var ledger = BudgetAlertLedger()
        let alert = BudgetEvaluator.evaluate(
            budget: Budget(scope: .daily, isEnabled: false, limit: 100),
            used: 500, limit: 100, windowKey: "d", ledger: &ledger
        )
        #expect(alert == nil)
    }

    @Test("a zero or negative limit never divides by zero")
    func zeroLimitSafe() {
        var ledger = BudgetAlertLedger()
        #expect(BudgetEvaluator.evaluate(
            budget: daily(0), used: 500, limit: 0, windowKey: "d", ledger: &ledger
        ) == nil)
        #expect(BudgetEvaluator.evaluate(
            budget: daily(-5), used: 500, limit: -5, windowKey: "d", ledger: &ledger
        ) == nil)
    }

    @Test("zero usage never alerts, even against a tiny budget")
    func zeroUsageSilent() {
        var ledger = BudgetAlertLedger()
        #expect(BudgetEvaluator.evaluate(
            budget: daily(1), used: 0, limit: 1, windowKey: "d", ledger: &ledger
        ) == nil)
    }

    // MARK: - Ledger housekeeping

    @Test("pruning drops rolled-over windows but keeps active ones")
    func pruning() {
        var ledger = BudgetAlertLedger()
        _ = BudgetEvaluator.evaluate(
            budget: daily(100), used: 90, limit: 100, windowKey: "old", ledger: &ledger
        )
        _ = BudgetEvaluator.evaluate(
            budget: Budget(scope: .weekly, isEnabled: true, limit: 100),
            used: 90, limit: 100, windowKey: "current", ledger: &ledger
        )

        ledger.prune(keeping: [BudgetAlertLedger.activeKey(.weekly, "current")])

        #expect(!ledger.hasFired(80, scope: .daily, windowKey: "old"))
        #expect(ledger.hasFired(80, scope: .weekly, windowKey: "current"))
    }

    @Test("ledger survives a JSON round-trip so relaunch doesn't replay alerts")
    func ledgerCodable() throws {
        var ledger = BudgetAlertLedger()
        _ = BudgetEvaluator.evaluate(
            budget: daily(100), used: 90, limit: 100, windowKey: "d", ledger: &ledger
        )

        let data = try JSONEncoder().encode(ledger)
        let restored = try JSONDecoder().decode(BudgetAlertLedger.self, from: data)

        #expect(restored == ledger)
        #expect(restored.hasFired(80, scope: .daily, windowKey: "d"))
    }

    @Test("budgets survive a JSON round-trip")
    func budgetsCodable() throws {
        let budgets = [daily(50), Budget(scope: .block, isEnabled: true)]
        let data = try JSONEncoder().encode(budgets)
        #expect(try JSONDecoder().decode([Budget].self, from: data) == budgets)
    }

    // MARK: - Window keys

    @Test("the daily key changes at the day boundary")
    func dailyWindowKey() {
        let monday = BudgetEvaluator.windowKey(
            for: .daily, now: date("2026-08-17T23:00:00Z"),
            blockStart: nil, billingPeriodStart: nil, calendar: calendar
        )
        let tuesday = BudgetEvaluator.windowKey(
            for: .daily, now: date("2026-08-18T01:00:00Z"),
            blockStart: nil, billingPeriodStart: nil, calendar: calendar
        )
        #expect(monday != tuesday)
    }

    @Test("the weekly key is stable within a week")
    func weeklyWindowKey() {
        let early = BudgetEvaluator.windowKey(
            for: .weekly, now: date("2026-08-17T09:00:00Z"),
            blockStart: nil, billingPeriodStart: nil, calendar: calendar
        )
        let later = BudgetEvaluator.windowKey(
            for: .weekly, now: date("2026-08-19T09:00:00Z"),
            blockStart: nil, billingPeriodStart: nil, calendar: calendar
        )
        #expect(early == later)
    }

    @Test("the block key follows the block, not the clock")
    func blockWindowKey() {
        let first = BudgetEvaluator.windowKey(
            for: .block, now: date("2026-08-17T09:00:00Z"),
            blockStart: date("2026-08-17T08:00:00Z"),
            billingPeriodStart: nil, calendar: calendar
        )
        let sameBlock = BudgetEvaluator.windowKey(
            for: .block, now: date("2026-08-17T12:00:00Z"),
            blockStart: date("2026-08-17T08:00:00Z"),
            billingPeriodStart: nil, calendar: calendar
        )
        let nextBlock = BudgetEvaluator.windowKey(
            for: .block, now: date("2026-08-17T14:00:00Z"),
            blockStart: date("2026-08-17T13:00:00Z"),
            billingPeriodStart: nil, calendar: calendar
        )
        #expect(first == sameBlock)
        #expect(first != nextBlock)
    }

    @Test("scopes with no active window yield no key rather than a fake one")
    func missingWindowKeys() {
        #expect(BudgetEvaluator.windowKey(
            for: .block, now: date("2026-08-17T09:00:00Z"),
            blockStart: nil, billingPeriodStart: nil, calendar: calendar
        ) == nil)
        #expect(BudgetEvaluator.windowKey(
            for: .billingPeriod, now: date("2026-08-17T09:00:00Z"),
            blockStart: nil, billingPeriodStart: nil, calendar: calendar
        ) == nil)
    }

    // MARK: - Copy (honesty guardrail)

    @Test("alert copy never implies a vendor quota")
    func copyStaysHonest() {
        let alert = BudgetAlert(
            scope: .daily, threshold: 80, used: 40, limit: 50, unit: .usd
        )
        let text = alert.title + " " + alert.body
        #expect(alert.body.contains("Estimated"))
        #expect(alert.body.contains("not a bill"))
        // The words that would turn an estimate into a promise.
        for forbidden in ["remaining", "left", "quota left", "allowance"] {
            #expect(!text.lowercased().contains(forbidden), "copy must not say \"\(forbidden)\"")
        }
    }

    @Test("reaching 100% reads as reached, not as exceeded quota")
    func fullBudgetCopy() {
        let alert = BudgetAlert(
            scope: .billingPeriod, threshold: 100, used: 200, limit: 200, unit: .usd
        )
        #expect(alert.title.contains("budget reached"))
    }

    @Test("block budgets are formatted in tokens, cost budgets in dollars")
    func unitFormatting() {
        #expect(BudgetScope.block.unit == .tokens)
        #expect(BudgetScope.daily.unit == .usd)
        #expect(BudgetScope.weekly.unit == .usd)
        #expect(BudgetScope.billingPeriod.unit == .usd)

        let blockAlert = BudgetAlert(
            scope: .block, threshold: 80, used: 1_200_000, limit: 1_500_000, unit: .tokens
        )
        #expect(blockAlert.body.contains("tokens"))
        #expect(!blockAlert.body.contains("$"))
    }

    @Test("scope raw values are pinned — they persist in UserDefaults")
    func scopeRawValues() {
        #expect(BudgetScope.block.rawValue == "block")
        #expect(BudgetScope.daily.rawValue == "daily")
        #expect(BudgetScope.weekly.rawValue == "weekly")
        #expect(BudgetScope.billingPeriod.rawValue == "billingPeriod")
    }
}
