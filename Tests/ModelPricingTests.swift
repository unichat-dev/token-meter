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
}
