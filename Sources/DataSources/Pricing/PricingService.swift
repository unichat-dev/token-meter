// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// Loads and refreshes the pricing table.
///
/// Layering (weakest → strongest):
/// 1. **Bundled** `default-pricing.json` — always present, ships with the app.
/// 2. **Cached** copy of the last successful feed fetch (Application Support).
/// 3. **Remote** feed — our own `pricing.json` served from the repo,
///    regenerated daily by CI (see `pricing-feed/`). Fetched at launch when
///    stale (>24 h) and once a day while running; conditional GET via ETag.
///
/// User per-model **overrides** sit on top of whichever base is active and
/// are stored as a plain JSON file next to the cache. No secrets here.
actor PricingService {
    struct LoadResult: Sendable {
        var table: PricingTable
        var status: PricingFeedStatus
        var overrides: [String: ModelPricing]
    }

    private struct CachedFeed: Codable {
        var etag: String?
        var fetchedAt: Date
        var table: PricingTable
    }

    static let refreshInterval: TimeInterval = 24 * 60 * 60

    private let directory: URL
    private var cachedETag: String?
    private var lastFetchAt: Date?

    init(directory: URL) {
        self.directory = directory
    }

    private var cacheURL: URL { directory.appending(path: "pricing-cache.json") }
    private var overridesURL: URL { directory.appending(path: "pricing-overrides.json") }

    // MARK: - Initial load (no network)

    func loadInitial() -> LoadResult? {
        let overrides = loadOverrides()

        if let cached = try? Self.decoder.decode(CachedFeed.self, from: Data(contentsOf: cacheURL)) {
            cachedETag = cached.etag
            lastFetchAt = cached.fetchedAt
            return LoadResult(
                table: cached.table,
                status: PricingFeedStatus(
                    origin: .cached,
                    generatedAt: cached.table.generatedAt,
                    fetchedAt: cached.fetchedAt,
                    modelCount: cached.table.models.count
                ),
                overrides: overrides
            )
        }

        guard
            let url = Bundle.main.url(forResource: "default-pricing", withExtension: "json"),
            let data = try? Data(contentsOf: url),
            let table = try? PricingTable.decoder.decode(PricingTable.self, from: data)
        else {
            Logger.dataSources.error("bundled default-pricing.json missing or undecodable")
            return nil
        }
        return LoadResult(
            table: table,
            status: PricingFeedStatus(
                origin: .bundled,
                generatedAt: table.generatedAt,
                fetchedAt: nil,
                modelCount: table.models.count
            ),
            overrides: overrides
        )
    }

    // MARK: - Remote refresh

    var isDue: Bool {
        guard let lastFetchAt else { return true }
        return Date.now.timeIntervalSince(lastFetchAt) >= Self.refreshInterval
    }

    /// Fetches the feed. Returns `nil` when unchanged (HTTP 304) or on any
    /// failure — the current table simply stays in effect.
    func refresh(from feedURL: URL) async -> LoadResult? {
        var request = URLRequest(url: feedURL, timeoutInterval: 30)
        if let cachedETag {
            request.setValue(cachedETag, forHTTPHeaderField: "If-None-Match")
        }

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse {
                if http.statusCode == 304 {
                    lastFetchAt = .now
                    return nil
                }
                guard http.statusCode == 200 else {
                    Logger.dataSources.warning("pricing feed HTTP \(http.statusCode)")
                    return nil
                }
            }
            let table = try PricingTable.decoder.decode(PricingTable.self, from: data)
            guard table.schemaVersion == 1, table.models.count >= 20 else {
                // Schema from the future or a suspicious payload: keep what
                // we have rather than degrade silently.
                Logger.dataSources.warning("pricing feed rejected: schema \(table.schemaVersion), \(table.models.count) models")
                return nil
            }

            let etag = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "ETag")
            let fetchedAt = Date.now
            cachedETag = etag
            lastFetchAt = fetchedAt
            saveCache(CachedFeed(etag: etag, fetchedAt: fetchedAt, table: table))

            return LoadResult(
                table: table,
                status: PricingFeedStatus(
                    origin: .remote,
                    generatedAt: table.generatedAt,
                    fetchedAt: fetchedAt,
                    modelCount: table.models.count
                ),
                overrides: loadOverrides()
            )
        } catch {
            Logger.dataSources.warning("pricing feed fetch failed: \(error, privacy: .public)")
            return nil
        }
    }

    // MARK: - Overrides

    func saveOverrides(_ overrides: [String: ModelPricing]) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(overrides)
            try data.write(to: overridesURL, options: .atomic)
        } catch {
            Logger.dataSources.error("saving pricing overrides failed: \(error, privacy: .public)")
        }
    }

    private func loadOverrides() -> [String: ModelPricing] {
        guard let data = try? Data(contentsOf: overridesURL) else { return [:] }
        return (try? Self.decoder.decode([String: ModelPricing].self, from: data)) ?? [:]
    }

    private func saveCache(_ cache: CachedFeed) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let data = try Self.encoder.encode(cache)
            try data.write(to: cacheURL, options: .atomic)
        } catch {
            Logger.dataSources.error("saving pricing cache failed: \(error, privacy: .public)")
        }
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()
}
