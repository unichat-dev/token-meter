// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("LiteLLMPricingParser")
struct LiteLLMPricingParserTests {
    /// A slice shaped like LiteLLM's real table: mixed providers, prefixed
    /// duplicates, non-chat modes, and a non-dict sentinel row.
    private let upstream = """
    {
      "sample_spec": "this row is a non-dict placeholder in the real file",
      "claude-sonnet-4": {
        "mode": "chat",
        "input_cost_per_token": 0.000003,
        "output_cost_per_token": 0.000015,
        "cache_read_input_token_cost": 0.0000003,
        "cache_creation_input_token_cost": 0.00000375
      },
      "gpt-4o": {
        "mode": "chat",
        "input_cost_per_token": 0.0000025,
        "output_cost_per_token": 0.00001
      },
      "azure/gpt-4o": {
        "mode": "chat",
        "input_cost_per_token": 0.0000025,
        "output_cost_per_token": 0.00001
      },
      "o1": {
        "mode": "chat",
        "input_cost_per_token": 0.000015,
        "output_cost_per_token": 0.00006
      },
      "text-embedding-3-small": {
        "mode": "embedding",
        "input_cost_per_token": 0.00000002,
        "output_cost_per_token": 0.0
      },
      "gemini-1.5-pro": {
        "mode": "chat",
        "input_cost_per_token": 0.0000035,
        "output_cost_per_token": 0.0000105
      },
      "gpt-4-no-output": {
        "mode": "chat",
        "input_cost_per_token": 0.00003
      }
    }
    """.data(using: .utf8)!

    @Test("includes tracked plain chat models, converts to USD per MTok")
    func includesTrackedModels() throws {
        let table = try #require(LiteLLMPricingParser.parse(upstream))
        let sonnet = try #require(table.models["claude-sonnet-4"])
        #expect(sonnet.inputPerMTok == 3)
        #expect(sonnet.outputPerMTok == 15)
        #expect(sonnet.cacheReadPerMTok == Decimal(string: "0.3"))
        #expect(sonnet.cacheWritePerMTok == Decimal(string: "3.75"))
        #expect(table.models["gpt-4o"]?.inputPerMTok == Decimal(string: "2.5"))
        #expect(table.models["o1"]?.outputPerMTok == 60)
    }

    @Test("cache tiers are nil when upstream omits them")
    func optionalCacheTiers() throws {
        let table = try #require(LiteLLMPricingParser.parse(upstream))
        let gpt = try #require(table.models["gpt-4o"])
        #expect(gpt.cacheReadPerMTok == nil)
        #expect(gpt.cacheWritePerMTok == nil)
    }

    @Test("drops provider-prefixed, non-chat, off-list, and incomplete rows")
    func excludesUntrackedModels() throws {
        let table = try #require(LiteLLMPricingParser.parse(upstream))
        #expect(table.models["azure/gpt-4o"] == nil)          // provider prefix
        #expect(table.models["text-embedding-3-small"] == nil) // embedding mode + off-list
        #expect(table.models["gemini-1.5-pro"] == nil)         // not a tracked family
        #expect(table.models["gpt-4-no-output"] == nil)        // missing output cost
        #expect(table.models["sample_spec"] == nil)            // non-dict row
        #expect(table.models.count == 3)
    }

    @Test("garbage payload returns nil rather than an empty table")
    func rejectsNonObject() {
        #expect(LiteLLMPricingParser.parse(Data("[1,2,3]".utf8)) == nil)
    }
}
