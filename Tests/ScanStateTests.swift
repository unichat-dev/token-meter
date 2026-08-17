// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("ScanState persistence")
struct ScanStateTests {
    private func assistantLine(_ id: String, output: Int = 100) -> String {
        """
        {"type":"assistant","timestamp":"2026-08-01T10:00:00.000Z","cwd":"/Users/dev/p","requestId":"req_\(id)","message":{"id":"msg_\(id)","model":"claude-opus-5","usage":{"input_tokens":1,"output_tokens":\(output),"cache_read_input_tokens":0,"cache_creation_input_tokens":0}}}
        """
    }

    // MARK: - Store round-trip

    @Test("state round-trips through the store")
    func roundTrip() async throws {
        try await withTempDirectory { dir in
            let store = ScanStateStore(url: dir.appending(path: "scan.json"))
            var state = ScanState()
            state.files["/a/b.jsonl"] = ScanState.FileState(inode: 42, offset: 1_024)
            store.save(state)

            #expect(store.load() == state)
        }
    }

    @Test("a missing state file loads as empty, not as an error")
    func missingFile() async throws {
        try await withTempDirectory { dir in
            let store = ScanStateStore(url: dir.appending(path: "nope.json"))
            #expect(store.load().files.isEmpty)
        }
    }

    @Test("a corrupt state file degrades to a full re-scan")
    func corruptFile() async throws {
        try await withTempDirectory { dir in
            let url = dir.appending(path: "scan.json")
            try Data("this is not json".utf8).write(to: url)
            #expect(ScanStateStore(url: url).load().files.isEmpty)
        }
    }

    /// The safety valve for step 1: when the parser learns to read more from
    /// the same line, stored offsets must be thrown away so history gets
    /// re-parsed once and back-filled with the richer fields.
    @Test("a stale parser generation discards the stored offsets")
    func staleGenerationInvalidates() async throws {
        try await withTempDirectory { dir in
            let url = dir.appending(path: "scan.json")
            let store = ScanStateStore(url: url)

            var old = ScanState(generation: ScanState.currentGeneration - 1)
            old.files["/a/b.jsonl"] = ScanState.FileState(inode: 1, offset: 999)
            store.save(old)

            let loaded = store.load()
            #expect(loaded.files.isEmpty)
            #expect(loaded.generation == ScanState.currentGeneration)
        }
    }

    // MARK: - Source behaviour

    @Test("a second run resumes and re-yields nothing")
    func resumesWithoutReplaying() async throws {
        try await withTempDirectory { dir in
            let logs = dir.appending(path: "projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let file = logs.appending(path: "session.jsonl")
            try Data((assistantLine("a") + "\n" + assistantLine("b") + "\n").utf8).write(to: file)

            let store = ScanStateStore(url: dir.appending(path: "scan.json"))

            // First run: reads both lines and records the offset.
            let firstWatcher = ManualWatcher()
            let first = ClaudeCodeLogSource(
                locator: ClaudeCodeLogLocator(pathOverride: logs.path),
                watcher: firstWatcher,
                rootPollInterval: .milliseconds(50),
                stateStore: store
            )
            let firstCollector = EventCollector()
            await firstCollector.start(first.events())
            let firstEvents = try await firstCollector.waitForCount(2) { firstWatcher.tick() }
            #expect(firstEvents.count == 2)
            await firstCollector.stop()

            let saved = store.load()
            #expect(saved.files.count == 1)
            #expect((saved.files.values.first?.offset ?? 0) > 0)

            // Second run over unchanged files: nothing new to emit.
            let secondWatcher = ManualWatcher()
            let second = ClaudeCodeLogSource(
                locator: ClaudeCodeLogLocator(pathOverride: logs.path),
                watcher: secondWatcher,
                rootPollInterval: .milliseconds(50),
                stateStore: store
            )
            let secondCollector = EventCollector()
            await secondCollector.start(second.events())
            secondWatcher.tick()
            try await secondCollector.expectNoMoreThan(0)
            await secondCollector.stop()
        }
    }

    @Test("a resumed run still picks up lines appended since last time")
    func resumesAndReadsNewLines() async throws {
        try await withTempDirectory { dir in
            let logs = dir.appending(path: "projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let file = logs.appending(path: "session.jsonl")
            try Data((assistantLine("a") + "\n").utf8).write(to: file)

            let store = ScanStateStore(url: dir.appending(path: "scan.json"))

            let firstWatcher = ManualWatcher()
            let first = ClaudeCodeLogSource(
                locator: ClaudeCodeLogLocator(pathOverride: logs.path),
                watcher: firstWatcher,
                rootPollInterval: .milliseconds(50),
                stateStore: store
            )
            let firstCollector = EventCollector()
            await firstCollector.start(first.events())
            _ = try await firstCollector.waitForCount(1) { firstWatcher.tick() }
            await firstCollector.stop()

            // Append while "not running".
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((assistantLine("b") + "\n").utf8))
            try handle.close()

            let secondWatcher = ManualWatcher()
            let second = ClaudeCodeLogSource(
                locator: ClaudeCodeLogLocator(pathOverride: logs.path),
                watcher: secondWatcher,
                rootPollInterval: .milliseconds(50),
                stateStore: store
            )
            let secondCollector = EventCollector()
            await secondCollector.start(second.events())
            let events = try await secondCollector.waitForCount(1) { secondWatcher.tick() }
            // Only the appended line — the first is not replayed.
            #expect(events.count == 1)
            #expect(events.first?.id == "msg_b:req_b")
            await secondCollector.stop()
        }
    }

    @Test("a rotated file (new inode) is re-read from the start")
    func rotationForcesReread() async throws {
        try await withTempDirectory { dir in
            let logs = dir.appending(path: "projects", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let file = logs.appending(path: "session.jsonl")
            try Data((assistantLine("a") + "\n").utf8).write(to: file)

            let store = ScanStateStore(url: dir.appending(path: "scan.json"))
            let firstWatcher = ManualWatcher()
            let first = ClaudeCodeLogSource(
                locator: ClaudeCodeLogLocator(pathOverride: logs.path),
                watcher: firstWatcher,
                rootPollInterval: .milliseconds(50),
                stateStore: store
            )
            let firstCollector = EventCollector()
            await firstCollector.start(first.events())
            _ = try await firstCollector.waitForCount(1) { firstWatcher.tick() }
            await firstCollector.stop()

            // Replace the file with a fresh one at the same path (new inode).
            try FileManager.default.removeItem(at: file)
            try Data((assistantLine("c") + "\n").utf8).write(to: file)

            let secondWatcher = ManualWatcher()
            let second = ClaudeCodeLogSource(
                locator: ClaudeCodeLogLocator(pathOverride: logs.path),
                watcher: secondWatcher,
                rootPollInterval: .milliseconds(50),
                stateStore: store
            )
            let secondCollector = EventCollector()
            await secondCollector.start(second.events())
            let events = try await secondCollector.waitForCount(1) { secondWatcher.tick() }
            #expect(events.first?.id == "msg_c:req_c")
            await secondCollector.stop()
        }
    }
}
