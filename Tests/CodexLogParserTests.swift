// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("CodexLogParser")
struct CodexLogParserTests {
    @Test("basic session: token_count deltas become estimated events")
    func basicFixture() throws {
        let parser = CodexLogParser()
        let lines = try Fixtures.lines("codex/session-basic.jsonl")
        let events = lines.compactMap { parser.event(from: $0) }

        #expect(lines.count == 4) // meta + response_item + 2 token_count
        #expect(events.count == 2) // only the two usage-bearing records

        let first = try #require(events.first)
        #expect(first.provider == .codexCLI)
        #expect(first.accuracy == .estimated) // honesty guardrail
        #expect(first.model == "gpt-5-codex") // carried from the session_meta line
        // input_tokens includes cached; we split cached into the cache-read tier
        // and fold reasoning tokens into output.
        #expect(first.tokens == TokenCounts(
            input: 1000, output: 350, cacheRead: 200, cacheCreation: 0
        ))
        #expect(first.id == "codex:2026-07-05T12:00:05.000Z:1550")

        let expectedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse("2026-07-05T12:00:05.000Z")
        #expect(first.timestamp == expectedTimestamp)

        // Second event uses the *delta* (last_token_usage), not the cumulative
        // total — summing deltas must reproduce the session total.
        #expect(events[1].tokens == TokenCounts(
            input: 600, output: 230, cacheRead: 200, cacheCreation: 0
        ))
    }

    @Test("edge cases: malformed, zero-usage, direct usage block, total fallback")
    func edgeCases() throws {
        let parser = CodexLogParser()
        let lines = try Fixtures.lines("codex/session-edge-cases.jsonl")
        let events = lines.compactMap { parser.event(from: $0) }

        // meta (skip) + malformed (skip) + zero-usage (skip) + usable ×2
        #expect(events.count == 2)

        // A response_item carrying a `usage` block directly is accepted.
        let direct = try #require(events.first)
        #expect(direct.model == "gpt-5")
        #expect(direct.tokens == TokenCounts(
            input: 400, output: 120, cacheRead: 100, cacheCreation: 0
        ))

        // A record with only a cumulative total (no delta) falls back to it.
        #expect(events[1].tokens == TokenCounts(
            input: 900, output: 210, cacheRead: 0, cacheCreation: 0
        ))
    }

    @Test("malformed lines never crash and produce no event")
    func malformedSkipped() {
        let parser = CodexLogParser()
        #expect(parser.event(from: Data("not json".utf8)) == nil)
        #expect(parser.event(from: Data()) == nil)
    }

    @Test("event ids are deterministic (idempotent across relaunch)")
    func deterministicIDs() throws {
        let line = try #require(try Fixtures.lines("codex/session-basic.jsonl").dropFirst(2).first)
        let a = CodexLogParser().event(from: line)
        let b = CodexLogParser().event(from: line)
        #expect(a?.id == b?.id)
        #expect(a?.id != nil)
    }
}
