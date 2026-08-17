// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The Claude Code data source: backfills existing JSONL logs, then follows
/// them live. A thin configuration over the shared ``JSONLLogWatchSource`` —
/// the watch/read loop is provider-agnostic; only the locator and parser
/// differ.
///
/// Every yielded event is `accuracy: .estimated` by construction (parser).
struct ClaudeCodeLogSource: UsageEventSource {
    nonisolated var provider: UsageProvider { .claudeCode }

    private let core: JSONLLogWatchSource

    /// - Parameter stateStore: persists read offsets between launches. Defaults
    ///   to the on-disk store; tests pass `nil` to stay hermetic.
    init(
        locator: ClaudeCodeLogLocator,
        watcher: any DirectoryWatching = FSEventsWatcher(),
        rootPollInterval: Duration = .seconds(10),
        stateStore: ScanStateStore? = ScanStateStore(provider: .claudeCode)
    ) {
        core = JSONLLogWatchSource(
            provider: .claudeCode,
            locator: locator,
            parser: ClaudeCodeLogParser(),
            watcher: watcher,
            rootPollInterval: rootPollInterval,
            stateStore: stateStore
        )
    }

    func events() -> AsyncThrowingStream<UsageEvent, Error> {
        core.events()
    }
}
