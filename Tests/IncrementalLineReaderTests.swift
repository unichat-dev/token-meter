// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("IncrementalLineReader")
struct IncrementalLineReaderTests {
    @Test("reads complete lines and leaves the partial tail unconsumed")
    func partialTail() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "log.jsonl")
            try Data("alpha\nbeta".utf8).write(to: file)

            let first = try IncrementalLineReader.readAppendedLines(at: file, from: 0)
            #expect(first.lines == [Data("alpha".utf8)])
            #expect(first.newOffset == 6) // after "alpha\n" — "beta" not consumed

            // The writer finishes the line, then appends another.
            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data("2\ngamma\n".utf8))
            try handle.close()

            let second = try IncrementalLineReader.readAppendedLines(at: file, from: first.newOffset)
            #expect(second.lines == [Data("beta2".utf8), Data("gamma".utf8)])
            #expect(second.newOffset == UInt64("alpha\nbeta2\ngamma\n".utf8.count))
        }
    }

    @Test("nothing new means no lines and an unchanged offset")
    func idempotentWhenUnchanged() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "log.jsonl")
            try Data("one\n".utf8).write(to: file)

            let first = try IncrementalLineReader.readAppendedLines(at: file, from: 0)
            let second = try IncrementalLineReader.readAppendedLines(at: file, from: first.newOffset)
            #expect(second.lines.isEmpty)
            #expect(second.newOffset == first.newOffset)
        }
    }

    @Test("truncated (rotated) file restarts from zero")
    func truncationResets() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "log.jsonl")
            try Data("a very long first generation line\n".utf8).write(to: file)
            let first = try IncrementalLineReader.readAppendedLines(at: file, from: 0)

            // Rotate: replace with a shorter file.
            try Data("fresh\n".utf8).write(to: file)
            let second = try IncrementalLineReader.readAppendedLines(at: file, from: first.newOffset)
            #expect(second.lines == [Data("fresh".utf8)])
            #expect(second.newOffset == 6)
        }
    }

    @Test("CRLF and blank lines are tolerated")
    func crlfAndBlankLines() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "log.jsonl")
            try Data("one\r\n\ntwo\n".utf8).write(to: file)

            let result = try IncrementalLineReader.readAppendedLines(at: file, from: 0)
            #expect(result.lines == [Data("one".utf8), Data("two".utf8)])
            #expect(result.newOffset == UInt64("one\r\n\ntwo\n".utf8.count))
        }
    }

    @Test("lines spanning chunk boundaries are reassembled")
    func longLines() async throws {
        try await withTempDirectory { dir in
            let file = dir.appending(path: "log.jsonl")
            // Longer than the 64 KiB read chunk.
            let long = String(repeating: "x", count: 200_000)
            try Data("\(long)\nshort\n".utf8).write(to: file)

            let result = try IncrementalLineReader.readAppendedLines(at: file, from: 0)
            #expect(result.lines.count == 2)
            #expect(result.lines[0].count == 200_000)
            #expect(result.lines[1] == Data("short".utf8))
        }
    }
}
