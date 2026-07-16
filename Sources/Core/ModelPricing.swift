// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// USD per **million** tokens for one model, by tier. Cache tiers are
/// optional — not every model/provider has them.
struct ModelPricing: Sendable, Codable, Equatable {
    var inputPerMTok: Decimal
    var outputPerMTok: Decimal
    var cacheReadPerMTok: Decimal?
    var cacheWritePerMTok: Decimal?
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
    /// Cost of one event's tokens at the given pricing. Cache tiers without
    /// a price contribute nothing (never guessed).
    static func cost(tokens: TokenCounts, pricing: ModelPricing) -> Decimal {
        var total = Decimal(tokens.input) * pricing.inputPerMTok
        total += Decimal(tokens.output) * pricing.outputPerMTok
        if let read = pricing.cacheReadPerMTok {
            total += Decimal(tokens.cacheRead) * read
        }
        if let write = pricing.cacheWritePerMTok {
            total += Decimal(tokens.cacheCreation) * write
        }
        return total / 1_000_000
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
            if let pricing = resolver.pricing(for: event.model) {
                totals.cost += cost(tokens: event.tokens, pricing: pricing)
                totals.pricedEventCount += 1
            } else {
                totals.unpricedModels.insert(event.model)
            }
        }
        return totals
    }
}
