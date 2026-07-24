// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("Ollama support")
struct OllamaSupportTests {
    @Test("status check against a dead port reports not running / not installed")
    func deadServer() async {
        // Port 1 on loopback is never an Ollama server; the check must come
        // back fast with a graceful non-running state, never hang or throw.
        let client = OllamaStatusClient(baseURL: URL(string: "http://127.0.0.1:1")!)
        let server = await client.check()
        #expect(server == .notInstalled || server == .notRunning)
    }

    @Test("event timing computes tokens per second")
    func throughputMath() {
        let timing = EventTiming(totalDurationNanos: 5_000_000_000, evalDurationNanos: 4_000_000_000)
        #expect(timing.tokensPerSecond(outputTokens: 200) == 50)
        #expect(timing.tokensPerSecond(outputTokens: 0) == nil)
        #expect(EventTiming().tokensPerSecond(outputTokens: 10) == nil)
    }

    @Test("ollama events carry no cost and never flag as unpriced")
    func localModelsExemptFromPricing() {
        let ollamaEvent = UsageEvent(
            id: "ollama:x",
            provider: .ollama,
            accuracy: .measured,
            timestamp: .now,
            model: "llama3.2",
            project: nil,
            tokens: TokenCounts(input: 100, output: 500)
        )
        let totals = CostEngine.totals(for: [ollamaEvent], resolver: ResolvedPricing())
        #expect(totals.costIfAnyPriced == nil)
        #expect(totals.unpricedModels.isEmpty) // local ≠ unpriced gap
        #expect(!UsageProvider.ollama.isMetered)
        #expect(UsageProvider.claudeCode.isMetered)
    }
}
