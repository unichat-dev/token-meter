// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("Export & updates")
struct UsageExportTests {
    private let resolver = ResolvedPricing(base: [
        "claude-opus-5": ModelPricing(inputPerMTok: 5, outputPerMTok: 25)
    ])

    private func event(
        id: String = "e",
        model: String = "claude-opus-5",
        provider: UsageProvider = .claudeCode,
        project: String? = "/Users/dev/demo",
        attribution: UsageAttribution = UsageAttribution()
    ) -> UsageEvent {
        UsageEvent(
            id: id, provider: provider, accuracy: .estimated,
            timestamp: Date(timeIntervalSince1970: 1_780_000_000),
            model: model, project: project,
            tokens: TokenCounts(input: 1_000_000, output: 100),
            attribution: attribution
        )
    }

    private func csv(_ events: [UsageEvent]) throws -> String {
        String(decoding: try UsageExport.data(for: events, format: .csv, resolver: resolver), as: UTF8.self)
    }

    // MARK: - CSV

    @Test("CSV has a header and one line per event")
    func csvShape() throws {
        let text = try csv([event(id: "a"), event(id: "b")])
        let lines = text.split(separator: "\n")
        #expect(lines.count == 3) // header + 2
        #expect(lines[0].hasPrefix("timestamp,provider,accuracy,model"))
    }

    @Test("cost is written per row, priced from the resolver")
    func costColumn() throws {
        let text = try csv([event()])
        // 1M input × $5/MTok + 100 output × $25/MTok = 5 + 0.0025
        #expect(text.hasSuffix(",5.0025\n"))
    }

    @Test("an unpriced model leaves the cost cell empty, never 0")
    func unpricedCostBlank() throws {
        let text = try csv([event(model: "mystery-model")])
        let row = text.split(separator: "\n")[1]
        #expect(row.hasSuffix(","), "expected a trailing empty cost cell, got: \(row)")
    }

    @Test("local models leave the cost cell empty — they have no cost dimension")
    func ollamaCostBlank() throws {
        let text = try csv([event(model: "llama3.2:3b", provider: .ollama)])
        #expect(text.split(separator: "\n")[1].hasSuffix(","))
    }

    @Test("attribution is exported")
    func attributionColumns() throws {
        let text = try csv([event(attribution: UsageAttribution(
            sessionID: "sess-1", gitBranch: "feature/x",
            agent: "Explore", skill: "run", isSidechain: true
        ))])
        for value in ["sess-1", "feature/x", "Explore", "run", "true"] {
            #expect(text.contains(value), "missing \(value)")
        }
    }

    @Test("values containing commas or quotes are quoted per RFC 4180")
    func csvQuoting() throws {
        let text = try csv([event(project: #"/Users/dev/a,b "quoted""#)])
        // Field is wrapped in quotes and each inner quote is doubled.
        #expect(text.contains(#""/Users/dev/a,b ""quoted"""#))
    }

    /// A branch named `=cmd|...` would otherwise execute on open in Excel.
    @Test("formula-injection prefixes are neutralized")
    func formulaInjectionNeutralized() throws {
        let text = try csv([event(attribution: UsageAttribution(gitBranch: "=1+1"))])
        #expect(text.contains("'=1+1"))
        #expect(!text.contains(",=1+1,"))
    }

    @Test("rows are ordered oldest first regardless of input order")
    func sortedOutput() throws {
        let older = UsageEvent(
            id: "old", provider: .claudeCode, accuracy: .estimated,
            timestamp: Date(timeIntervalSince1970: 1_000),
            model: "claude-opus-5", project: nil, tokens: TokenCounts(output: 1)
        )
        let text = try csv([event(id: "new"), older])
        let lines = text.split(separator: "\n")
        #expect(lines[1].contains("1970"))
    }

    // MARK: - JSON

    @Test("JSON decodes to one object per event")
    func jsonShape() throws {
        let data = try UsageExport.data(
            for: [event(id: "a"), event(id: "b")], format: .json, resolver: resolver
        )
        let parsed = try JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        #expect(parsed?.count == 2)
        #expect(parsed?.first?["model"] as? String == "claude-opus-5")
    }

    @Test("an empty range exports a header-only CSV, not an error")
    func emptyExport() throws {
        let text = try csv([])
        #expect(text.split(separator: "\n").count == 1)
    }

    // MARK: - Filenames

    @Test("suggested filename spans the interval and is locale-independent")
    func filename() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let interval = DateInterval(
            start: try! Date.ISO8601FormatStyle().parse("2026-08-01T00:00:00Z"),
            end: try! Date.ISO8601FormatStyle().parse("2026-09-01T00:00:00Z")
        )
        let name = UsageExport.suggestedFilename(for: interval, format: .csv, calendar: calendar)
        #expect(name == "TokenMeter-2026-08-01_2026-08-31.csv")
    }

    // MARK: - Update version comparison

    @Test("a higher version is detected as newer")
    func newerVersion() {
        #expect(UpdateChecker.isNewer("2.0.0", than: "1.0.0"))
        #expect(UpdateChecker.isNewer("1.1.0", than: "1.0.9"))
        // The classic string-compare bug: 1.10 must beat 1.9.
        #expect(UpdateChecker.isNewer("1.10.0", than: "1.9.0"))
    }

    @Test("the same or an older version is not newer")
    func notNewer() {
        #expect(!UpdateChecker.isNewer("1.0.0", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("1.0.0", than: "2.0.0"))
        #expect(!UpdateChecker.isNewer("1.0", than: "1.0.0"))
    }

    @Test("a leading v is ignored")
    func tagNormalization() {
        #expect(UpdateChecker.normalize("v2.0.0") == "2.0.0")
        #expect(UpdateChecker.normalize("2.0.0") == "2.0.0")
        #expect(UpdateChecker.normalize(" v2.0.0 ") == "2.0.0")
    }

    /// Better to miss an update than to nag forever about a tag we can't parse.
    @Test("a non-numeric tag never reports an update")
    func unparseableTagIsIgnored() {
        #expect(!UpdateChecker.isNewer("nightly", than: "1.0.0"))
        #expect(!UpdateChecker.isNewer("2.0.0-beta", than: "1.0.0"))
    }
}
