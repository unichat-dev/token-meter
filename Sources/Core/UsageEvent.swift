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
}
