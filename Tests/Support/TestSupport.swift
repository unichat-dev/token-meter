// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
@testable import TokenMeter

/// Loads sanitized fixtures from the repo's `fixtures/` directory (resolved
/// relative to this source file, so it works locally and in CI checkouts).
enum Fixtures {
    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // Support
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
            .appending(path: "fixtures", directoryHint: .isDirectory)
    }

    static func url(_ relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath))
    }

    /// Non-empty lines of a fixture, split on `\n`.
    static func lines(_ relativePath: String) throws -> [Data] {
        let newline = UInt8(ascii: "\n")
        return try data(relativePath)
            .split(whereSeparator: { $0 == newline })
            .map { Data($0) }
            .filter { !$0.isEmpty }
    }
}

/// Creates a unique temp directory for a test and removes it afterwards.
func withTempDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
    let dir = FileManager.default.temporaryDirectory
        .appending(path: "tokenmeter-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    return try await body(dir)
}

struct TimeoutError: Error, CustomStringConvertible {
    let description: String
}

/// Collects events from a source's stream in the background; tests poll
/// `waitForCount` instead of racing stream iterators.
actor EventCollector {
    private var events: [UsageEvent] = []
    private var streamError: Error?
    private var task: Task<Void, Never>?

    func start(_ stream: AsyncThrowingStream<UsageEvent, Error>) {
        task = Task {
            do {
                for try await event in stream {
                    self.append(event)
                }
            } catch {
                self.fail(error)
            }
        }
    }

    func stop() {
        task?.cancel()
    }

    private func append(_ event: UsageEvent) { events.append(event) }
    private func fail(_ error: Error) { streamError = error }

    func snapshot() -> [UsageEvent] { events }

    /// Polls until at least `count` events arrived, invoking `poke` between
    /// polls (used to re-tick a manual watcher without racing subscription).
    func waitForCount(
        _ count: Int,
        timeout: Duration = .seconds(5),
        poke: @Sendable () -> Void = {}
    ) async throws -> [UsageEvent] {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let streamError { throw streamError }
            if events.count >= count { return events }
            poke()
            try await Task.sleep(for: .milliseconds(50))
        }
        throw TimeoutError(
            description: "expected \(count) events, got \(events.count) within \(timeout)"
        )
    }

    /// Asserts the count stays below `count` for the whole `window`.
    func expectNoMoreThan(_ count: Int, for window: Duration = .milliseconds(500)) async throws {
        try await Task.sleep(for: window)
        if events.count > count {
            throw TimeoutError(description: "expected at most \(count) events, got \(events.count)")
        }
    }
}

/// Deterministic watcher for source tests — fires when the test says so.
final class ManualWatcher: DirectoryWatching, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<Void>.Continuation?

    func changes(in directory: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            self.lock.withLock { self.continuation = continuation }
        }
    }

    func tick() {
        lock.withLock { continuation }?.yield(())
    }
}
