// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import CoreServices
import Foundation

/// Abstraction over "something under this directory changed" so the log
/// source can be tested with a manually-driven watcher instead of real
/// (timing-sensitive) FSEvents.
protocol DirectoryWatching: Sendable {
    /// Coalesced change ticks for the subtree rooted at `directory`.
    /// The stream ends when the consumer cancels.
    func changes(in directory: URL) -> AsyncStream<Void>
}

/// FSEvents-backed watcher (recursive, kernel-level, cheap). Ticks are
/// coalesced by `latency` seconds, so a burst of log writes triggers one
/// rescan instead of dozens.
struct FSEventsWatcher: DirectoryWatching {
    var latency: TimeInterval = 0.5

    func changes(in directory: URL) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let box = CallbackBox(continuation: continuation)
            let info = Unmanaged.passRetained(box).toOpaque()
            var context = FSEventStreamContext(
                version: 0,
                info: info,
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<CallbackBox>.fromOpaque(info)
                    .takeUnretainedValue()
                    .continuation
                    .yield(())
            }

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                callback,
                &context,
                [directory.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
            ) else {
                Unmanaged<CallbackBox>.fromOpaque(info).release()
                continuation.finish()
                return
            }

            let queue = DispatchQueue(
                label: "com.unichatdigital.tokenmeter.fsevents",
                qos: .utility
            )
            FSEventStreamSetDispatchQueue(stream, queue)
            FSEventStreamStart(stream)

            let handle = StreamHandle(stream: stream, info: info)
            continuation.onTermination = { _ in
                handle.stop()
            }
        }
    }
}

/// Carries the stream continuation across the C callback boundary.
private final class CallbackBox: Sendable {
    let continuation: AsyncStream<Void>.Continuation
    init(continuation: AsyncStream<Void>.Continuation) {
        self.continuation = continuation
    }
}

/// Owns the FSEventStream lifecycle; `stop()` is idempotent and thread-safe
/// (`onTermination` can fire from any thread).
private final class StreamHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private var info: UnsafeMutableRawPointer?

    init(stream: FSEventStreamRef, info: UnsafeMutableRawPointer) {
        self.stream = stream
        self.info = info
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        guard let stream, let info else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        Unmanaged<CallbackBox>.fromOpaque(info).release()
        self.stream = nil
        self.info = nil
    }
}
