// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Parses one Claude Code JSONL log line into a ``UsageEvent``.
///
/// Only assistant messages carrying a `usage` block produce events; user
/// lines, tool results, synthetic messages, and malformed lines return `nil`.
/// Never log the line contents — log lines embed user prompts.
///
/// All produced events are ``UsageAccuracy/estimated``: these logs are known
/// to under-report tokens.
struct ClaudeCodeLogParser: UsageLineParsing {
    private let decoder = JSONDecoder()

    init() {}

    func event(from line: Data) -> UsageEvent? {
        guard !line.isEmpty else { return nil }
        guard let raw = try? decoder.decode(RawLogLine.self, from: line) else {
            return nil // malformed line — skip, never crash
        }
        guard
            raw.type == "assistant",
            let message = raw.message,
            let usage = message.usage,
            let timestampString = raw.timestamp,
            let timestamp = Self.parseTimestamp(timestampString),
            let id = Self.eventID(raw: raw, message: message)
        else { return nil }

        let model = message.model ?? "unknown"
        // Synthetic placeholder messages carry no real usage.
        guard model != "<synthetic>" else { return nil }

        // Built stepwise rather than inline: the optional-chaining chains below
        // are cheap to read but expensive for the type checker in one literal.
        let breakdown = usage.cacheCreation
        let cacheCreationTotal: Int = usage.cacheCreationInputTokens ?? breakdown?.total ?? 0

        var tokens = TokenCounts()
        tokens.input = usage.inputTokens ?? 0
        tokens.output = usage.outputTokens ?? 0
        tokens.cacheRead = usage.cacheReadInputTokens ?? 0
        // The flat field stays the total. When the nested breakdown is absent
        // (older logs) both TTL tiers stay zero and the whole amount bills at
        // the base write rate, exactly as before.
        tokens.cacheCreation = cacheCreationTotal
        tokens.cacheCreation5m = breakdown?.ephemeral5mInputTokens ?? 0
        tokens.cacheCreation1h = breakdown?.ephemeral1hInputTokens ?? 0

        var serverTools = ServerToolUse()
        serverTools.webSearchRequests = usage.serverToolUse?.webSearchRequests ?? 0
        serverTools.webFetchRequests = usage.serverToolUse?.webFetchRequests ?? 0

        var attribution = UsageAttribution()
        attribution.sessionID = Self.normalized(raw.sessionId)
        attribution.gitBranch = Self.normalized(raw.gitBranch)
        // `attributionAgent` names the subagent type; `agentId` is only an
        // opaque instance id, so it's not a useful grouping key on its own.
        attribution.agent = Self.normalized(raw.attributionAgent)
        attribution.skill = Self.normalized(raw.attributionSkill)
        attribution.isSidechain = raw.isSidechain ?? false

        return UsageEvent(
            id: id,
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: timestamp,
            model: model,
            project: raw.cwd,
            tokens: tokens,
            serverToolUse: serverTools,
            attribution: attribution
        )
    }

    /// Treats empty/whitespace strings as absent, so blank fields don't become
    /// a real-looking "" grouping key in the breakdowns.
    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// Streaming can log the same message id across several lines (one per
    /// API response chunk); `messageID:requestID` disambiguates, matching how
    /// ccusage dedupes. Falls back to the line's own uuid.
    private static func eventID(raw: RawLogLine, message: RawMessage) -> String? {
        if let messageID = message.id {
            if let requestID = raw.requestId {
                return "\(messageID):\(requestID)"
            }
            return messageID
        }
        return raw.uuid
    }

    // ISO8601 with and without fractional seconds — logs use fractional
    // ("2026-07-01T09:58:40.000Z") but don't rely on it.
    private static let fractionalISO8601 = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
    private static let plainISO8601 = Date.ISO8601FormatStyle()

    private static func parseTimestamp(_ string: String) -> Date? {
        if let date = try? fractionalISO8601.parse(string) { return date }
        return try? plainISO8601.parse(string)
    }
}

// MARK: - Raw log schema (only the fields we read)

private struct RawLogLine: Decodable {
    var type: String?
    var timestamp: String?
    var cwd: String?
    var uuid: String?
    var requestId: String?
    var message: RawMessage?

    // Attribution context — present on Claude Code lines, absent elsewhere.
    var sessionId: String?
    var gitBranch: String?
    var attributionAgent: String?
    var attributionSkill: String?
    var isSidechain: Bool?
}

private struct RawMessage: Decodable {
    var id: String?
    var model: String?
    var usage: RawUsage?
}

private struct RawUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheReadInputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheCreation: RawCacheCreation?
    var serverToolUse: RawServerToolUse?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheCreation = "cache_creation"
        case serverToolUse = "server_tool_use"
    }
}

/// Cache writes split by entry TTL — the 1-hour tier is billed higher than the
/// 5-minute one, so the split is a price input, not a detail.
private struct RawCacheCreation: Decodable {
    var ephemeral5mInputTokens: Int?
    var ephemeral1hInputTokens: Int?

    /// Fallback total for logs that carry the breakdown but not the flat field.
    var total: Int {
        (ephemeral5mInputTokens ?? 0) + (ephemeral1hInputTokens ?? 0)
    }

    enum CodingKeys: String, CodingKey {
        case ephemeral5mInputTokens = "ephemeral_5m_input_tokens"
        case ephemeral1hInputTokens = "ephemeral_1h_input_tokens"
    }
}

/// Provider-side tool calls billed per request rather than per token.
private struct RawServerToolUse: Decodable {
    var webSearchRequests: Int?
    var webFetchRequests: Int?

    enum CodingKeys: String, CodingKey {
        case webSearchRequests = "web_search_requests"
        case webFetchRequests = "web_fetch_requests"
    }
}
