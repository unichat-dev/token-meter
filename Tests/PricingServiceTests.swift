// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("PricingService")
struct PricingServiceTests {
    private func feedJSON(generatedAt: String = "2026-07-16T00:00:00Z", extraModel: String? = nil) -> String {
        var models = """
        "claude-opus-4-8": {"inputPerMTok": 15, "outputPerMTok": 75, "cacheReadPerMTok": 1.5, "cacheWritePerMTok": 18.75}
        """
        for index in 0..<25 { // clear the ≥20-model sanity guard
            models += ", \"filler-model-\(index)\": {\"inputPerMTok\": 1, \"outputPerMTok\": 2}"
        }
        if let extraModel {
            models += ", \"\(extraModel)\": {\"inputPerMTok\": 5, \"outputPerMTok\": 10}"
        }
        return """
        {"schemaVersion": 1, "generatedAt": "\(generatedAt)", "source": "test", "models": {\(models)}}
        """
    }

    @Test("refresh from a file URL loads, caches, and next launch uses the cache")
    func refreshAndCache() async throws {
        try await withTempDirectory { dir in
            let feedFile = dir.appending(path: "feed.json")
            try Data(feedJSON().utf8).write(to: feedFile)

            let service = PricingService(directory: dir)
            let refreshed = try #require(await service.refresh(from: feedFile, format: .tokenMeter))
            #expect(refreshed.status.origin == .remote)
            #expect(refreshed.table.models["claude-opus-4-8"]?.inputPerMTok == 15)

            // A fresh service in the same directory (── relaunch) starts
            // from the cached copy without touching the network.
            let relaunched = PricingService(directory: dir)
            let initial = try #require(await relaunched.loadInitial())
            #expect(initial.status.origin == .cached)
            #expect(initial.table == refreshed.table)
            #expect(await !relaunched.isDue) // fetched moments ago
        }
    }

    @Test("bad feed is rejected and current state kept")
    func rejectsBadFeed() async throws {
        try await withTempDirectory { dir in
            let service = PricingService(directory: dir)

            let tooFew = dir.appending(path: "few.json")
            try Data("""
            {"schemaVersion": 1, "generatedAt": "2026-07-16T00:00:00Z", "source": "t", "models": {"a": {"inputPerMTok": 1, "outputPerMTok": 2}}}
            """.utf8).write(to: tooFew)
            #expect(await service.refresh(from: tooFew, format: .tokenMeter) == nil)

            let futureSchema = dir.appending(path: "future.json")
            try Data(feedJSON().replacingOccurrences(of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 99").utf8)
                .write(to: futureSchema)
            #expect(await service.refresh(from: futureSchema, format: .tokenMeter) == nil)

            let missing = dir.appending(path: "nope.json")
            #expect(await service.refresh(from: missing, format: .tokenMeter) == nil)
        }
    }

    @Test("overrides persist across service instances")
    func overridesPersist() async throws {
        try await withTempDirectory { dir in
            let service = PricingService(directory: dir)
            let custom = ModelPricing(inputPerMTok: 42, outputPerMTok: 84)
            await service.saveOverrides(["my-model": custom])

            let relaunched = PricingService(directory: dir)
            let feedFile = dir.appending(path: "feed.json")
            try Data(feedJSON().utf8).write(to: feedFile)
            let result = try #require(await relaunched.refresh(from: feedFile, format: .tokenMeter))
            #expect(result.overrides["my-model"] == custom)
        }
    }

    @Test("isDue is true initially and after the refresh interval only")
    func refreshScheduling() async throws {
        try await withTempDirectory { dir in
            let service = PricingService(directory: dir)
            #expect(await service.isDue) // never fetched

            let feedFile = dir.appending(path: "feed.json")
            try Data(feedJSON().utf8).write(to: feedFile)
            _ = await service.refresh(from: feedFile, format: .tokenMeter)
            #expect(await !service.isDue)
        }
    }
}
