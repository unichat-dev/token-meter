// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

/// End-to-end Codex source test: fixture-backed temp directory + a manually
/// driven watcher. Confirms the Codex locator/parser wire correctly through
/// the shared ``JSONLLogWatchSource`` (backfill → live → dedupe).
@Suite("CodexLogSource")
struct CodexLogSourceTests {
    private func makeSource(root: URL, watcher: ManualWatcher) -> CodexLogSource {
        CodexLogSource(
            locator: CodexLogLocator(pathOverride: root.path),
            watcher: watcher,
            rootPollInterval: .milliseconds(50),
            // No persisted offsets: these tests must re-read their temp fixtures
            // from scratch, and must never touch the real Application Support.
            stateStore: nil
        )
    }

    private func tokenCountLine(timestamp: String, delta: Int) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\(delta),"cached_input_tokens":0,"output_tokens":0,"reasoning_output_tokens":0,"total_tokens":\(delta)}}}}
        """
    }

    private func appendLine(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    @Test("backfills existing rollout, then yields live-appended events")
    func backfillThenLive() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "2026/07/17/rollout-abc.jsonl")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let seed = [
                #"{"timestamp":"2026-07-17T09:00:00.000Z","type":"session_meta","payload":{"model":"gpt-5"}}"#,
                tokenCountLine(timestamp: "2026-07-17T09:00:05.000Z", delta: 100),
            ].joined(separator: "\n") + "\n"
            try seed.write(to: file, atomically: true, encoding: .utf8)

            let watcher = ManualWatcher()
            let source = makeSource(root: dir, watcher: watcher)
            let collector = EventCollector()
            await collector.start(source.events())

            let backfilled = try await collector.waitForCount(1, poke: { watcher.tick() })
            #expect(backfilled.first?.provider == .codexCLI)
            #expect(backfilled.first?.model == "gpt-5")
            #expect(backfilled.first?.accuracy == .estimated)

            try appendLine(tokenCountLine(timestamp: "2026-07-17T09:05:00.000Z", delta: 250), to: file)
            let live = try await collector.waitForCount(2, poke: { watcher.tick() })
            #expect(live.count == 2)

            await collector.stop()
        }
    }

    @Test("re-scanning the same lines never double-counts")
    func dedupeAcrossScans() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "rollout.jsonl")
            let seed = tokenCountLine(timestamp: "2026-07-17T10:00:00.000Z", delta: 42) + "\n"
            try seed.write(to: file, atomically: true, encoding: .utf8)

            let watcher = ManualWatcher()
            let source = makeSource(root: dir, watcher: watcher)
            let collector = EventCollector()
            await collector.start(source.events())

            _ = try await collector.waitForCount(1, poke: { watcher.tick() })
            // Several no-op ticks must not re-yield the already-seen event.
            try await collector.expectNoMoreThan(1)

            await collector.stop()
        }
    }
}
