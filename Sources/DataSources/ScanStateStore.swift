// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// How far into each log file we've already read.
///
/// Without this, every launch re-read every byte of the log tree and re-parsed
/// every line, only for the id-dedupe to throw nearly all of it away — hundreds
/// of megabytes of I/O and JSON decoding to learn nothing. Persisting the
/// offsets makes a warm start proportional to what's actually new.
struct ScanState: Codable, Equatable, Sendable {
    /// Bumped whenever the parser starts extracting **more** from the same log
    /// line. A stored state from an older generation is discarded so the next
    /// launch re-reads everything once and back-fills the richer fields into
    /// history; ingestion upserts by event id, so the replay is idempotent.
    ///
    /// Generation history:
    /// - 1: original four token fields.
    /// - 2: cache-write TTL split + server tool request counts.
    /// - 3: session / branch / agent / skill attribution.
    static let currentGeneration = 3

    struct FileState: Codable, Equatable, Sendable {
        var inode: UInt64?
        var offset: UInt64
    }

    var generation: Int
    /// Absolute file path → how far we read.
    var files: [String: FileState]

    init(generation: Int = ScanState.currentGeneration, files: [String: FileState] = [:]) {
        self.generation = generation
        self.files = files
    }
}

/// Loads and saves a provider's ``ScanState``.
///
/// Failures are never fatal: a missing, corrupt or stale file simply means a
/// full re-scan, which is correct, just slower.
struct ScanStateStore: Sendable {
    private let url: URL

    /// - Parameter provider: scopes the file, so Claude Code and Codex keep
    ///   independent offsets.
    init?(provider: UsageProvider) {
        guard let directory = try? Persistence.storeDirectoryURL() else { return nil }
        self.url = directory.appending(path: "scan-state-\(provider.rawValue).json")
    }

    init(url: URL) {
        self.url = url
    }

    func load() -> ScanState {
        guard
            let data = try? Data(contentsOf: url),
            let state = try? JSONDecoder().decode(ScanState.self, from: data)
        else { return ScanState() }

        guard state.generation == ScanState.currentGeneration else {
            Logger.dataSources.info(
                "scan state generation \(state.generation) != \(ScanState.currentGeneration) — re-reading logs once"
            )
            return ScanState()
        }
        return state
    }

    func save(_ state: ScanState) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let data = try JSONEncoder().encode(state)
            try data.write(to: url, options: .atomic)
        } catch {
            // Losing the offsets costs a re-scan, nothing more.
            Logger.dataSources.warning("saving scan state failed: \(error, privacy: .public)")
        }
    }
}
