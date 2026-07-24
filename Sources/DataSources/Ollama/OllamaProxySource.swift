// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Network
import os

/// Local capture proxy for Ollama (the Ollama data source).
///
/// Ollama has no usage-history API — token counts exist only inside each
/// response. So TokenMeter listens on a local port, relays every byte to the
/// real server untouched, and reads `prompt_eval_count` / `eval_count` out of
/// the responses as they pass through. Apps opt in by pointing their Ollama
/// base URL at the proxy port (e.g. `http://127.0.0.1:11435`).
///
/// Security posture:
/// - Binds **loopback only** — the proxy is never reachable from the network.
/// - Pure relay: bytes are forwarded verbatim, requests are not inspected
///   (prompts stay private; we only scan responses for count fields), and
///   nothing but token counts + timings leaves this class.
///
/// Events are `accuracy: .measured` — exact counts from the runtime, with no
/// cost dimension (local models are free by nature).
final class OllamaProxySource: UsageEventSource, @unchecked Sendable {
    var provider: UsageProvider { .ollama }

    private let listenPort: UInt16
    private let upstreamHost: NWEndpoint.Host
    private let upstreamPort: NWEndpoint.Port
    private let queue = DispatchQueue(label: "com.unichatdigital.tokenmeter.ollama-proxy", qos: .utility)
    private let lock = NSLock()
    private var listener: NWListener?

    init(listenPort: UInt16, upstreamHost: String, upstreamPort: UInt16) {
        self.listenPort = listenPort
        self.upstreamHost = NWEndpoint.Host(upstreamHost)
        self.upstreamPort = NWEndpoint.Port(rawValue: upstreamPort) ?? 11434
    }

    func events() -> AsyncThrowingStream<UsageEvent, Error> {
        AsyncThrowingStream { continuation in
            do {
                try start(continuation)
            } catch {
                continuation.finish(throwing: error)
                return
            }
            continuation.onTermination = { _ in
                self.stop()
            }
        }
    }

    // MARK: - Listener

    private func start(_ continuation: AsyncThrowingStream<UsageEvent, Error>.Continuation) throws {
        let parameters = NWParameters.tcp
        // Loopback only: never expose the proxy to the local network.
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: listenPort) ?? 11435
        )
        let listener = try NWListener(using: parameters)

        listener.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                // Typically the port is already taken.
                continuation.finish(throwing: error)
            }
        }
        listener.newConnectionHandler = { [weak self] client in
            self?.handle(client: client, continuation: continuation)
        }
        listener.start(queue: queue)

        lock.lock()
        self.listener = listener
        lock.unlock()
    }

    private func stop() {
        lock.lock()
        listener?.cancel()
        listener = nil
        lock.unlock()
    }

    // MARK: - Per-connection relay

    /// Response-side scanner for one connection. `@unchecked Sendable` is
    /// sound because each connection's callbacks all run on the proxy's one
    /// serial queue — the parser is never touched concurrently.
    private final class ResponseTap: @unchecked Sendable {
        private let parser = OllamaUsageParser()
        private let continuation: AsyncThrowingStream<UsageEvent, Error>.Continuation

        init(continuation: AsyncThrowingStream<UsageEvent, Error>.Continuation) {
            self.continuation = continuation
        }

        func scan(_ data: Data) {
            for usage in parser.consume(data) {
                continuation.yield(OllamaProxySource.event(from: usage))
            }
        }
    }

    private func handle(
        client: NWConnection,
        continuation: AsyncThrowingStream<UsageEvent, Error>.Continuation
    ) {
        let upstream = NWConnection(host: upstreamHost, port: upstreamPort, using: .tcp)
        // One scanner per connection: keep-alive responses arrive
        // sequentially on the same stream, which the line scanner handles.
        let tap = ResponseTap(continuation: continuation)

        client.start(queue: queue)
        upstream.start(queue: queue)

        // Client → server: forward verbatim. Requests are not parsed —
        // prompts are none of our business.
        relay(from: client, to: upstream, tap: nil)

        // Server → client: forward verbatim, scanning for usage records.
        relay(from: upstream, to: client, tap: tap)
    }

    /// Pumps bytes one receive at a time; the next receive is only scheduled
    /// after the forward completes, so backpressure propagates naturally.
    private func relay(
        from source: NWConnection,
        to destination: NWConnection,
        tap: ResponseTap?
    ) {
        // Strong capture is intentional: the closure chain lives exactly as
        // long as the connection; cancelling both ends releases everything.
        source.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) {
            data, _, isComplete, error in
            if let data, !data.isEmpty {
                tap?.scan(data)
                destination.send(content: data, completion: .contentProcessed { _ in
                    self.relay(from: source, to: destination, tap: tap)
                })
                return
            }
            if isComplete || error != nil {
                source.cancel()
                destination.cancel()
                return
            }
            self.relay(from: source, to: destination, tap: tap)
        }
    }

    private static func event(from usage: OllamaUsageParser.ParsedUsage) -> UsageEvent {
        UsageEvent(
            // Responses are observed live, exactly once — a UUID-based id is
            // stable enough for dedupe and DB idempotency.
            id: "ollama:\(UUID().uuidString)",
            provider: .ollama,
            accuracy: .measured,
            timestamp: .now,
            model: usage.model ?? "unknown",
            project: nil,
            tokens: TokenCounts(
                input: usage.promptTokens,
                output: usage.outputTokens
            ),
            timing: EventTiming(
                totalDurationNanos: usage.totalDurationNanos,
                evalDurationNanos: usage.evalDurationNanos
            )
        )
    }
}
