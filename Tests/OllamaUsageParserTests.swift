// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("OllamaUsageParser")
struct OllamaUsageParserTests {
    private let finalGenerateChunk = """
    {"model":"llama3.2","created_at":"2026-07-16T10:00:00Z","response":"","done":true,"done_reason":"stop","total_duration":4935886791,"load_duration":534986708,"prompt_eval_count":26,"prompt_eval_duration":107345000,"eval_count":298,"eval_duration":4289432000}
    """

    private let intermediateChunk = """
    {"model":"llama3.2","created_at":"2026-07-16T10:00:00Z","response":"Hello","done":false}
    """

    @Test("final generate chunk produces one record with counts and timing")
    func generateFinalChunk() {
        let parser = OllamaUsageParser()
        let records = parser.consume(Data((finalGenerateChunk + "\n").utf8))

        #expect(records.count == 1)
        let record = records[0]
        #expect(record.model == "llama3.2")
        #expect(record.promptTokens == 26)
        #expect(record.outputTokens == 298)
        #expect(record.totalDurationNanos == 4_935_886_791)
        #expect(record.evalDurationNanos == 4_289_432_000)
    }

    @Test("intermediate streaming chunks are ignored")
    func intermediateChunksIgnored() {
        let parser = OllamaUsageParser()
        var records: [OllamaUsageParser.ParsedUsage] = []
        for _ in 0..<50 {
            records += parser.consume(Data((intermediateChunk + "\n").utf8))
        }
        records += parser.consume(Data((finalGenerateChunk + "\n").utf8))
        #expect(records.count == 1)
    }

    @Test("fragments split mid-JSON reassemble into one record")
    func arbitraryFragmentBoundaries() {
        let full = Data((intermediateChunk + "\n" + finalGenerateChunk + "\n").utf8)
        // Try several nasty split points, including mid-number and mid-key.
        for splitAt in [1, 10, full.count / 2, full.count - 3] {
            let parser = OllamaUsageParser()
            var records = parser.consume(full.prefix(splitAt))
            records += parser.consume(full.suffix(full.count - splitAt))
            #expect(records.count == 1, "split at \(splitAt)")
            #expect(records.first?.outputTokens == 298)
        }
    }

    @Test("HTTP headers and chunked-framing lines don't confuse the scanner")
    func httpFramingIgnored() {
        let wire = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"
            + "12c\r\n" + intermediateChunk + "\n\r\n"
            + "1f4\r\n" + finalGenerateChunk + "\n\r\n"
            + "0\r\n\r\n"
        let parser = OllamaUsageParser()
        let records = parser.consume(Data(wire.utf8))
        #expect(records.count == 1)
        #expect(records.first?.promptTokens == 26)
    }

    @Test("openai-compat response body with usage block is captured")
    func openAICompatBody() {
        let body = """
        {"id":"chatcmpl-1","object":"chat.completion","model":"llama3.2","choices":[],"usage":{"prompt_tokens":31,"completion_tokens":140,"total_tokens":171}}
        """
        let parser = OllamaUsageParser()
        let records = parser.consume(Data((body + "\n").utf8))
        #expect(records == [OllamaUsageParser.ParsedUsage(
            model: "llama3.2",
            promptTokens: 31,
            outputTokens: 140,
            totalDurationNanos: nil,
            evalDurationNanos: nil
        )])
    }

    @Test("openai-compat SSE stream: data-prefixed usage chunk, [DONE] ignored")
    func openAICompatSSE() {
        let wire = "data: {\"id\":\"c1\",\"model\":\"llama3.2\",\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\r\n"
            + "data: {\"id\":\"c1\",\"model\":\"llama3.2\",\"choices\":[],\"usage\":{\"prompt_tokens\":8,\"completion_tokens\":2}}\r\n"
            + "data: [DONE]\r\n"
        let parser = OllamaUsageParser()
        let records = parser.consume(Data(wire.utf8))
        #expect(records.count == 1)
        #expect(records.first?.promptTokens == 8)
        #expect(records.first?.outputTokens == 2)
    }

    @Test("multiple keep-alive responses on one connection all captured")
    func sequentialResponses() {
        let parser = OllamaUsageParser()
        var records = parser.consume(Data((finalGenerateChunk + "\n").utf8))
        records += parser.consume(Data((finalGenerateChunk + "\n").utf8))
        #expect(records.count == 2)
    }

    @Test("garbage and binary data never crash or emit records")
    func garbageTolerance() {
        let parser = OllamaUsageParser()
        var records = parser.consume(Data([0xFF, 0xFE, 0x00, 0x0A, 0x7B, 0x0A]))
        records += parser.consume(Data("not json at all\n{broken json\n".utf8))
        #expect(records.isEmpty)
    }

    @Test("newline-free flood is capped, then recovery works")
    func bufferCap() {
        let parser = OllamaUsageParser()
        // 2 MB without a newline — must not grow unbounded or crash.
        let flood = Data(repeating: UInt8(ascii: "x"), count: 2 << 20)
        #expect(parser.consume(flood).isEmpty)
        // Parser still works afterwards.
        let records = parser.consume(Data(("\n" + finalGenerateChunk + "\n").utf8))
        #expect(records.count == 1)
    }
}
