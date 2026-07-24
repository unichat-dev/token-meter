// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("WidgetSnapshot")
struct WidgetSnapshotTests {
    @Test("codable round-trip preserves every field")
    func codableRoundTrip() throws {
        let snapshot = WidgetSnapshot(
            updatedAt: Date(timeIntervalSince1970: 1_780_000_000),
            todayTokens: 2_400_000,
            todayCostUSD: Decimal(string: "4.20"),
            blockTokens: 310_000,
            blockEndsAt: Date(timeIntervalSince1970: 1_780_010_000),
            weekTokens: 14_800_000,
            localTokens: 512
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(WidgetSnapshot.self, from: encoder.encode(snapshot))
        #expect(decoded == snapshot)
    }

    @Test("content comparison ignores updatedAt")
    func contentComparison() {
        let base = WidgetSnapshot(
            updatedAt: .now,
            todayTokens: 100,
            todayCostUSD: nil,
            blockTokens: nil,
            blockEndsAt: nil,
            weekTokens: 200,
            localTokens: 0
        )
        var later = base
        later.updatedAt = base.updatedAt.addingTimeInterval(3600)
        #expect(later.hasSameContent(as: base)) // only the clock moved

        var changed = later
        changed.todayTokens = 101
        #expect(!changed.hasSameContent(as: base))
        #expect(!base.hasSameContent(as: nil))
    }
}
