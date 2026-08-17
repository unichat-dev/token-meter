// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("ClaudeCodeLogParser")
struct ClaudeCodeLogParserTests {
    private let parser = ClaudeCodeLogParser()

    @Test("basic fixture yields exactly the assistant events with usage")
    func basicFixture() throws {
        let lines = try Fixtures.lines("claude-code/session-basic.jsonl")
        let events = lines.compactMap { parser.event(from: $0) }

        #expect(lines.count == 6) // 3 user + 3 assistant
        #expect(events.count == 3)

        let first = try #require(events.first)
        #expect(first.id == "msg_fixture_0001:req_fixture_0001")
        #expect(first.provider == .claudeCode)
        #expect(first.accuracy == .estimated) // honesty guardrail
        #expect(first.model == "claude-sonnet-5")
        #expect(first.project == "/Users/dev/projects/demo-app")
        #expect(first.tokens == TokenCounts(
            input: 12, output: 250, cacheRead: 0, cacheCreation: 2048
        ))

        let expectedTimestamp = try Date.ISO8601FormatStyle(includingFractionalSeconds: true)
            .parse("2026-07-01T09:58:40.000Z")
        #expect(first.timestamp == expectedTimestamp)

        // Third event exercises a different model.
        #expect(events[2].model == "claude-opus-4-8")
        #expect(events[2].tokens.total == 25 + 1330 + 4096)
    }

    @Test("user lines produce no event")
    func userLinesSkipped() throws {
        let lines = try Fixtures.lines("claude-code/session-basic.jsonl")
        let userLine = try #require(lines.first) // first fixture line is a user event
        #expect(parser.event(from: userLine) == nil)
    }

    @Test("malformed line is skipped, not fatal")
    func malformedLine() {
        let garbage = Data("this line is not valid JSON at all".utf8)
        #expect(parser.event(from: garbage) == nil)
        #expect(parser.event(from: Data()) == nil)
    }

    @Test("assistant line without usage block is skipped")
    func missingUsage() throws {
        let lines = try Fixtures.lines("claude-code/session-edge-cases.jsonl")
        let events = lines.compactMap { parser.event(from: $0) }
        // Fixture: valid event + garbage line + no-usage line + duplicate-id
        // line (parser doesn't dedupe — the source does) + truncated line.
        #expect(events.count == 2)
        #expect(events.allSatisfy { $0.id == "msg_fixture_0010:req_fixture_0010" })
    }

    @Test("timestamp without fractional seconds still parses")
    func plainTimestamp() {
        let line = Data("""
        {"type":"assistant","timestamp":"2026-07-02T08:00:00Z","requestId":"req_x","message":{"id":"msg_x","model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":2}}}
        """.utf8)
        let event = parser.event(from: line)
        #expect(event != nil)
        #expect(event?.tokens == TokenCounts(input: 1, output: 2))
    }

    @Test("synthetic model messages are skipped")
    func syntheticSkipped() {
        let line = Data("""
        {"type":"assistant","timestamp":"2026-07-02T08:00:00Z","message":{"id":"msg_s","model":"<synthetic>","usage":{"input_tokens":0,"output_tokens":0}}}
        """.utf8)
        #expect(parser.event(from: line) == nil)
    }

    @Test("missing ids make the line unidentifiable — skipped")
    func missingIDs() {
        let line = Data("""
        {"type":"assistant","timestamp":"2026-07-02T08:00:00Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1,"output_tokens":2}}}
        """.utf8)
        #expect(parser.event(from: line) == nil)
    }

    // MARK: - Cache TTL split + server tools

    @Test("nested cache_creation splits into 5m and 1h tiers")
    func cacheTiersParsed() throws {
        let lines = try Fixtures.lines("claude-code/session-cache-tiers.jsonl")
        let events = lines.compactMap { parser.event(from: $0) }
        #expect(events.count == 4)

        let split = try #require(events.first)
        #expect(split.tokens.cacheCreation == 1_000_000) // flat field stays the total
        #expect(split.tokens.cacheCreation5m == 250_000)
        #expect(split.tokens.cacheCreation1h == 750_000)
        #expect(split.tokens.cacheCreationUntiered == 0)
        // The breakdown must not inflate the headline token count.
        #expect(split.tokens.total == 40 + 500 + 2_000_000 + 1_000_000)
    }

    @Test("server tool requests are captured, search and fetch separately")
    func serverToolsParsed() throws {
        let lines = try Fixtures.lines("claude-code/session-cache-tiers.jsonl")
        let events = lines.compactMap { parser.event(from: $0) }

        #expect(events[1].serverToolUse == ServerToolUse(webSearchRequests: 3, webFetchRequests: 2))
        #expect(events[0].serverToolUse.isEmpty)
    }

    @Test("legacy lines without the nested breakdown keep zeroed tiers")
    func legacyFlatCacheField() throws {
        let lines = try Fixtures.lines("claude-code/session-cache-tiers.jsonl")
        let events = lines.compactMap { parser.event(from: $0) }

        let legacy = events[2]
        #expect(legacy.tokens.cacheCreation == 80_000)
        #expect(legacy.tokens.cacheCreation5m == 0)
        #expect(legacy.tokens.cacheCreation1h == 0)
        // Everything falls into the untiered bucket → base-rate billing.
        #expect(legacy.tokens.cacheCreationUntiered == 80_000)
        #expect(legacy.serverToolUse.isEmpty)
    }

    // MARK: - Attribution

    @Test("session, branch, agent, skill and sidechain are captured")
    func attributionParsed() {
        let line = Data("""
        {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","cwd":"/Users/dev/p","requestId":"req_x","sessionId":"11111111-2222-4333-8444-555555555555","gitBranch":"feature/checkout","attributionAgent":"general-purpose","attributionSkill":"premium-web-experience","isSidechain":true,"message":{"id":"msg_x","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}
        """.utf8)
        let event = parser.event(from: line)
        #expect(event?.attribution.sessionID == "11111111-2222-4333-8444-555555555555")
        #expect(event?.attribution.gitBranch == "feature/checkout")
        #expect(event?.attribution.agent == "general-purpose")
        #expect(event?.attribution.skill == "premium-web-experience")
        #expect(event?.attribution.isSidechain == true)
    }

    @Test("lines without attribution yield an empty attribution, not blanks")
    func attributionAbsent() {
        let line = Data("""
        {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","requestId":"req_y","message":{"id":"msg_y","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}
        """.utf8)
        let attribution = parser.event(from: line)?.attribution
        #expect(attribution?.isEmpty == true)
        #expect(attribution?.isSidechain == false)
    }

    /// An empty string would become a real-looking "" row in the breakdown
    /// charts, so blanks have to normalize to nil.
    @Test("blank attribution strings normalize to nil")
    func blankAttributionNormalized() {
        let line = Data("""
        {"type":"assistant","timestamp":"2026-08-01T10:00:00Z","requestId":"req_z","gitBranch":"","attributionSkill":"   ","message":{"id":"msg_z","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":2}}}
        """.utf8)
        let attribution = parser.event(from: line)?.attribution
        #expect(attribution?.gitBranch == nil)
        #expect(attribution?.skill == nil)
    }

    @Test("breakdown without the flat total still yields the right total")
    func breakdownSuppliesTotal() throws {
        let lines = try Fixtures.lines("claude-code/session-cache-tiers.jsonl")
        let events = lines.compactMap { parser.event(from: $0) }

        let derived = events[3]
        #expect(derived.tokens.cacheCreation == 10_000) // 4k + 6k
        #expect(derived.tokens.cacheCreation5m == 4_000)
        #expect(derived.tokens.cacheCreation1h == 6_000)
        #expect(derived.tokens.cacheCreationUntiered == 0)
    }
}
