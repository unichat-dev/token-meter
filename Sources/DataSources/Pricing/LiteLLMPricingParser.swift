// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// Which shape a pricing feed URL returns, so the service knows how to decode.
enum PricingFeedFormat: Sendable {
    /// Our own compact `pricing.json` (the `pricing-feed/` output).
    case tokenMeter
    /// LiteLLM's raw `model_prices_and_context_window.json`, normalized in-app.
    case liteLLM
}

/// Normalizes LiteLLM's community pricing table into our own `PricingTable`.
///
/// This is the in-app twin of `pricing-feed/generate_pricing.py`: same include
/// rules, same per-token → per-million-token conversion, so the "LiteLLM
/// (direct)" source in Settings yields the same numbers our feed would — just
/// without depending on the feed being published.
enum LiteLLMPricingParser {
    /// The direct upstream (MIT-licensed, community-maintained).
    static let upstreamURL = URL(
        string: "https://raw.githubusercontent.com/BerriAI/litellm/main/model_prices_and_context_window.json"
    )!

    /// Plain model keys we track — no provider-prefixed duplicates like
    /// "azure/gpt-4o" or "us.anthropic.claude-…" (the CLI logs use plain ids).
    /// Mirrors the generator's `^(claude-|gpt-|chatgpt-|o[134](-mini|-pro)?(-|$))`
    /// exactly: the OpenAI o-series only matches when the digit is followed by a
    /// hyphen or the end of the id (so "o1"/"o1-mini" pass, "o13" doesn't).
    private static func isTracked(_ key: String) -> Bool {
        if key.hasPrefix("claude-") || key.hasPrefix("gpt-") || key.hasPrefix("chatgpt-") {
            return true
        }
        for base in ["o1", "o3", "o4"] where key == base || key.hasPrefix(base + "-") {
            return true
        }
        return false
    }

    /// Parses raw LiteLLM JSON into our table. Returns `nil` if the payload
    /// isn't the object-of-models shape we expect (upstream format change).
    static func parse(_ data: Data, generatedAt: Date = .now) -> PricingTable? {
        guard
            let root = try? JSONSerialization.jsonObject(with: data),
            let upstream = root as? [String: Any]
        else {
            Logger.dataSources.warning("LiteLLM payload isn't a JSON object")
            return nil
        }

        var models: [String: ModelPricing] = [:]
        for (key, value) in upstream {
            if key.contains("/") { continue }
            if !isTracked(key) { continue }
            guard let info = value as? [String: Any] else { continue }

            // Only chat-style models (matches the generator's mode filter).
            if let mode = info["mode"] as? String, mode != "chat", mode != "responses" {
                continue
            }

            guard
                let input = perMTok(info["input_cost_per_token"]),
                let output = perMTok(info["output_cost_per_token"])
            else { continue }

            models[key] = ModelPricing(
                inputPerMTok: input,
                outputPerMTok: output,
                cacheReadPerMTok: perMTok(info["cache_read_input_token_cost"]),
                cacheWritePerMTok: perMTok(info["cache_creation_input_token_cost"]),
                cacheWrite1hPerMTok: perMTok(info["cache_creation_input_token_cost_above_1hr"]),
                webSearchPerRequest: webSearchCost(info["search_context_cost_per_query"])
            )
        }

        return PricingTable(
            schemaVersion: 1,
            generatedAt: generatedAt,
            source: "litellm/model_prices_and_context_window.json (MIT), fetched directly",
            models: models
        )
    }

    /// USD per token → USD per million tokens, trimmed of float noise the same
    /// way the generator does (`round(x * 1_000_000, 6)`).
    private static func perMTok(_ raw: Any?) -> Decimal? {
        guard let number = raw as? NSNumber else { return nil }
        let perMillion = number.doubleValue * 1_000_000
        return Decimal(string: String(format: "%.6f", perMillion))
    }

    /// Upstream reports web-search cost as a per-query object keyed by context
    /// size (`search_context_size_low/medium/high`). The CLI logs only give us
    /// a request count with no size, so we take the medium tier as the
    /// representative rate — for Anthropic all three are identical anyway.
    /// A plain number is also accepted in case upstream flattens the shape.
    private static func webSearchCost(_ raw: Any?) -> Decimal? {
        if let number = raw as? NSNumber {
            return Decimal(string: String(format: "%.6f", number.doubleValue))
        }
        guard let bySize = raw as? [String: Any] else { return nil }
        let preferred = [
            "search_context_size_medium",
            "search_context_size_low",
            "search_context_size_high",
        ]
        for key in preferred {
            if let number = bySize[key] as? NSNumber {
                return Decimal(string: String(format: "%.6f", number.doubleValue))
            }
        }
        return nil
    }
}
