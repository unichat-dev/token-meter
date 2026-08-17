// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("ModelPricing & CostEngine")
struct ModelPricingTests {
    private let opusPricing = ModelPricing(
        inputPerMTok: 15,
        outputPerMTok: 75,
        cacheReadPerMTok: Decimal(string: "1.5")!,
        cacheWritePerMTok: Decimal(string: "18.75")!
    )

    private func event(id: String, model: String, tokens: TokenCounts) -> UsageEvent {
        UsageEvent(
            id: id,
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            model: model,
            project: nil,
            tokens: tokens
        )
    }

    // MARK: - Cost math

    @Test("cost applies all four tiers at $/MTok")
    func fourTierCost() {
        let tokens = TokenCounts(input: 1_000_000, output: 2_000_000, cacheRead: 4_000_000, cacheCreation: 800_000)
        let cost = CostEngine.cost(tokens: tokens, pricing: opusPricing)
        // 1M×15 + 2M×75 + 4M×1.5 + 0.8M×18.75 = 15 + 150 + 6 + 15 = 186
        #expect(cost == 186)
    }

    @Test("missing cache tiers contribute nothing — never guessed")
    func missingCacheTiers() {
        let pricing = ModelPricing(inputPerMTok: 10, outputPerMTok: 30)
        let tokens = TokenCounts(input: 1_000_000, output: 1_000_000, cacheRead: 50_000_000, cacheCreation: 50_000_000)
        #expect(CostEngine.cost(tokens: tokens, pricing: pricing) == 40)
    }

    // MARK: - Cache-write TTL tiers

    /// Opus-shaped pricing with an explicit 1-hour tier (2x input).
    private let tieredPricing = ModelPricing(
        inputPerMTok: 5,
        outputPerMTok: 25,
        cacheReadPerMTok: Decimal(string: "0.5")!,
        cacheWritePerMTok: Decimal(string: "6.25")!,
        cacheWrite1hPerMTok: 10
    )

    @Test("1-hour cache writes bill at the 1h rate, 5-minute at the base rate")
    func cacheWriteTiersBillSeparately() {
        let tokens = TokenCounts(
            cacheCreation: 2_000_000,
            cacheCreation5m: 500_000,
            cacheCreation1h: 1_500_000
        )
        // 0.5M×6.25 + 1.5M×10 = 3.125 + 15 = 18.125
        #expect(CostEngine.cost(tokens: tokens, pricing: tieredPricing) == Decimal(string: "18.125")!)
    }

    @Test("a flat cache total with no TTL split bills entirely at the base rate")
    func untieredCacheWriteUnchanged() {
        let tokens = TokenCounts(cacheCreation: 2_000_000)
        // Whole 2M at 6.25 = 12.5 — identical to pre-V2 behaviour.
        #expect(CostEngine.cost(tokens: tokens, pricing: tieredPricing) == Decimal(string: "12.5")!)
    }

    @Test("tokens the provider left unattributed fall back to the base rate")
    func partiallyTieredCacheWrite() {
        let tokens = TokenCounts(
            cacheCreation: 1_000_000,
            cacheCreation5m: 200_000,
            cacheCreation1h: 300_000
        )
        // 0.5M unattributed + 0.2M at 6.25, 0.3M at 10 = 4.375 + 3 = 7.375
        #expect(CostEngine.cost(tokens: tokens, pricing: tieredPricing) == Decimal(string: "7.375")!)
    }

    @Test("tiers overshooting the total never produce negative cost")
    func overshootingTiersClamped() {
        let tokens = TokenCounts(
            cacheCreation: 100_000,
            cacheCreation5m: 100_000,
            cacheCreation1h: 100_000
        )
        #expect(tokens.cacheCreationUntiered == 0)
        #expect(CostEngine.cost(tokens: tokens, pricing: tieredPricing) > 0)
    }

    @Test("a feed without the 1h tier derives it as 2x base input")
    func derivedHourlyRate() {
        let noHourly = ModelPricing(
            inputPerMTok: 5,
            outputPerMTok: 25,
            cacheWritePerMTok: Decimal(string: "6.25")!
        )
        #expect(noHourly.effectiveCacheWrite1hPerMTok == 10)

        let tokens = TokenCounts(cacheCreation: 1_000_000, cacheCreation1h: 1_000_000)
        #expect(CostEngine.cost(tokens: tokens, pricing: noHourly) == 10)
    }

    @Test("models without prompt caching never get an invented 1h rate")
    func noDerivationWithoutCaching() {
        let uncached = ModelPricing(inputPerMTok: 5, outputPerMTok: 25)
        #expect(uncached.effectiveCacheWrite1hPerMTok == nil)

        let tokens = TokenCounts(cacheCreation: 1_000_000, cacheCreation1h: 1_000_000)
        #expect(CostEngine.cost(tokens: tokens, pricing: uncached) == 0)
    }

    @Test("TokenCounts.total ignores the TTL breakdown so it can't double-count")
    func totalIgnoresBreakdown() {
        let tokens = TokenCounts(
            input: 10,
            output: 20,
            cacheRead: 30,
            cacheCreation: 40,
            cacheCreation5m: 15,
            cacheCreation1h: 25
        )
        #expect(tokens.total == 100)
    }

    // MARK: - Server tools

    @Test("web search bills per request, on top of tokens")
    func webSearchBillsPerRequest() {
        let pricing = ModelPricing(
            inputPerMTok: 5,
            outputPerMTok: 25,
            webSearchPerRequest: Decimal(string: "0.01")!
        )
        let cost = CostEngine.cost(
            tokens: TokenCounts(input: 1_000_000),
            pricing: pricing,
            serverToolUse: ServerToolUse(webSearchRequests: 3, webFetchRequests: 7)
        )
        // 1M×5/1e6 = 5, plus 3 searches × $0.01. Fetches are never charged.
        #expect(cost == Decimal(string: "5.03")!)
    }

    @Test("web search with no published price contributes nothing")
    func webSearchUnpricedIsFree() {
        let cost = CostEngine.cost(
            tokens: TokenCounts(),
            pricing: ModelPricing(inputPerMTok: 5, outputPerMTok: 25),
            serverToolUse: ServerToolUse(webSearchRequests: 100)
        )
        #expect(cost == 0)
    }

    @Test("totals carry each event's server tool usage")
    func totalsIncludeServerTools() {
        let resolver = ResolvedPricing(base: [
            "claude-opus-5": ModelPricing(
                inputPerMTok: 5,
                outputPerMTok: 25,
                webSearchPerRequest: Decimal(string: "0.01")!
            )
        ])
        let searching = UsageEvent(
            id: "s",
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            model: "claude-opus-5",
            project: nil,
            tokens: TokenCounts(),
            serverToolUse: ServerToolUse(webSearchRequests: 5)
        )
        #expect(CostEngine.totals(for: [searching], resolver: resolver).cost == Decimal(string: "0.05")!)
    }

    @Test("decimal math stays exact for small counts")
    func decimalPrecision() {
        let pricing = ModelPricing(inputPerMTok: Decimal(string: "0.25")!, outputPerMTok: Decimal(string: "1.25")!)
        let cost = CostEngine.cost(tokens: TokenCounts(input: 3, output: 7), pricing: pricing)
        // (3×0.25 + 7×1.25) / 1e6 = 9.5e-6 — exact in Decimal
        #expect(cost == Decimal(string: "0.0000095")!)
    }

    // MARK: - Resolution

    @Test("override beats feed; feed exact beats prefix")
    func resolutionOrder() {
        let feedPrice = ModelPricing(inputPerMTok: 1, outputPerMTok: 2)
        let familyPrice = ModelPricing(inputPerMTok: 3, outputPerMTok: 4)
        let overridePrice = ModelPricing(inputPerMTok: 9, outputPerMTok: 9)

        let resolver = ResolvedPricing(
            base: ["claude-sonnet-5-20250929": feedPrice, "claude-sonnet-5": familyPrice],
            overrides: ["claude-sonnet-5-20250929": overridePrice]
        )

        #expect(resolver.pricing(for: "claude-sonnet-5-20250929") == overridePrice)
        #expect(resolver.pricing(for: "claude-sonnet-5") == familyPrice)
    }

    @Test("versioned model id falls back to longest matching feed prefix")
    func prefixFallback() {
        let family = ModelPricing(inputPerMTok: 3, outputPerMTok: 15)
        let broader = ModelPricing(inputPerMTok: 1, outputPerMTok: 1)
        let resolver = ResolvedPricing(base: [
            "claude-sonnet": broader,
            "claude-sonnet-5": family,
        ])

        // Longest prefix wins.
        #expect(resolver.pricing(for: "claude-sonnet-5-20250929") == family)
        // No match at all → nil, never a guess.
        #expect(resolver.pricing(for: "gemini-ultra") == nil)
    }

    @Test("totals separate priced and unpriced models")
    func totalsSplitUnpriced() {
        let resolver = ResolvedPricing(base: [
            "claude-opus-4-8": ModelPricing(inputPerMTok: 15, outputPerMTok: 75),
        ])
        let events = [
            event(id: "a", model: "claude-opus-4-8", tokens: TokenCounts(input: 1_000_000)),
            event(id: "b", model: "mystery-model", tokens: TokenCounts(output: 999)),
        ]

        let totals = CostEngine.totals(for: events, resolver: resolver)
        #expect(totals.cost == 15)
        #expect(totals.pricedEventCount == 1)
        #expect(totals.unpricedModels == ["mystery-model"])
        #expect(totals.costIfAnyPriced == 15)
    }

    @Test("no priced events means nil cost, not $0.00")
    func nilWhenNothingPriced() {
        let totals = CostEngine.totals(
            for: [event(id: "a", model: "mystery", tokens: TokenCounts(output: 5))],
            resolver: ResolvedPricing()
        )
        #expect(totals.costIfAnyPriced == nil)
    }

    // MARK: - Feed decoding

    @Test("bundled feed file decodes and contains current Claude models")
    func bundledFeedDecodes() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/default-pricing.json")
        let table = try PricingTable.decoder.decode(PricingTable.self, from: Data(contentsOf: url))

        #expect(table.schemaVersion == 1)
        #expect(table.models.count >= 20)
        let opus = try #require(table.models["claude-opus-4-8"])
        #expect(opus.inputPerMTok > 0)
        #expect(opus.outputPerMTok > opus.inputPerMTok)
        #expect(opus.cacheReadPerMTok != nil)
        #expect(opus.cacheWritePerMTok != nil)
    }

    /// The bundled table is the offline fallback, so a model missing from it
    /// silently drops out of every cost total on a first launch with no
    /// network. Regenerate with `make update-pricing` before each release.
    @Test("bundled feed prices every Claude model the app is likely to meet")
    func bundledFeedCoversCurrentModels() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Resources/default-pricing.json")
        let table = try PricingTable.decoder.decode(PricingTable.self, from: Data(contentsOf: url))
        let resolver = ResolvedPricing(base: table.models)

        for model in ["claude-opus-5", "claude-sonnet-5", "claude-opus-4-8", "claude-haiku-4-5"] {
            #expect(resolver.pricing(for: model) != nil, "no bundled price for \(model)")
        }

        // The 1-hour cache tier has to survive the feed round-trip, or every
        // long-lived cache write silently bills at the cheaper 5-minute rate.
        let opus5 = try #require(table.models["claude-opus-5"])
        #expect(opus5.cacheWrite1hPerMTok == 10)
        #expect(opus5.webSearchPerRequest == Decimal(string: "0.01")!)
    }
}
