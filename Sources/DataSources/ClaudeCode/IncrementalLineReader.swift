// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Append-aware file reading: returns only the **complete** lines written
/// since a previous offset, so callers never re-parse whole files and never
/// see half-written lines.
///
/// Robustness contract:
/// - **Partial last line** (no trailing `\n` yet): not consumed; the returned
///   offset stays at the end of the last complete line, so the line is picked
///   up whole on a later read.
/// - **Rotated/truncated file** (size shrank below the stored offset): starts
///   over from 0. Idempotent ingestion (event-id dedupe upstream, DB dedupe
///   in the DB) makes the re-read safe.
/// - Reads in fixed-size chunks — memory stays bounded regardless of file size.
enum IncrementalLineReader {
    struct ReadResult: Equatable {
        var lines: [Data]
        var newOffset: UInt64
    }

    private static let chunkSize = 64 * 1024

    static func readAppendedLines(at url: URL, from offset: UInt64) throws -> ReadResult {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        let size = try handle.seekToEnd()
        var start = offset
        if size < start {
            start = 0 // file was rotated or truncated — start over
        }
        guard size > start else {
            return ReadResult(lines: [], newOffset: start)
        }

        try handle.seek(toOffset: start)

        var lines: [Data] = []
        var pending: [UInt8] = []
        var consumed = start

        while let chunk = try handle.read(upToCount: Self.chunkSize), !chunk.isEmpty {
            pending.append(contentsOf: chunk)
            var lineStart = 0
            for index in (pending.count - chunk.count)..<pending.count where pending[index] == 0x0A {
                var line = Array(pending[lineStart..<index])
                if line.last == 0x0D { line.removeLast() } // tolerate CRLF
                if !line.isEmpty {
                    lines.append(Data(line))
                }
                consumed += UInt64(index - lineStart + 1)
                lineStart = index + 1
            }
            pending.removeFirst(lineStart)
        }
        // `pending` now holds an incomplete trailing line (if any) — not
        // consumed, not counted into `consumed`.
        return ReadResult(lines: lines, newOffset: consumed)
    }
}
