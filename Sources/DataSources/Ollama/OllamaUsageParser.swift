// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Extracts per-request usage from Ollama HTTP response bytes flowing
/// through the capture proxy.
///
/// Works on the raw response stream without full HTTP parsing: Ollama's
/// streaming endpoints flush one NDJSON object per chunk, so scanning
/// newline-delimited segments and attempting a lenient JSON decode on each
/// is robust in practice. Chunked-encoding size lines, headers, and partial
/// fragments simply fail to decode and are skipped. Handles:
/// - `/api/generate` + `/api/chat` — final object has `"done":true` plus
///   `prompt_eval_count` / `eval_count` / `*_duration` (nanoseconds)
/// - OpenAI-compat `/v1/*` — objects with a `usage` block, including
///   `data: `-prefixed SSE lines
///
/// Known caveat (surfaced in Settings copy): Ollama can report an inaccurate
/// or missing `prompt_eval_count` when the prompt exceeds the model's
/// context window. Counts are shown as measured, never billed.
final class OllamaUsageParser {
    struct ParsedUsage: Equatable, Sendable {
        var model: String?
        var promptTokens: Int
        var outputTokens: Int
        var totalDurationNanos: Int64?
        var evalDurationNanos: Int64?
    }

    /// Guards against unbounded growth if a response never contains a
    /// newline (binary blobs, huge single-line bodies we don't care about).
    private static let maxBufferedBytes = 1 << 20

    private var buffer = Data()
    private let decoder = JSONDecoder()

    /// Feed raw response bytes; returns any usage records completed by this
    /// fragment. Fragment boundaries are arbitrary — mid-JSON splits are fine.
    func consume(_ data: Data) -> [ParsedUsage] {
        buffer.append(data)

        var results: [ParsedUsage] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newlineIndex]
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
            if let usage = parse(line: Data(line)) {
                results.append(usage)
            }
        }

        if buffer.count > Self.maxBufferedBytes {
            buffer.removeAll(keepingCapacity: false)
        }
        return results
    }

    private func parse(line: Data) -> ParsedUsage? {
        guard !line.isEmpty else { return nil }

        var jsonData = line
        // Tolerate CR (chunked framing / SSE both use CRLF).
        if jsonData.last == 0x0D {
            jsonData.removeLast()
        }
        // OpenAI-compat streaming wraps objects as SSE: "data: {...}".
        if jsonData.starts(with: Data("data: ".utf8)) {
            jsonData.removeFirst(6)
        }
        // Cheap pre-filter: JSON objects only (skips headers, chunk sizes,
        // "data: [DONE]", blank framing lines).
        guard jsonData.first == UInt8(ascii: "{") else { return nil }

        guard let raw = try? decoder.decode(RawLine.self, from: jsonData) else { return nil }

        // Native endpoints: only the final object of a request carries counts.
        if raw.done == true, raw.evalCount != nil || raw.promptEvalCount != nil {
            return ParsedUsage(
                model: raw.model,
                promptTokens: raw.promptEvalCount ?? 0,
                outputTokens: raw.evalCount ?? 0,
                totalDurationNanos: raw.totalDuration,
                evalDurationNanos: raw.evalDuration
            )
        }
        // OpenAI-compat endpoints: a usage block (final SSE chunk or the
        // single non-streamed body).
        if let usage = raw.usage, usage.promptTokens != nil || usage.completionTokens != nil {
            return ParsedUsage(
                model: raw.model,
                promptTokens: usage.promptTokens ?? 0,
                outputTokens: usage.completionTokens ?? 0,
                totalDurationNanos: nil,
                evalDurationNanos: nil
            )
        }
        return nil
    }
}

// MARK: - Raw wire shapes (only the fields we read)

private struct RawLine: Decodable {
    var model: String?
    var done: Bool?
    var promptEvalCount: Int?
    var evalCount: Int?
    var totalDuration: Int64?
    var evalDuration: Int64?
    var usage: RawOpenAIUsage?

    enum CodingKeys: String, CodingKey {
        case model, done, usage
        case promptEvalCount = "prompt_eval_count"
        case evalCount = "eval_count"
        case totalDuration = "total_duration"
        case evalDuration = "eval_duration"
    }
}

private struct RawOpenAIUsage: Decodable {
    var promptTokens: Int?
    var completionTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
    }
}
