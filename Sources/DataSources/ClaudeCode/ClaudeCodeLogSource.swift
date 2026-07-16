// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// The Claude Code data source: backfills existing JSONL logs,
/// then follows them live.
///
/// Pipeline per scan: locate `*.jsonl` files → read only appended complete
/// lines (offset-tracked) → parse → dedupe by event id → yield.
///
/// - Offsets are in-memory per run; re-reading after relaunch is safe because
///   ingestion dedupes by event id (and the history DB makes it durable).
/// - If the logs root doesn't exist yet (Claude Code not installed, or
///   installed mid-session), the source polls for it to appear, then starts.
/// - Every yielded event is `accuracy: .estimated` by construction (parser).
actor ClaudeCodeLogSource: UsageEventSource {
    nonisolated var provider: UsageProvider { .claudeCode }

    private let root: URL
    private let locator: ClaudeCodeLogLocator
    private let watcher: any DirectoryWatching
    private let rootPollInterval: Duration

    /// Per-file read position + the inode it belongs to. If the inode
    /// changes (file replaced via rename-rotation), the offset is void and
    /// reading restarts from 0; in-place truncation is caught separately by
    /// the reader's size check.
    private struct FileIngestState {
        var inode: UInt64?
        var offset: UInt64
    }

    private var fileStates: [String: FileIngestState] = [:]
    private var seenEventIDs: Set<String> = []
    private var skippedLineCount = 0

    init(
        locator: ClaudeCodeLogLocator,
        watcher: any DirectoryWatching = FSEventsWatcher(),
        rootPollInterval: Duration = .seconds(10)
    ) {
        self.locator = locator
        self.root = locator.rootURL
        self.watcher = watcher
        self.rootPollInterval = rootPollInterval
    }

    nonisolated func events() -> AsyncThrowingStream<UsageEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task { await self.run(continuation) }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Run loop

    private func run(_ continuation: AsyncThrowingStream<UsageEvent, Error>.Continuation) async {
        // Wait for the logs root to exist (poll slowly — this only spins when
        // Claude Code has never run).
        while !FileManager.default.fileExists(atPath: root.path) {
            do {
                try await Task.sleep(for: rootPollInterval)
            } catch {
                continuation.finish()
                return // cancelled
            }
        }

        scanAll(into: continuation) // backfill

        for await _ in watcher.changes(in: root) {
            if Task.isCancelled { break }
            scanAll(into: continuation)
        }
        continuation.finish()
    }

    /// One pass over every log file, reading only bytes appended since the
    /// last pass. Cheap when idle: enumeration + a size check per file.
    private func scanAll(into continuation: AsyncThrowingStream<UsageEvent, Error>.Continuation) {
        let parser = ClaudeCodeLogParser()
        var newEvents = 0

        for file in locator.jsonlFiles(under: root) {
            let key = file.standardizedFileURL.path
            let inode = Self.inode(of: file)

            var startOffset = fileStates[key]?.offset ?? 0
            if let previous = fileStates[key], previous.inode != inode {
                startOffset = 0 // file was replaced (rename rotation)
            }

            let result: IncrementalLineReader.ReadResult
            do {
                result = try IncrementalLineReader.readAppendedLines(
                    at: file,
                    from: startOffset
                )
            } catch {
                // Unreadable file (racing deletion, permissions) — skip this
                // pass; the next change tick retries.
                continue
            }
            fileStates[key] = FileIngestState(inode: inode, offset: result.newOffset)

            for line in result.lines {
                guard let event = parser.event(from: line) else {
                    skippedLineCount += 1
                    continue
                }
                guard seenEventIDs.insert(event.id).inserted else { continue }
                newEvents += 1
                continuation.yield(event)
            }
        }

        if newEvents > 0 {
            // Counts only — never line contents (they embed user prompts).
            Logger.dataSources.debug(
                "claude-code scan: \(newEvents) new events, \(self.skippedLineCount) lines skipped total"
            )
        }
    }

    private static func inode(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
