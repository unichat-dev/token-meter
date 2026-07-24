// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// Locates a provider's JSONL log tree. Shared by the Claude Code and Codex
/// CLI sources (both keep append-only `*.jsonl` session logs on disk).
protocol JSONLLogLocating: Sendable {
    /// Where the logs live (honoring any user path override).
    var rootURL: URL { get }
    /// Every `*.jsonl` file under `root`, in a deterministic order.
    func jsonlFiles(under root: URL) -> [URL]
}

extension JSONLLogLocating {
    /// Default enumeration — recursive, regular files only, path-sorted so a
    /// session's lines are always read contiguously in one scan.
    func jsonlFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            if isRegular == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }
}

/// Turns one raw JSONL line into a ``UsageEvent`` (or `nil` to skip it).
///
/// The owning ``JSONLLogWatchSource`` is an actor and calls this serially, so
/// a conforming parser may keep per-scan state (e.g. the last-seen model)
/// even when marked `@unchecked Sendable`.
protocol UsageLineParsing: Sendable {
    func event(from line: Data) -> UsageEvent?
}

/// Generic "backfill then follow" source for append-only JSONL logs.
///
/// Pipeline per scan: locate `*.jsonl` files → read only appended complete
/// lines (offset + inode tracked) → parse → dedupe by event id → yield.
///
/// - Offsets are in-memory per run; re-reading after relaunch is safe because
///   ingestion dedupes by event id (and the history DB makes it durable).
/// - If the logs root doesn't exist yet, the source polls for it to appear.
/// - Rename-rotation (new inode) and in-place truncation both restart at 0.
actor JSONLLogWatchSource: UsageEventSource {
    nonisolated let provider: UsageProvider

    private let root: URL
    private let locator: any JSONLLogLocating
    private let parser: any UsageLineParsing
    private let watcher: any DirectoryWatching
    private let rootPollInterval: Duration

    private struct FileIngestState {
        var inode: UInt64?
        var offset: UInt64
    }

    private var fileStates: [String: FileIngestState] = [:]
    private var seenEventIDs: Set<String> = []
    private var skippedLineCount = 0

    init(
        provider: UsageProvider,
        locator: any JSONLLogLocating,
        parser: any UsageLineParsing,
        watcher: any DirectoryWatching = FSEventsWatcher(),
        rootPollInterval: Duration = .seconds(10)
    ) {
        self.provider = provider
        self.locator = locator
        self.root = locator.rootURL
        self.parser = parser
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
        // the tool has never run / isn't installed).
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
                result = try IncrementalLineReader.readAppendedLines(at: file, from: startOffset)
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
                "\(self.provider.rawValue, privacy: .public) scan: \(newEvents) new events, \(self.skippedLineCount) lines skipped total"
            )
        }
    }

    private static func inode(of url: URL) -> UInt64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.systemFileNumber] as? NSNumber)?.uint64Value
    }
}
