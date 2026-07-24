// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Parses Codex CLI rollout JSONL into ``UsageEvent`` values.
///
/// Codex logs each session as an append-only stream of typed records. Token
/// usage arrives in `token_count` event records whose `info.last_token_usage`
/// holds the **incremental** counts for that turn (summing the deltas across a
/// session reproduces the session total — using the cumulative
/// `total_token_usage` per record would over-count). The model id is announced
/// earlier in the session (`session_meta` / `turn_context`) and doesn't repeat
/// on every usage record, so this parser carries the last-seen model forward.
///
/// The owning ``JSONLLogWatchSource`` is an actor and calls `event(from:)`
/// serially per scan, and files are read contiguously in path order, so the
/// per-session model context is well-defined. That serial access is why the
/// mutable `currentModel` is safe under `@unchecked Sendable`.
///
/// All produced events are ``UsageAccuracy/estimated`` — like Claude Code
/// logs, these local counts are known to under-report.
final class CodexLogParser: UsageLineParsing, @unchecked Sendable {
    private let decoder = JSONDecoder()
    /// Last model announced in the current session; used until superseded.
    private var currentModel: String?

    func event(from line: Data) -> UsageEvent? {
        guard !line.isEmpty else { return nil }
        guard let raw = try? decoder.decode(RawCodexLine.self, from: line) else {
            return nil // malformed line — skip, never crash
        }

        // Track the model as sessions announce it (meta / turn-context lines).
        if let announced = raw.model
            ?? raw.payload?.model
            ?? raw.payload?.info?.model,
           !announced.isEmpty {
            currentModel = announced
        }

        // Only records that carry a per-turn usage delta produce events.
        guard let usage = Self.turnUsage(from: raw),
              let timestampString = raw.timestamp,
              let timestamp = Self.parseTimestamp(timestampString)
        else { return nil }

        let cached = usage.cached_input_tokens ?? 0
        let input = usage.input_tokens ?? 0
        let tokens = TokenCounts(
            // Codex reports cached tokens as a subset of input_tokens; split
            // them into our uncached-input and cache-read tiers.
            input: max(0, input - cached),
            output: (usage.output_tokens ?? 0) + (usage.reasoning_output_tokens ?? 0),
            cacheRead: cached,
            cacheCreation: 0
        )
        guard tokens.total > 0 else { return nil } // no-op record

        // Deterministic id (survives relaunch → idempotent, no double count):
        // timestamp + the turn's total. A runtime counter would change across
        // restarts and duplicate in the history DB.
        let id = "codex:\(timestampString):\(tokens.total)"

        return UsageEvent(
            id: id,
            provider: .codexCLI,
            accuracy: .estimated,
            timestamp: timestamp,
            model: currentModel ?? "unknown",
            project: nil,
            tokens: tokens
        )
    }

    /// The incremental usage for this record, if it is a usage-bearing line.
    private static func turnUsage(from raw: RawCodexLine) -> RawTokenUsage? {
        if raw.payload?.type == "token_count", let info = raw.payload?.info {
            // Prefer the per-turn delta; only fall back to total when a record
            // omits the delta (rare) — better a possible over-count than a gap.
            return info.last_token_usage ?? info.total_token_usage
        }
        // Some Codex builds attach a `usage` block directly to a response item.
        return raw.payload?.usage
    }

    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainISO8601 = Date.ISO8601FormatStyle()

    private static func parseTimestamp(_ string: String) -> Date? {
        if let date = try? fractionalISO8601.parse(string) { return date }
        return try? plainISO8601.parse(string)
    }
}

// MARK: - Raw Codex schema (only the fields we read; unknown keys ignored)

private struct RawCodexLine: Decodable {
    var timestamp: String?
    var type: String?
    var model: String?
    var payload: Payload?
}

private struct Payload: Decodable {
    var type: String?
    var model: String?
    var info: Info?
    var usage: RawTokenUsage?
}

private struct Info: Decodable {
    var model: String?
    var last_token_usage: RawTokenUsage?
    var total_token_usage: RawTokenUsage?
}

private struct RawTokenUsage: Decodable {
    var input_tokens: Int?
    var cached_input_tokens: Int?
    var output_tokens: Int?
    var reasoning_output_tokens: Int?
    var total_tokens: Int?
}
