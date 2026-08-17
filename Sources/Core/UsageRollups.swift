// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// One reconstructed 5-hour usage block.
///
/// **This is an estimate.** Claude's real 5-hour window is not exposed by any
/// API; we reconstruct plausible block boundaries from log
/// timestamps the way ccusage does: a block starts with the first event after
/// the previous block ended, floored to the full UTC hour, and lasts exactly
/// five wall-clock hours. UI must never present this as authoritative quota.
struct UsageBlock: Sendable, Equatable {
    var start: Date
    var end: Date
    var tokens = TokenCounts()
    var eventCount = 0
    var lastEventAt: Date?

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}

/// Pure rollup math over `UsageEvent`s: 5-hour blocks, daily and weekly
/// aggregation. No I/O, no hidden clock reads — callers pass `now`/calendars,
/// which keeps timezone/DST behavior testable.
enum UsageRollups {
    /// Claude's usage window length. Wall-clock seconds on purpose: the real
    /// window is "5 hours from first message", which does not stretch or
    /// shrink across DST transitions.
    static let blockDuration: TimeInterval = 5 * 60 * 60

    /// Floors to the full UTC hour (epoch hours == UTC hours), matching how
    /// ccusage anchors block starts.
    static func floorToUTCHour(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// Reconstructs consecutive blocks from (possibly unsorted) events.
    static func blocks(
        from events: [UsageEvent],
        blockDuration: TimeInterval = UsageRollups.blockDuration
    ) -> [UsageBlock] {
        let sorted = events.sorted { $0.timestamp < $1.timestamp }
        var blocks: [UsageBlock] = []

        for event in sorted {
            if var current = blocks.last, current.contains(event.timestamp) {
                current.tokens += event.tokens
                current.eventCount += 1
                current.lastEventAt = event.timestamp
                blocks[blocks.count - 1] = current
            } else {
                let start = floorToUTCHour(event.timestamp)
                var block = UsageBlock(start: start, end: start.addingTimeInterval(blockDuration))
                block.tokens = event.tokens
                block.eventCount = 1
                block.lastEventAt = event.timestamp
                blocks.append(block)
            }
        }
        return blocks
    }

    /// The block covering `now`, if usage is ongoing. `nil` means idle — the
    /// next message would start a fresh block.
    static func activeBlock(in blocks: [UsageBlock], now: Date) -> UsageBlock? {
        // Only the last block can contain `now`: blocks are chronological and
        // a new one only starts after the previous ended.
        blocks.last.flatMap { $0.contains(now) ? $0 : nil }
    }

    /// The largest completed block total — an honest, self-derived reference
    /// for progress display ("vs. your highest past block"). Excludes the
    /// active block so progress against it can't be trivially 100%.
    static func peakBlockTokens(in blocks: [UsageBlock], now: Date) -> Int {
        blocks
            .filter { !$0.contains(now) }
            .map(\.tokens.total)
            .max() ?? 0
    }

    /// Sums events inside the calendar week containing `date` (locale-aware:
    /// week start and timezone come from `calendar`).
    static func weekly(
        from events: [UsageEvent],
        containing date: Date,
        calendar: Calendar
    ) -> UsageSummary {
        guard let week = calendar.dateInterval(of: .weekOfYear, for: date) else {
            return .empty
        }
        var summary = UsageSummary()
        for event in events where week.contains(event.timestamp) && event.timestamp != week.end {
            summary.include(event)
        }
        return summary
    }
}
