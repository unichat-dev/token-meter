// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

/// Integration test for the real FSEvents wrapper. Kept to one generous-
/// timeout test so CI stays reliable; the log-source behavior itself is
/// covered deterministically with `ManualWatcher`.
@Suite("FSEventsWatcher")
struct FSEventsWatcherTests {
    @Test("delivers a change tick when a file is written under the root")
    func deliversTick() async throws {
        try await withTempDirectory { dir in
            let watcher = FSEventsWatcher(latency: 0.1)
            let stream = watcher.changes(in: dir)

            let ticked = Flag()
            let consumer = Task {
                for await _ in stream {
                    await ticked.set()
                    break
                }
            }
            defer { consumer.cancel() }

            // Give the stream a beat to start, then write.
            try await Task.sleep(for: .milliseconds(300))
            try Data("hello\n".utf8).write(to: dir.appending(path: "new.jsonl"))

            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(5))
            while clock.now < deadline {
                if await ticked.isSet { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            Issue.record("no FSEvents tick within 5s")
        }
    }
}

private actor Flag {
    private(set) var isSet = false
    func set() { isSet = true }
}
