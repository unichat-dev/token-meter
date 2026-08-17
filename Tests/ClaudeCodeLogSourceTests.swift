// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

/// End-to-end source tests: fixture-backed temp directory + a manually
/// driven watcher, so nothing depends on FSEvents timing.
@Suite("ClaudeCodeLogSource")
struct ClaudeCodeLogSourceTests {
    private func makeSource(root: URL, watcher: ManualWatcher) -> ClaudeCodeLogSource {
        ClaudeCodeLogSource(
            locator: ClaudeCodeLogLocator(pathOverride: root.path),
            watcher: watcher,
            rootPollInterval: .milliseconds(50),
            // No persisted offsets: these tests must re-read their temp fixtures
            // from scratch, and must never touch the real Application Support.
            stateStore: nil
        )
    }

    private func appendLine(_ line: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func fixtureEventLine(id: String, timestamp: String = "2026-07-03T10:00:00.000Z") -> String {
        """
        {"type":"assistant","timestamp":"\(timestamp)","cwd":"/Users/dev/projects/demo-app","requestId":"req_\(id)","message":{"id":"msg_\(id)","model":"claude-sonnet-5","usage":{"input_tokens":5,"output_tokens":10,"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
    }

    @Test("backfills existing logs, then yields live-appended events")
    func backfillThenLive() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "project/session.jsonl")
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try Fixtures.data("claude-code/session-basic.jsonl").write(to: file)

            let watcher = ManualWatcher()
            let source = makeSource(root: dir, watcher: watcher)
            let collector = EventCollector()
            await collector.start(source.events())
            defer { Task { await collector.stop() } }

            // Backfill: the 3 assistant events from the fixture.
            let backfill = try await collector.waitForCount(3)
            #expect(backfill.count == 3)
            #expect(backfill.allSatisfy { $0.accuracy == .estimated })

            // Live append → watcher tick → new event.
            try appendLine(fixtureEventLine(id: "live_0001"), to: file)
            let live = try await collector.waitForCount(4, poke: { watcher.tick() })
            #expect(live.count == 4)
            #expect(live.last?.id == "msg_live_0001:req_live_0001")
        }
    }

    @Test("duplicate lines are deduped by event id")
    func dedupe() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "session.jsonl")
            let line = fixtureEventLine(id: "dup_0001")
            try Data((line + "\n" + line + "\n").utf8).write(to: file)

            let watcher = ManualWatcher()
            let source = makeSource(root: dir, watcher: watcher)
            let collector = EventCollector()
            await collector.start(source.events())
            defer { Task { await collector.stop() } }

            _ = try await collector.waitForCount(1)
            // Append the same line a third time — still no new event.
            try appendLine(line, to: file)
            for _ in 0..<3 { watcher.tick() }
            try await collector.expectNoMoreThan(1)
        }
    }

    @Test("partial line is not ingested until completed")
    func partialWrite() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "session.jsonl")
            try Data("".utf8).write(to: file)

            let watcher = ManualWatcher()
            let source = makeSource(root: dir, watcher: watcher)
            let collector = EventCollector()
            await collector.start(source.events())
            defer { Task { await collector.stop() } }

            // Write half a line (no newline) — must not produce an event.
            let full = fixtureEventLine(id: "partial_0001")
            let half = String(full.prefix(80))
            let handle = try FileHandle(forWritingTo: file)
            try handle.write(contentsOf: Data(half.utf8))
            try handle.close()

            for _ in 0..<3 { watcher.tick() }
            try await collector.expectNoMoreThan(0)

            // Complete the line — now it arrives, parsed whole.
            let rest = String(full.dropFirst(80)) + "\n"
            let handle2 = try FileHandle(forWritingTo: file)
            try handle2.seekToEnd()
            try handle2.write(contentsOf: Data(rest.utf8))
            try handle2.close()

            let events = try await collector.waitForCount(1, poke: { watcher.tick() })
            #expect(events.first?.id == "msg_partial_0001:req_partial_0001")
        }
    }

    @Test("rename-rotated file (same size, new inode) is re-read from the start")
    func renameRotation() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "session.jsonl")
            try Data((fixtureEventLine(id: "gen1_0001") + "\n").utf8).write(to: file)

            let watcher = ManualWatcher()
            let source = makeSource(root: dir, watcher: watcher)
            let collector = EventCollector()
            await collector.start(source.events())
            defer { Task { await collector.stop() } }

            _ = try await collector.waitForCount(1)

            // Atomic rewrite = temp file + rename → same path, same byte
            // count (ids differ only in the generation digit), NEW inode.
            // Catches the case a size-only check misses.
            try Data((fixtureEventLine(id: "gen2_0001") + "\n").utf8)
                .write(to: file, options: .atomic)
            let events = try await collector.waitForCount(2, poke: { watcher.tick() })
            #expect(events.map(\.id).contains("msg_gen2_0001:req_gen2_0001"))
        }
    }

    @Test("truncate-rotated file (shrunk in place) is re-read from the start")
    func truncateRotation() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "session.jsonl")
            let padding = fixtureEventLine(id: "gen1_0001") + "\n" + fixtureEventLine(id: "gen1_0002") + "\n"
            try Data(padding.utf8).write(to: file)

            let watcher = ManualWatcher()
            let source = makeSource(root: dir, watcher: watcher)
            let collector = EventCollector()
            await collector.start(source.events())
            defer { Task { await collector.stop() } }

            _ = try await collector.waitForCount(2)

            // Truncate in place to a single shorter line (same inode).
            let handle = try FileHandle(forWritingTo: file)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: Data((fixtureEventLine(id: "gen2_0001") + "\n").utf8))
            try handle.close()

            let events = try await collector.waitForCount(3, poke: { watcher.tick() })
            #expect(events.map(\.id).contains("msg_gen2_0001:req_gen2_0001"))
        }
    }

    @Test("waits for a missing root to appear, then backfills")
    func lateRootCreation() async throws {
        try await withTempDirectory { dir in
            let root = dir.appending(path: "not-yet-created")

            let watcher = ManualWatcher()
            let source = makeSource(root: root, watcher: watcher)
            let collector = EventCollector()
            await collector.start(source.events())
            defer { Task { await collector.stop() } }

            try await collector.expectNoMoreThan(0, for: .milliseconds(150))

            // Root appears with a log file — the source picks it up.
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try Data((fixtureEventLine(id: "late_0001") + "\n").utf8)
                .write(to: root.appending(path: "session.jsonl"))

            let events = try await collector.waitForCount(1, timeout: .seconds(5))
            #expect(events.first?.id == "msg_late_0001:req_late_0001")
        }
    }
}
