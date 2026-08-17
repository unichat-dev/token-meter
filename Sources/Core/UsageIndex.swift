// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Day-bucketed usage totals, maintained as events arrive.
///
/// Rollups used to be recomputed by filtering the whole event array several
/// times per pass, which made every refresh O(all history) and got slower for
/// the rest of the user's life. This keeps running totals per (day × model)
/// instead, so a refresh costs O(days in range × models) — a few hundred
/// operations rather than a few hundred thousand.
///
/// **Why aggregating first is safe for money:** `CostEngine.cost` is linear in
/// every token tier and in request counts, so pricing the sum of a model's
/// tokens gives exactly the same `Decimal` as summing each event's price. The
/// bucket key includes the model precisely because pricing varies by model and
/// nothing else.
///
/// Buckets are keyed by `calendar.startOfDay`, and every window the app reports
/// on (today, calendar week, billing period) begins at a day boundary, so whole
/// buckets always compose exactly. The 5-hour block is the one window that
/// doesn't align to days — it's reconstructed from raw events instead.
struct UsageIndex: Equatable {
    /// Totals for one model within one day.
    struct ModelBucket: Equatable, Sendable {
        var tokens = TokenCounts()
        var serverToolUse = ServerToolUse()
        var eventCount = 0
    }

    struct DayBucket: Equatable, Sendable {
        /// Metered usage, split by model so it can be priced exactly.
        var byModel: [String: ModelBucket] = [:]
        /// Local models have tokens but no cost — kept apart so they can never
        /// leak into a cost total.
        var ollamaTokens = 0
        var meteredEventCount = 0
        var lastMeteredEventAt: Date?

        var isEmpty: Bool {
            byModel.isEmpty && ollamaTokens == 0
        }
    }

    /// startOfDay → totals.
    private(set) var days: [Date: DayBucket] = [:]

    init() {}

    // MARK: - Maintenance

    mutating func insert(_ event: UsageEvent, calendar: Calendar) {
        let day = calendar.startOfDay(for: event.timestamp)
        var bucket = days[day] ?? DayBucket()

        if event.provider.isMetered {
            var model = bucket.byModel[event.model] ?? ModelBucket()
            model.tokens += event.tokens
            model.serverToolUse += event.serverToolUse
            model.eventCount += 1
            bucket.byModel[event.model] = model
            bucket.meteredEventCount += 1
            if bucket.lastMeteredEventAt.map({ event.timestamp > $0 }) ?? true {
                bucket.lastMeteredEventAt = event.timestamp
            }
        } else {
            bucket.ollamaTokens += event.tokens.total
        }

        days[day] = bucket
    }

    /// Backs an event out — used when a re-scan supersedes a stored event with
    /// a richer parse of the same log line.
    ///
    /// `lastMeteredEventAt` is intentionally left alone: recomputing it would
    /// need the day's events, and a superseding event carries the same
    /// timestamp as the one it replaces, so the value stays correct in the case
    /// this exists to serve.
    mutating func remove(_ event: UsageEvent, calendar: Calendar) {
        let day = calendar.startOfDay(for: event.timestamp)
        guard var bucket = days[day] else { return }

        if event.provider.isMetered {
            guard var model = bucket.byModel[event.model] else { return }
            model.tokens -= event.tokens
            model.serverToolUse -= event.serverToolUse
            model.eventCount -= 1
            if model.eventCount <= 0 {
                bucket.byModel.removeValue(forKey: event.model)
            } else {
                bucket.byModel[event.model] = model
            }
            bucket.meteredEventCount -= 1
        } else {
            bucket.ollamaTokens -= event.tokens.total
        }

        if bucket.isEmpty {
            days.removeValue(forKey: day)
        } else {
            days[day] = bucket
        }
    }

    // MARK: - Queries

    /// Totals across the days covered by `interval`.
    ///
    /// `interval` is treated as day-granular: a day counts when its start falls
    /// inside `[interval.start, interval.end)`. Callers pass day-aligned
    /// intervals, which is what makes that exact.
    func aggregate(in interval: DateInterval) -> Aggregate {
        var result = Aggregate()
        for (day, bucket) in days where day >= interval.start && day < interval.end {
            result.merge(bucket)
        }
        return result
    }

    /// Totals for the calendar day containing `date`.
    func aggregate(on date: Date, calendar: Calendar) -> Aggregate {
        var result = Aggregate()
        if let bucket = days[calendar.startOfDay(for: date)] {
            result.merge(bucket)
        }
        return result
    }

    /// Totals across everything indexed.
    func aggregateAll() -> Aggregate {
        var result = Aggregate()
        for bucket in days.values {
            result.merge(bucket)
        }
        return result
    }

    /// Every metered model seen, for pricing-gap reporting.
    var meteredModels: Set<String> {
        var models: Set<String> = []
        for bucket in days.values {
            models.formUnion(bucket.byModel.keys)
        }
        return models
    }

    /// Summed usage over some set of days.
    struct Aggregate: Equatable, Sendable {
        var byModel: [String: ModelBucket] = [:]
        var tokens = TokenCounts()
        var eventCount = 0
        var lastEventAt: Date?
        var ollamaTokens = 0

        mutating func merge(_ bucket: DayBucket) {
            for (model, modelBucket) in bucket.byModel {
                var existing = byModel[model] ?? ModelBucket()
                existing.tokens += modelBucket.tokens
                existing.serverToolUse += modelBucket.serverToolUse
                existing.eventCount += modelBucket.eventCount
                byModel[model] = existing
                tokens += modelBucket.tokens
            }
            eventCount += bucket.meteredEventCount
            ollamaTokens += bucket.ollamaTokens
            if let last = bucket.lastMeteredEventAt,
               lastEventAt.map({ last > $0 }) ?? true {
                lastEventAt = last
            }
        }

        /// The metered part as a display summary. Cost is filled in separately
        /// by the caller, matching `UsageSummary`'s contract.
        var summary: UsageSummary {
            var summary = UsageSummary()
            summary.tokens = tokens
            summary.eventCount = eventCount
            summary.lastEventAt = lastEventAt
            return summary
        }
    }
}

extension CostEngine {
    /// Prices a pre-aggregated window.
    ///
    /// Equivalent to `totals(for:resolver:)` over the same events — see the
    /// linearity note on ``UsageIndex`` — but costs one `Decimal` pass per
    /// model rather than per event.
    static func totals(
        for aggregate: UsageIndex.Aggregate,
        resolver: ResolvedPricing
    ) -> Totals {
        var totals = Totals()
        for (model, bucket) in aggregate.byModel {
            if let pricing = resolver.pricing(for: model) {
                totals.cost += cost(
                    tokens: bucket.tokens,
                    pricing: pricing,
                    serverToolUse: bucket.serverToolUse
                )
                totals.pricedEventCount += bucket.eventCount
            } else {
                totals.unpricedModels.insert(model)
            }
        }
        return totals
    }
}
