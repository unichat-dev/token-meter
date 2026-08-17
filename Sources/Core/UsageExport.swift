// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Serializes usage events for export.
///
/// Everything Token Meter knows lives in a local database the user can't easily
/// query, which makes the data effectively trapped. Export is what turns it
/// into something you can expense, chart elsewhere, or hand to a finance team.
///
/// The estimated cost is written as a column rather than left to the reader to
/// recompute, so a spreadsheet doesn't need the pricing table — but it stays
/// labeled "estimated" in the header for the same reason it is everywhere else.
enum UsageExport {
    enum Format: String, CaseIterable, Identifiable, Sendable {
        case csv
        case json

        var id: String { rawValue }
        var fileExtension: String { rawValue }

        var label: String {
            switch self {
            case .csv: "CSV (spreadsheet)"
            case .json: "JSON"
            }
        }
    }

    /// One exported row. Mirrors ``UsageEvent`` plus the derived cost.
    private struct Row: Encodable {
        var timestamp: String
        var provider: String
        var accuracy: String
        var model: String
        var project: String?
        var sessionID: String?
        var gitBranch: String?
        var agent: String?
        var skill: String?
        var isSidechain: Bool
        var inputTokens: Int
        var outputTokens: Int
        var cacheReadTokens: Int
        var cacheCreationTokens: Int
        var cacheCreation5mTokens: Int
        var cacheCreation1hTokens: Int
        var webSearchRequests: Int
        var webFetchRequests: Int
        var totalTokens: Int
        /// `nil` when the model has no price — never fabricated as 0.
        var estimatedCostUSD: String?
    }

    private static let columns = [
        "timestamp", "provider", "accuracy", "model", "project",
        "session_id", "git_branch", "agent", "skill", "is_sidechain",
        "input_tokens", "output_tokens", "cache_read_tokens",
        "cache_creation_tokens", "cache_creation_5m_tokens",
        "cache_creation_1h_tokens", "web_search_requests", "web_fetch_requests",
        "total_tokens", "estimated_cost_usd",
    ]

    static func data(
        for events: [UsageEvent],
        format: Format,
        resolver: ResolvedPricing
    ) throws -> Data {
        let rows = events
            .sorted { $0.timestamp < $1.timestamp }
            .map { row(for: $0, resolver: resolver) }

        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return try encoder.encode(rows)
        case .csv:
            var text = columns.joined(separator: ",") + "\n"
            for row in rows {
                text += csvLine(row) + "\n"
            }
            return Data(text.utf8)
        }
    }

    private static func row(for event: UsageEvent, resolver: ResolvedPricing) -> Row {
        var cost: String?
        // Local models have no cost dimension at all — leaving the cell empty
        // is truthful, where "0.00" would imply a priced zero.
        if event.provider.isMetered, let pricing = resolver.pricing(for: event.model) {
            let amount = CostEngine.cost(
                tokens: event.tokens,
                pricing: pricing,
                serverToolUse: event.serverToolUse
            )
            cost = NSDecimalNumber(decimal: amount).stringValue
        }

        return Row(
            timestamp: event.timestamp.formatted(.iso8601),
            provider: event.provider.rawValue,
            accuracy: event.accuracy.rawValue,
            model: event.model,
            project: event.project,
            sessionID: event.attribution.sessionID,
            gitBranch: event.attribution.gitBranch,
            agent: event.attribution.agent,
            skill: event.attribution.skill,
            isSidechain: event.attribution.isSidechain,
            inputTokens: event.tokens.input,
            outputTokens: event.tokens.output,
            cacheReadTokens: event.tokens.cacheRead,
            cacheCreationTokens: event.tokens.cacheCreation,
            cacheCreation5mTokens: event.tokens.cacheCreation5m,
            cacheCreation1hTokens: event.tokens.cacheCreation1h,
            webSearchRequests: event.serverToolUse.webSearchRequests,
            webFetchRequests: event.serverToolUse.webFetchRequests,
            totalTokens: event.tokens.total,
            estimatedCostUSD: cost
        )
    }

    private static func csvLine(_ row: Row) -> String {
        [
            row.timestamp, row.provider, row.accuracy, row.model,
            row.project ?? "", row.sessionID ?? "", row.gitBranch ?? "",
            row.agent ?? "", row.skill ?? "", row.isSidechain ? "true" : "false",
            String(row.inputTokens), String(row.outputTokens),
            String(row.cacheReadTokens), String(row.cacheCreationTokens),
            String(row.cacheCreation5mTokens), String(row.cacheCreation1hTokens),
            String(row.webSearchRequests), String(row.webFetchRequests),
            String(row.totalTokens), row.estimatedCostUSD ?? "",
        ]
        .map(escape)
        .joined(separator: ",")
    }

    /// RFC 4180 quoting. Project paths and branch names can contain commas and
    /// quotes, and a leading `=`/`+`/`-`/`@` would be run as a formula by
    /// Excel and Numbers — so those get a leading apostrophe.
    private static func escape(_ value: String) -> String {
        var value = value
        if let first = value.first, "=+-@\t\r".contains(first) {
            value = "'" + value
        }
        guard value.contains(where: { ",\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Default filename for a range, e.g. `TokenMeter-2026-08-01_2026-08-31.csv`.
    static func suggestedFilename(
        for interval: DateInterval,
        format: Format,
        calendar: Calendar = .current
    ) -> String {
        // Built from components rather than a format style so the filename is
        // always ISO-ish regardless of the user's locale.
        func stamp(_ date: Date) -> String {
            let parts = calendar.dateComponents([.year, .month, .day], from: date)
            return String(
                format: "%04d-%02d-%02d",
                parts.year ?? 0, parts.month ?? 0, parts.day ?? 0
            )
        }
        let end = interval.end.addingTimeInterval(-1)
        return "TokenMeter-\(stamp(interval.start))_\(stamp(end)).\(format.fileExtension)"
    }
}
