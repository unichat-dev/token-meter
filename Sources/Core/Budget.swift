// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A usage window a budget can be set against.
///
/// Honesty guardrail: every one of these is reconstructed from local logs.
/// A budget is **the user's own ceiling**, never a vendor quota — nothing here
/// may be phrased as "remaining allowance".
enum BudgetScope: String, CaseIterable, Sendable, Codable, Identifiable {
    /// The reconstructed 5-hour block, measured in tokens.
    case block
    /// Today, measured in estimated USD.
    case daily
    /// The calendar week, in estimated USD.
    case weekly
    /// The plan's billing period, in estimated USD.
    case billingPeriod

    var id: String { rawValue }

    var label: String {
        switch self {
        case .block: "5-hour block"
        case .daily: "Today"
        case .weekly: "This week"
        case .billingPeriod: "This billing period"
        }
    }

    /// Blocks are counted in tokens; everything else in money.
    var unit: BudgetUnit {
        self == .block ? .tokens : .usd
    }
}

enum BudgetUnit: Sendable {
    case tokens
    case usd
}

/// Fractions of a budget worth interrupting someone for.
///
/// Fixed rather than configurable: three well-chosen points are useful, and an
/// editable list mostly produces notification fatigue.
enum BudgetThreshold {
    static let all: [Int] = [50, 80, 100]
}

/// One budget the user has configured.
struct Budget: Sendable, Equatable, Codable {
    var scope: BudgetScope
    var isEnabled: Bool
    /// Ceiling in the scope's unit. For `.block` this is ignored — the limit
    /// comes from the block reference already configured in Usage Windows, so
    /// the same number isn't entered twice.
    var limit: Decimal

    init(scope: BudgetScope, isEnabled: Bool = false, limit: Decimal = 0) {
        self.scope = scope
        self.isEnabled = isEnabled
        self.limit = limit
    }
}

/// A crossing worth notifying about.
struct BudgetAlert: Sendable, Equatable {
    var scope: BudgetScope
    /// The threshold crossed (50/80/100).
    var threshold: Int
    var used: Decimal
    var limit: Decimal
    var unit: BudgetUnit

    /// Notification title. Deliberately leads with the app name so the alert is
    /// identifiable in a stack of notifications.
    var title: String {
        threshold >= 100
            ? "Token Meter — \(scope.label) budget reached"
            : "Token Meter — \(threshold)% of your \(scope.label.lowercased()) budget"
    }

    /// Notification body.
    ///
    /// Never says "remaining", "left", or "quota": the numbers are
    /// reconstructed from local logs and the ceiling is the user's own.
    var body: String {
        let usedText = BudgetFormat.amount(used, unit: unit)
        let limitText = BudgetFormat.amount(limit, unit: unit)
        return "Estimated \(usedText) of your \(limitText) budget. Reconstructed from local logs — an estimate, not a bill or your plan's quota."
    }
}

enum BudgetFormat {
    static func amount(_ value: Decimal, unit: BudgetUnit) -> String {
        switch unit {
        case .usd:
            return value.formatted(.currency(code: "USD"))
        case .tokens:
            let count = NSDecimalNumber(decimal: value).intValue
            return count.formatted(.number.notation(.compactName)) + " tokens"
        }
    }
}

/// Remembers which thresholds already fired, so a long session can't re-notify
/// on every ingest tick.
///
/// Keyed by scope **and window instance** (today's date, this block's start …)
/// so a new day or a new block starts with a clean slate automatically. Persisted
/// so a relaunch mid-window doesn't replay alerts the user already dismissed.
struct BudgetAlertLedger: Sendable, Equatable, Codable {
    /// "scope|windowKey" → thresholds already fired for it.
    private var fired: [String: Set<Int>] = [:]

    init() {}

    private static func key(_ scope: BudgetScope, _ windowKey: String) -> String {
        "\(scope.rawValue)|\(windowKey)"
    }

    func hasFired(_ threshold: Int, scope: BudgetScope, windowKey: String) -> Bool {
        fired[Self.key(scope, windowKey)]?.contains(threshold) ?? false
    }

    mutating func markFired(
        upTo threshold: Int,
        scope: BudgetScope,
        windowKey: String,
        thresholds: [Int] = BudgetThreshold.all
    ) {
        let key = Self.key(scope, windowKey)
        // Marking every lower threshold too is what stops a jump from 0% to 90%
        // producing a 50% *and* an 80% notification back to back.
        let reached = thresholds.filter { $0 <= threshold }
        fired[key, default: []].formUnion(reached)
    }

    /// Drops entries for windows that have rolled over, so the ledger can't
    /// grow without bound across months of running.
    mutating func prune(keeping activeKeys: Set<String>) {
        fired = fired.filter { activeKeys.contains($0.key) }
    }

    /// The storage keys currently in play, for `prune`.
    static func activeKey(_ scope: BudgetScope, _ windowKey: String) -> String {
        key(scope, windowKey)
    }

    var isEmpty: Bool { fired.isEmpty }
}

/// Decides whether a budget crossing deserves a notification. Pure — no clock,
/// no I/O, no notification framework — so every rule here is unit-testable.
enum BudgetEvaluator {
    /// The highest not-yet-fired threshold that `used` has reached.
    ///
    /// Returns at most **one** alert per evaluation: if usage leaps past several
    /// thresholds at once the user gets the highest one, not a burst.
    static func evaluate(
        budget: Budget,
        used: Decimal,
        limit: Decimal,
        windowKey: String,
        ledger: inout BudgetAlertLedger,
        thresholds: [Int] = BudgetThreshold.all
    ) -> BudgetAlert? {
        guard budget.isEnabled, limit > 0, used > 0 else { return nil }

        let percent = (used / limit) * 100
        let crossed = thresholds
            .filter { Decimal($0) <= percent }
            .filter { !ledger.hasFired($0, scope: budget.scope, windowKey: windowKey) }

        guard let highest = crossed.max() else { return nil }

        ledger.markFired(
            upTo: highest,
            scope: budget.scope,
            windowKey: windowKey,
            thresholds: thresholds
        )
        return BudgetAlert(
            scope: budget.scope,
            threshold: highest,
            used: used,
            limit: limit,
            unit: budget.scope.unit
        )
    }

    /// Stable identity for the window a scope is currently measuring, so the
    /// ledger resets on its own when the window rolls over.
    static func windowKey(
        for scope: BudgetScope,
        now: Date,
        blockStart: Date?,
        billingPeriodStart: Date?,
        calendar: Calendar
    ) -> String? {
        switch scope {
        case .block:
            guard let blockStart else { return nil }
            return String(Int(blockStart.timeIntervalSince1970))
        case .daily:
            let day = calendar.dateComponents([.year, .month, .day], from: now)
            return "\(day.year ?? 0)-\(day.month ?? 0)-\(day.day ?? 0)"
        case .weekly:
            guard let week = calendar.dateInterval(of: .weekOfYear, for: now) else { return nil }
            return String(Int(week.start.timeIntervalSince1970))
        case .billingPeriod:
            guard let billingPeriodStart else { return nil }
            return String(Int(billingPeriodStart.timeIntervalSince1970))
        }
    }
}
