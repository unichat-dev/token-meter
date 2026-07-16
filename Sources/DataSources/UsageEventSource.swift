// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Contract every usage data source implements — the Claude Code log
/// watcher today; Ollama, the vendor usage APIs, and Codex logs as they
/// come online.
///
/// Sources emit normalized ``UsageEvent`` values through an async stream so
/// consumers (persistence + live UI) get both backfill and near-real-time
/// updates through one interface, regardless of whether the underlying
/// mechanism is a file watcher or a polling loop.
protocol UsageEventSource: Sendable {
    /// Stable identifier for diagnostics and per-source enable/disable.
    var provider: UsageProvider { get }

    /// Starts the source and returns its event stream. The stream first
    /// yields any backfill (e.g. existing log lines past the last ingested
    /// offset), then live events. Finishing the stream stops the source.
    func events() -> AsyncThrowingStream<UsageEvent, Error>
}
