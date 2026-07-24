// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Where a usage event came from. Every provider integration maps into this.
enum UsageProvider: String, Sendable, Codable, CaseIterable {
    case claudeCode = "claude-code"  // ~/.claude JSONL logs
    case codexCLI = "codex-cli"      // Codex local logs
    case anthropicAPI = "anthropic-api" // Anthropic Usage & Cost API
    case openAIAPI = "openai-api"    // OpenAI Usage API + Costs endpoint
    case ollama = "ollama"           // local Ollama REST API

    /// Whether usage from this provider has a monetary dimension. Local
    /// models don't — their events carry exact token counts but must never
    /// show up as "unpriced" gaps in cost totals.
    var isMetered: Bool {
        self != .ollama
    }
}

/// How trustworthy a number is. This distinction is a product requirement
/// of this app: local-log numbers are known to
/// under-report and must surface as **estimated** everywhere in the UI;
/// API-sourced numbers are billing-grade.
enum UsageAccuracy: String, Sendable, Codable {
    /// Derived from local CLI logs — display with an "estimated" label.
    case estimated
    /// Reported by a provider's usage/cost API — reconciles to the invoice.
    case billing
    /// Exact token counts but no cost dimension (local models via Ollama).
    case measured
}

/// Token counts for a single usage event, mirroring the per-message `usage`
/// block in provider responses. All fields default to zero because sources
/// report different subsets (e.g. Ollama has no cache tiers).
struct TokenCounts: Sendable, Codable, Equatable {
    var input: Int = 0
    var output: Int = 0
    var cacheRead: Int = 0
    var cacheCreation: Int = 0

    var total: Int { input + output + cacheRead + cacheCreation }
}

/// Request timing, reported by local runtimes (Ollama). Nanoseconds, as the
/// API reports them. Session-scoped: shown live for latency/throughput but
/// not persisted with the event history.
struct EventTiming: Sendable, Codable, Equatable {
    var totalDurationNanos: Int64?
    var evalDurationNanos: Int64?

    /// Generation speed for `outputTokens` produced in `evalDurationNanos`.
    func tokensPerSecond(outputTokens: Int) -> Double? {
        guard let evalDurationNanos, evalDurationNanos > 0, outputTokens > 0 else { return nil }
        return Double(outputTokens) / (Double(evalDurationNanos) / 1_000_000_000)
    }
}

/// One normalized usage event — the shared currency between data sources,
/// persistence, rollups, and UI. SwiftData models persist this
/// shape; sources emit it.
struct UsageEvent: Sendable, Codable, Equatable, Identifiable {
    /// Stable identity used for idempotent ingestion (dedupe on re-scan) —
    /// e.g. the provider message id, or a source-defined composite key.
    let id: String
    let provider: UsageProvider
    let accuracy: UsageAccuracy
    let timestamp: Date
    /// Provider model identifier as reported (e.g. "claude-opus-4-8").
    let model: String
    /// Grouping context, e.g. the Claude Code project directory. Optional
    /// because API- and Ollama-sourced events have no project notion.
    let project: String?
    let tokens: TokenCounts
    /// Latency/throughput info where the source reports it (Ollama).
    var timing: EventTiming?

    init(
        id: String,
        provider: UsageProvider,
        accuracy: UsageAccuracy,
        timestamp: Date,
        model: String,
        project: String?,
        tokens: TokenCounts,
        timing: EventTiming? = nil
    ) {
        self.id = id
        self.provider = provider
        self.accuracy = accuracy
        self.timestamp = timestamp
        self.model = model
        self.project = project
        self.tokens = tokens
        self.timing = timing
    }
}
