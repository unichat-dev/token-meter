// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("UsageHistoryStore")
struct UsageHistoryStoreTests {
    private func makeStore() throws -> UsageHistoryStore {
        UsageHistoryStore(modelContainer: try UsageHistoryStore.makeInMemoryContainer())
    }

    private func event(id: String, output: Int = 10, project: String? = "/Users/dev/projects/demo-app") -> UsageEvent {
        UsageEvent(
            id: id,
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            model: "claude-sonnet-5",
            project: project,
            // Carries the V2 columns too, so `roundTrip` proves the cache TTL
            // split and server-tool counts survive a store round-trip.
            tokens: TokenCounts(
                input: 5,
                output: output,
                cacheRead: 1,
                cacheCreation: 200,
                cacheCreation5m: 50,
                cacheCreation1h: 150
            ),
            serverToolUse: ServerToolUse(webSearchRequests: 4, webFetchRequests: 6),
            // V3 columns too, so `roundTrip` proves attribution persists.
            attribution: UsageAttribution(
                sessionID: "11111111-2222-4333-8444-555555555555",
                gitBranch: "feature/checkout",
                agent: "general-purpose",
                skill: "premium-web-experience",
                isSidechain: true
            )
        )
    }

    @Test("round-trips every field")
    func roundTrip() async throws {
        let store = try makeStore()
        let original = event(id: "msg_a:req_a")
        try await store.ingest([original])

        let loaded = try await store.loadAll()
        #expect(loaded == [original])
    }

    @Test("re-ingesting the same events does not duplicate (idempotent)")
    func idempotentIngest() async throws {
        let store = try makeStore()
        let batch = [event(id: "msg_a:req_a"), event(id: "msg_b:req_b")]

        try await store.ingest(batch)
        try await store.ingest(batch) // relaunch re-scan
        try await store.ingest([batch[0]]) // partial replay

        #expect(try await store.storedEventCount() == 2)
    }

    @Test("same id with newer data upserts instead of duplicating")
    func upsert() async throws {
        let store = try makeStore()
        try await store.ingest([event(id: "msg_a:req_a", output: 10)])
        try await store.ingest([event(id: "msg_a:req_a", output: 99)])

        let loaded = try await store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded.first?.tokens.output == 99)
    }

    @Test("loadAll returns oldest first")
    func sortedLoad() async throws {
        let store = try makeStore()
        var older = event(id: "old")
        older = UsageEvent(
            id: older.id, provider: older.provider, accuracy: older.accuracy,
            timestamp: Date(timeIntervalSince1970: 1_000),
            model: older.model, project: older.project, tokens: older.tokens
        )
        try await store.ingest([event(id: "new"), older])

        let loaded = try await store.loadAll()
        #expect(loaded.map(\.id) == ["old", "new"])
    }

    @Test("empty batch is a no-op")
    func emptyBatch() async throws {
        let store = try makeStore()
        try await store.ingest([])
        #expect(try await store.storedEventCount() == 0)
    }
}
