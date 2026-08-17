// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What prompt caching is doing to a window's bill.
///
/// Agentic coding re-sends the whole conversation prefix on every turn, so
/// cache reads dominate both token counts and cost — for a heavy user they can
/// be three quarters of the total. That makes caching the single most useful
/// thing to show, because it's one of the few levers a user can actually pull:
/// shorter sessions mean smaller prefixes to re-read.
struct CacheEfficiency: Sendable, Equatable {
    /// Tokens served from cache.
    var cacheReadTokens: Int
    /// Tokens written into the cache.
    var cacheWriteTokens: Int
    /// Uncached prompt tokens.
    var freshInputTokens: Int

    /// What the window actually cost.
    var actualCostUSD: Decimal
    /// What the identical traffic would have cost with no prompt caching, i.e.
    /// every cached and written token billed as ordinary input.
    var withoutCacheCostUSD: Decimal

    /// Share of prompt tokens that came from cache rather than being sent fresh.
    var hitRate: Double {
        let prompt = cacheReadTokens + cacheWriteTokens + freshInputTokens
        guard prompt > 0 else { return 0 }
        return Double(cacheReadTokens) / Double(prompt)
    }

    /// Difference between the two figures. Positive means caching is helping.
    var savingsUSD: Decimal {
        withoutCacheCostUSD - actualCostUSD
    }

    /// Cost avoided as a share of the uncached figure.
    var savingsRate: Double {
        let without = NSDecimalNumber(decimal: withoutCacheCostUSD).doubleValue
        guard without > 0 else { return 0 }
        return NSDecimalNumber(decimal: savingsUSD).doubleValue / without
    }

    var hasData: Bool {
        cacheReadTokens + cacheWriteTokens + freshInputTokens > 0
    }
}

extension CacheEfficiency {
    /// Builds the picture for a pre-aggregated window.
    ///
    /// The counterfactual prices every cache read and cache write at the
    /// model's ordinary **input** rate, holding output unchanged. That is
    /// deliberately a like-for-like comparison of the *same traffic*, not a
    /// prediction: without caching a user would restructure their sessions, so
    /// this is "what these exact tokens would have cost", nothing more.
    ///
    /// Models with no cache pricing are skipped on both sides of the
    /// comparison, so an unpriced model can't make caching look free.
    static func make(
        aggregate: UsageIndex.Aggregate,
        resolver: ResolvedPricing
    ) -> CacheEfficiency {
        var efficiency = CacheEfficiency(
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            freshInputTokens: 0,
            actualCostUSD: 0,
            withoutCacheCostUSD: 0
        )

        for (model, bucket) in aggregate.byModel {
            guard let pricing = resolver.pricing(for: model) else { continue }

            efficiency.cacheReadTokens += bucket.tokens.cacheRead
            efficiency.cacheWriteTokens += bucket.tokens.cacheCreation
            efficiency.freshInputTokens += bucket.tokens.input

            efficiency.actualCostUSD += CostEngine.cost(
                tokens: bucket.tokens,
                pricing: pricing,
                serverToolUse: bucket.serverToolUse
            )

            // Same tokens, no cache tiers: reads and writes become plain input.
            var uncached = bucket.tokens
            uncached.input += bucket.tokens.cacheRead + bucket.tokens.cacheCreation
            uncached.cacheRead = 0
            uncached.cacheCreation = 0
            uncached.cacheCreation5m = 0
            uncached.cacheCreation1h = 0

            efficiency.withoutCacheCostUSD += CostEngine.cost(
                tokens: uncached,
                pricing: pricing,
                serverToolUse: bucket.serverToolUse
            )
        }

        return efficiency
    }
}
