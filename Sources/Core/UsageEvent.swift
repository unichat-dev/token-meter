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
    /// **Total** cache-creation (write) tokens, as reported by the provider's
    /// flat `cache_creation_input_tokens` field.
    var cacheCreation: Int = 0

    // Cache writes are billed by how long the entry lives: Anthropic charges
    // 1.25x base input for a 5-minute entry but 2x for a 1-hour one. The two
    // fields below **break down** `cacheCreation` — they are not additive with
    // it, and `total` deliberately ignores them so it can't double-count.
    // Sources that don't report the split leave both at zero and get billed at
    // the flat write rate.

    /// Portion of `cacheCreation` written with a 5-minute TTL.
    var cacheCreation5m: Int = 0
    /// Portion of `cacheCreation` written with a 1-hour TTL.
    var cacheCreation1h: Int = 0

    /// Cache-creation tokens the provider didn't attribute to a TTL tier.
    /// Billed at the flat write rate. Clamped at zero so a provider reporting
    /// tiers that overshoot the total can never produce negative cost.
    var cacheCreationUntiered: Int {
        max(0, cacheCreation - cacheCreation5m - cacheCreation1h)
    }

    var total: Int { input + output + cacheRead + cacheCreation }

    /// Accumulates every tier at once. Rollups use this rather than adding
    /// fields by hand, so a tier added later can't be silently dropped from a
    /// summary — which would understate cost the moment a summary is priced.
    static func += (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input += rhs.input
        lhs.output += rhs.output
        lhs.cacheRead += rhs.cacheRead
        lhs.cacheCreation += rhs.cacheCreation
        lhs.cacheCreation5m += rhs.cacheCreation5m
        lhs.cacheCreation1h += rhs.cacheCreation1h
    }

    /// Inverse of `+=`, so an aggregate can have a superseded event backed out
    /// of it without a full rebuild.
    static func -= (lhs: inout TokenCounts, rhs: TokenCounts) {
        lhs.input -= rhs.input
        lhs.output -= rhs.output
        lhs.cacheRead -= rhs.cacheRead
        lhs.cacheCreation -= rhs.cacheCreation
        lhs.cacheCreation5m -= rhs.cacheCreation5m
        lhs.cacheCreation1h -= rhs.cacheCreation1h
    }
}

/// Provider-side tool invocations billed **per request**, not per token
/// (Anthropic's server-side web search and web fetch tools).
struct ServerToolUse: Sendable, Codable, Equatable {
    var webSearchRequests: Int = 0
    /// Recorded for display only — Anthropic bills web fetch through the
    /// tokens it returns, with no separate per-request charge.
    var webFetchRequests: Int = 0

    var isEmpty: Bool { webSearchRequests == 0 && webFetchRequests == 0 }

    static func += (lhs: inout ServerToolUse, rhs: ServerToolUse) {
        lhs.webSearchRequests += rhs.webSearchRequests
        lhs.webFetchRequests += rhs.webFetchRequests
    }

    static func -= (lhs: inout ServerToolUse, rhs: ServerToolUse) {
        lhs.webSearchRequests -= rhs.webSearchRequests
        lhs.webFetchRequests -= rhs.webFetchRequests
    }
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

/// Where inside a coding session the usage came from.
///
/// Claude Code already records all of this per line; capturing it is what lets
/// the app answer "what did this branch cost" or "which subagent burns the most
/// tokens" — questions a per-model total can't touch. Every field is optional
/// because other providers report none of it.
struct UsageAttribution: Sendable, Codable, Equatable {
    /// The CLI session the turn belonged to.
    var sessionID: String?
    /// Git branch checked out at the time.
    var gitBranch: String?
    /// Subagent type that produced the turn (e.g. "general-purpose", "Explore").
    var agent: String?
    /// Skill in effect for the turn.
    var skill: String?
    /// Whether the turn ran on a sidechain — a subagent thread rather than the
    /// main conversation.
    var isSidechain: Bool = false

    var isEmpty: Bool {
        sessionID == nil && gitBranch == nil && agent == nil && skill == nil && !isSidechain
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
    /// Per-request server tool calls billed on top of tokens.
    let serverToolUse: ServerToolUse
    /// Session / branch / agent / skill context, where the source reports it.
    let attribution: UsageAttribution
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
        serverToolUse: ServerToolUse = ServerToolUse(),
        attribution: UsageAttribution = UsageAttribution(),
        timing: EventTiming? = nil
    ) {
        self.id = id
        self.provider = provider
        self.accuracy = accuracy
        self.timestamp = timestamp
        self.model = model
        self.project = project
        self.tokens = tokens
        self.serverToolUse = serverToolUse
        self.attribution = attribution
        self.timing = timing
    }
}
