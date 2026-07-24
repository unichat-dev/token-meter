// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Codex CLI data source: backfills existing rollout logs, then follows
/// them live. Like ``ClaudeCodeLogSource``, a thin configuration over the
/// shared ``JSONLLogWatchSource`` — same offset/inode-aware incremental
/// reading and Full Disk Access handling, a Codex-specific locator + parser.
///
/// Every yielded event is `accuracy: .estimated` by construction (parser).
struct CodexLogSource: UsageEventSource {
    nonisolated var provider: UsageProvider { .codexCLI }

    private let core: JSONLLogWatchSource

    init(
        locator: CodexLogLocator,
        watcher: any DirectoryWatching = FSEventsWatcher(),
        rootPollInterval: Duration = .seconds(10)
    ) {
        core = JSONLLogWatchSource(
            provider: .codexCLI,
            locator: locator,
            parser: CodexLogParser(),
            watcher: watcher,
            rootPollInterval: rootPollInterval
        )
    }

    func events() -> AsyncThrowingStream<UsageEvent, Error> {
        core.events()
    }
}
