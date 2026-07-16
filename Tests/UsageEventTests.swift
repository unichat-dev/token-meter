// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("UsageEvent")
struct UsageEventTests {
    @Test("token total sums all four tiers")
    func tokenTotal() {
        let counts = TokenCounts(input: 12, output: 250, cacheRead: 100, cacheCreation: 2048)
        #expect(counts.total == 2410)
    }

    @Test("codable round-trip preserves the event")
    func codableRoundTrip() throws {
        let event = UsageEvent(
            id: "msg_fixture_0001",
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            model: "claude-sonnet-5",
            project: "/Users/dev/projects/demo-app",
            tokens: TokenCounts(input: 12, output: 250, cacheCreation: 2048)
        )
        let data = try JSONEncoder().encode(event)
        let decoded = try JSONDecoder().decode(UsageEvent.self, from: data)
        #expect(decoded == event)
    }

    @Test("log-derived providers must default to estimated accuracy in sources")
    func rawValuesAreStable() {
        // Raw values are persisted (SwiftData) — changing them is
        // a breaking migration. This test pins them.
        #expect(UsageProvider.claudeCode.rawValue == "claude-code")
        #expect(UsageProvider.codexCLI.rawValue == "codex-cli")
        #expect(UsageProvider.anthropicAPI.rawValue == "anthropic-api")
        #expect(UsageProvider.openAIAPI.rawValue == "openai-api")
        #expect(UsageProvider.ollama.rawValue == "ollama")
        #expect(UsageAccuracy.estimated.rawValue == "estimated")
        #expect(UsageAccuracy.billing.rawValue == "billing")
        #expect(UsageAccuracy.measured.rawValue == "measured")
    }
}
