// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// USD per **million** tokens for one model, by tier. Cache tiers are
/// optional — not every model/provider has them.
struct ModelPricing: Sendable, Codable, Equatable {
    var inputPerMTok: Decimal
    var outputPerMTok: Decimal
    var cacheReadPerMTok: Decimal?
    /// Cache write at the default (5-minute) TTL.
    var cacheWritePerMTok: Decimal?
    /// Cache write at the 1-hour TTL, which providers price higher than the
    /// 5-minute tier. Optional: feeds that don't publish it fall back to
    /// ``derivedCacheWrite1hPerMTok``.
    var cacheWrite1hPerMTok: Decimal?
    /// USD for **one** server-side web-search request (not per million).
    var webSearchPerRequest: Decimal?

    init(
        inputPerMTok: Decimal,
        outputPerMTok: Decimal,
        cacheReadPerMTok: Decimal? = nil,
        cacheWritePerMTok: Decimal? = nil,
        cacheWrite1hPerMTok: Decimal? = nil,
        webSearchPerRequest: Decimal? = nil
    ) {
        self.inputPerMTok = inputPerMTok
        self.outputPerMTok = outputPerMTok
        self.cacheReadPerMTok = cacheReadPerMTok
        self.cacheWritePerMTok = cacheWritePerMTok
        self.cacheWrite1hPerMTok = cacheWrite1hPerMTok
        self.webSearchPerRequest = webSearchPerRequest
    }

    /// The 1-hour cache-write rate to actually bill at.
    ///
    /// When the feed publishes the tier we use it verbatim. Otherwise we derive
    /// it as **2x base input** — Anthropic's documented multiplier for a 1-hour
    /// write (the 5-minute tier is 1.25x). Deriving is gated on the model having
    /// a 5-minute cache price at all, so models without prompt caching never
    /// get an invented one.
    var effectiveCacheWrite1hPerMTok: Decimal? {
        if let cacheWrite1hPerMTok { return cacheWrite1hPerMTok }
        guard cacheWritePerMTok != nil else { return nil }
        return inputPerMTok * 2
    }
}

/// The pricing feed document (see `pricing-feed/generate_pricing.py` — the
/// app depends only on this schema, never on upstream sources directly).
struct PricingTable: Sendable, Codable, Equatable {
    var schemaVersion: Int
    var generatedAt: Date
    var source: String
    var models: [String: ModelPricing]

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Where the currently-used base table came from — shown in Settings so the
/// user knows how fresh their prices are.
struct PricingFeedStatus: Sendable, Equatable {
    enum Origin: String, Sendable {
        case bundled = "bundled with the app"
        case cached = "cached from the feed"
        case remote = "fetched from the feed"
    }

    var origin: Origin
    var generatedAt: Date
    var fetchedAt: Date?
    var modelCount: Int
}

/// Price resolution: user override (exact) → feed exact → feed longest-prefix.
///
/// Prefix matching covers versioned ids: a log model `claude-sonnet-5-20250929`
/// finds feed key `claude-sonnet-5` when no exact entry exists.
struct ResolvedPricing: Sendable, Equatable {
    var base: [String: ModelPricing]
    var overrides: [String: ModelPricing]

    init(base: [String: ModelPricing] = [:], overrides: [String: ModelPricing] = [:]) {
        self.base = base
        self.overrides = overrides
    }

    func pricing(for model: String) -> ModelPricing? {
        if let override = overrides[model] { return override }
        if let exact = base[model] { return exact }
        // Longest feed key that prefixes the model id (>= 4 chars to avoid
        // absurd matches like "o1").
        let candidate = base.keys
            .filter { $0.count >= 4 && model.hasPrefix($0) }
            .max { $0.count < $1.count }
        return candidate.map { base[$0]! }
    }
}

/// Turns token counts into estimated USD. Pure `Decimal` math — no floating
/// point drift in money.
enum CostEngine {
    /// Cost of one event at the given pricing. Tiers without a price
    /// contribute nothing (never guessed).
    ///
    /// Cache writes bill by TTL: the 5-minute portion (plus anything the
    /// provider left unattributed) at the base write rate, the 1-hour portion
    /// at the higher rate. Sources that report only a flat total land entirely
    /// in the untiered bucket and bill exactly as they did before.
    static func cost(
        tokens: TokenCounts,
        pricing: ModelPricing,
        serverToolUse: ServerToolUse = ServerToolUse()
    ) -> Decimal {
        var perMillion = Decimal(tokens.input) * pricing.inputPerMTok
        perMillion += Decimal(tokens.output) * pricing.outputPerMTok
        if let read = pricing.cacheReadPerMTok {
            perMillion += Decimal(tokens.cacheRead) * read
        }
        if let write = pricing.cacheWritePerMTok {
            perMillion += Decimal(tokens.cacheCreation5m + tokens.cacheCreationUntiered) * write
        }
        if let hourly = pricing.effectiveCacheWrite1hPerMTok {
            perMillion += Decimal(tokens.cacheCreation1h) * hourly
        }

        var total = perMillion / 1_000_000

        // Server tools are priced per request, not per token, so they're added
        // after the per-million divide. Web fetch carries no per-request charge
        // — its cost already arrives as tokens.
        if let perSearch = pricing.webSearchPerRequest {
            total += Decimal(serverToolUse.webSearchRequests) * perSearch
        }
        return total
    }

    struct Totals: Equatable, Sendable {
        var cost: Decimal = 0
        var pricedEventCount = 0
        /// Models that appeared but had no price — surfaced in the UI so the
        /// user knows the total is partial (honesty: no silent gaps).
        var unpricedModels: Set<String> = []

        /// `nil` when nothing could be priced — UI shows "—", never $0.00
        /// for "unknown".
        var costIfAnyPriced: Decimal? {
            pricedEventCount > 0 ? cost : nil
        }
    }

    static func totals(for events: [UsageEvent], resolver: ResolvedPricing) -> Totals {
        var totals = Totals()
        for event in events {
            // Local models (Ollama) have no cost by nature — skip them
            // entirely rather than flagging them as pricing gaps.
            guard event.provider.isMetered else { continue }
            if let pricing = resolver.pricing(for: event.model) {
                totals.cost += cost(
                    tokens: event.tokens,
                    pricing: pricing,
                    serverToolUse: event.serverToolUse
                )
                totals.pricedEventCount += 1
            } else {
                totals.unpricedModels.insert(event.model)
            }
        }
        return totals
    }
}
