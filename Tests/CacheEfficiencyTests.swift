// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("CacheEfficiency")
struct CacheEfficiencyTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Opus-shaped: input $5, cache read $0.50 (10× cheaper), write $6.25.
    private let resolver = ResolvedPricing(base: [
        "claude-opus-5": ModelPricing(
            inputPerMTok: 5, outputPerMTok: 25,
            cacheReadPerMTok: Decimal(string: "0.5")!,
            cacheWritePerMTok: Decimal(string: "6.25")!,
            cacheWrite1hPerMTok: 10
        )
    ])

    private func aggregate(_ tokens: TokenCounts, model: String = "claude-opus-5") -> UsageIndex.Aggregate {
        var index = UsageIndex()
        index.insert(
            UsageEvent(
                id: "e", provider: .claudeCode, accuracy: .estimated,
                timestamp: Date(timeIntervalSince1970: 1_780_000_000),
                model: model, project: nil, tokens: tokens
            ),
            calendar: calendar
        )
        return index.aggregateAll()
    }

    @Test("cache reads are the saving: 1M read costs a tenth of 1M input")
    func readSavings() {
        let cache = CacheEfficiency.make(
            aggregate: aggregate(TokenCounts(cacheRead: 1_000_000)),
            resolver: resolver
        )
        #expect(cache.actualCostUSD == Decimal(string: "0.5")!)  // 1M × $0.50
        #expect(cache.withoutCacheCostUSD == 5)                  // 1M × $5.00
        #expect(cache.savingsUSD == Decimal(string: "4.5")!)
    }

    @Test("cache writes cost more than plain input, so they cut the saving")
    func writesAreACost() {
        // A write is $6.25 vs $5 as input — caching is a net loss on writes,
        // and the panel must not pretend otherwise.
        let cache = CacheEfficiency.make(
            aggregate: aggregate(TokenCounts(cacheCreation: 1_000_000)),
            resolver: resolver
        )
        #expect(cache.actualCostUSD == Decimal(string: "6.25")!)
        #expect(cache.withoutCacheCostUSD == 5)
        #expect(cache.savingsUSD == Decimal(string: "-1.25")!)
    }

    @Test("output tokens are untouched by the counterfactual")
    func outputUnchanged() {
        let cache = CacheEfficiency.make(
            aggregate: aggregate(TokenCounts(output: 1_000_000)),
            resolver: resolver
        )
        // Output bills identically either way, so it cancels out entirely.
        #expect(cache.actualCostUSD == 25)
        #expect(cache.withoutCacheCostUSD == 25)
        #expect(cache.savingsUSD == 0)
    }

    @Test("hit rate counts prompt tokens only, never output")
    func hitRateIgnoresOutput() {
        let cache = CacheEfficiency.make(
            aggregate: aggregate(TokenCounts(
                input: 250_000, output: 9_000_000, cacheRead: 750_000
            )),
            resolver: resolver
        )
        // 750k of 1M prompt tokens came from cache.
        #expect(abs(cache.hitRate - 0.75) < 0.0001)
    }

    @Test("a realistic agentic mix shows a large saving")
    func realisticMix() {
        // Roughly the shape of real Claude Code usage: cache reads dwarf all else.
        let cache = CacheEfficiency.make(
            aggregate: aggregate(TokenCounts(
                input: 5_000, output: 500_000,
                cacheRead: 300_000_000, cacheCreation: 3_000_000
            )),
            resolver: resolver
        )
        #expect(cache.savingsUSD > 0)
        #expect(cache.savingsRate > 0.5)
        #expect(cache.hitRate > 0.98)
    }

    @Test("unpriced models are excluded from both sides of the comparison")
    func unpricedExcluded() {
        let cache = CacheEfficiency.make(
            aggregate: aggregate(TokenCounts(cacheRead: 1_000_000), model: "mystery-model"),
            resolver: resolver
        )
        #expect(!cache.hasData)
        #expect(cache.actualCostUSD == 0)
        #expect(cache.withoutCacheCostUSD == 0)
    }

    @Test("an empty window reports no data rather than a fake 0% saving")
    func emptyWindow() {
        let cache = CacheEfficiency.make(
            aggregate: UsageIndex.Aggregate(), resolver: resolver
        )
        #expect(!cache.hasData)
        #expect(cache.hitRate == 0)
        #expect(cache.savingsRate == 0)
    }

    @Test("rates never divide by zero")
    func noDivideByZero() {
        let cache = CacheEfficiency(
            cacheReadTokens: 0, cacheWriteTokens: 0, freshInputTokens: 0,
            actualCostUSD: 0, withoutCacheCostUSD: 0
        )
        #expect(cache.hitRate == 0)
        #expect(cache.savingsRate == 0)
    }
}
