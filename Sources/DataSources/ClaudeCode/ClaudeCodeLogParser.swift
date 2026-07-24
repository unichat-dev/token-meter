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

        return UsageEvent(
            id: id,
            provider: .claudeCode,
            accuracy: .estimated,
            timestamp: timestamp,
            model: model,
            project: raw.cwd,
            tokens: TokenCounts(
                input: usage.inputTokens ?? 0,
                output: usage.outputTokens ?? 0,
                cacheRead: usage.cacheReadInputTokens ?? 0,
                cacheCreation: usage.cacheCreationInputTokens ?? 0
            )
        )
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

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
    }
}
