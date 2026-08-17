// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What the user actually pays for their AI coding tools.
///
/// Token Meter can only ever compute **API list-price equivalent** cost from
/// local logs. On a subscription that number is not a bill — it's the value you
/// got out of a flat fee. Knowing the plan is what lets the app say so instead
/// of showing a large dollar figure with no context.
enum SubscriptionPlan: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Not declared — the app keeps showing plain estimated cost.
    case unset
    case claudePro
    case claudeMax5
    case claudeMax20
    case chatGPTPlus
    case chatGPTPro
    /// Metered API billing: the estimate approximates a real invoice, so
    /// there's no "value multiple" to show.
    case payAsYouGo
    case custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .unset: "Not set"
        case .claudePro: "Claude Pro"
        case .claudeMax5: "Claude Max 5×"
        case .claudeMax20: "Claude Max 20×"
        case .chatGPTPlus: "ChatGPT Plus"
        case .chatGPTPro: "ChatGPT Pro"
        case .payAsYouGo: "Pay-as-you-go API"
        case .custom: "Custom"
        }
    }

    /// List price at time of writing. Editable in Settings, because vendors
    /// change prices and Token Meter must never assert a stale number as fact.
    var defaultMonthlyPriceUSD: Decimal? {
        switch self {
        case .claudePro, .chatGPTPlus: 20
        case .claudeMax5: 100
        case .claudeMax20, .chatGPTPro: 200
        case .custom: 0
        case .unset, .payAsYouGo: nil
        }
    }

    /// Whether comparing observed usage against a flat fee is meaningful.
    var showsValueComparison: Bool {
        switch self {
        case .unset, .payAsYouGo: false
        case .claudePro, .claudeMax5, .claudeMax20, .chatGPTPlus, .chatGPTPro, .custom: true
        }
    }
}

/// The billing window a plan's fee covers.
///
/// Subscriptions renew on the day you signed up, not the 1st, so the period is
/// anchored to a configurable cycle day rather than the calendar month.
enum BillingPeriod {
    /// Cycle days are clamped to 1...28 so every month has the day — no
    /// silently skipped renewal in February.
    static let dayRange = 1...28

    /// The period containing `date`, starting on `cycleStartDay`.
    static func current(
        containing date: Date,
        cycleStartDay: Int,
        calendar: Calendar = .current
    ) -> DateInterval {
        let day = min(max(cycleStartDay, dayRange.lowerBound), dayRange.upperBound)

        var components = calendar.dateComponents([.year, .month], from: date)
        components.day = day
        // Anchor at the start of the day so a period boundary never lands
        // mid-afternoon because `date` did.
        guard let anchor = calendar.date(from: components).map({ calendar.startOfDay(for: $0) })
        else {
            return DateInterval(start: date, duration: 0)
        }

        // Before the cycle day this month → we're still inside the period that
        // began last month.
        let start = anchor <= date
            ? anchor
            : calendar.date(byAdding: .month, value: -1, to: anchor) ?? anchor
        let end = calendar.date(byAdding: .month, value: 1, to: start) ?? start
        return DateInterval(start: start, end: end)
    }
}

/// What the current billing period cost versus what it's being paid for.
struct PlanValue: Sendable, Equatable {
    var plan: SubscriptionPlan
    /// What the user pays for `period`. Zero for `.unset` / `.payAsYouGo`.
    var monthlyPriceUSD: Decimal
    var period: DateInterval
    /// API list-price equivalent of everything Token Meter observed in the
    /// period. A **floor**, not a total: usage from before the app was
    /// installed, from rotated-away logs, or from the web chat apps is
    /// invisible, and unpriced models are excluded entirely.
    var observedCostUSD: Decimal
    var eventCount: Int
    /// Models seen in the period with no price — their usage is missing from
    /// `observedCostUSD`, so the comparison understates.
    var unpricedModels: Set<String>
    /// True when history doesn't reach back to `period.start`, so the observed
    /// figure covers only part of the period.
    var isPartialPeriod: Bool

    /// How many times over the usage would have cost, versus the fee.
    /// `nil` when there's nothing meaningful to divide by.
    var valueMultiple: Decimal? {
        guard plan.showsValueComparison, monthlyPriceUSD > 0 else { return nil }
        return observedCostUSD / monthlyPriceUSD
    }

    /// Observed value minus the fee — positive means the plan is paying off.
    var netUSD: Decimal? {
        guard plan.showsValueComparison, monthlyPriceUSD > 0 else { return nil }
        return observedCostUSD - monthlyPriceUSD
    }

    /// True once usage has exceeded the fee.
    var hasBrokenEven: Bool {
        (netUSD ?? 0) > 0
    }

    static let none = PlanValue(
        plan: .unset,
        monthlyPriceUSD: 0,
        period: DateInterval(start: .distantPast, duration: 0),
        observedCostUSD: 0,
        eventCount: 0,
        unpricedModels: [],
        isPartialPeriod: false
    )
}

extension PlanValue {
    /// Builds the period's value picture from raw events.
    ///
    /// `earliestHistoryAt` is the oldest event the app knows about at all —
    /// used to flag a period the history can't fully cover.
    static func make(
        plan: SubscriptionPlan,
        monthlyPriceUSD: Decimal,
        events: [UsageEvent],
        now: Date,
        cycleStartDay: Int,
        resolver: ResolvedPricing,
        earliestHistoryAt: Date?,
        calendar: Calendar = .current
    ) -> PlanValue {
        let period = BillingPeriod.current(
            containing: now, cycleStartDay: cycleStartDay, calendar: calendar
        )
        let inPeriod = events.filter {
            $0.provider.isMetered
                && $0.timestamp >= period.start
                && $0.timestamp < period.end
        }
        let totals = CostEngine.totals(for: inPeriod, resolver: resolver)

        return PlanValue(
            plan: plan,
            monthlyPriceUSD: monthlyPriceUSD,
            period: period,
            observedCostUSD: totals.cost,
            eventCount: inPeriod.count,
            unpricedModels: totals.unpricedModels,
            isPartialPeriod: (earliestHistoryAt ?? now) > period.start
        )
    }
}
