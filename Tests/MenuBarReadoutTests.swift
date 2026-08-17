// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("BlockReference & MenuBarMetric")
struct MenuBarReadoutTests {

    // MARK: - Block reference resolution

    @Test("off mode never produces a reference")
    func offMode() {
        #expect(BlockReference.tokens(mode: .off, custom: 5_000, peak: 9_000) == nil)
    }

    @Test("peak mode uses the highest past block, but only once there is one")
    func peakMode() {
        #expect(BlockReference.tokens(mode: .peak, custom: 0, peak: 9_000) == 9_000)
        // Fresh install: no completed blocks yet — no bar rather than a 0-divide.
        #expect(BlockReference.tokens(mode: .peak, custom: 5_000, peak: 0) == nil)
    }

    @Test("custom mode uses the user's number, ignoring peak")
    func customMode() {
        #expect(BlockReference.tokens(mode: .custom, custom: 5_000, peak: 9_000) == 5_000)
        #expect(BlockReference.tokens(mode: .custom, custom: 0, peak: 9_000) == nil)
    }

    @Test("fraction is clamped so an over-reference block shows a full bar")
    func fractionClamped() {
        #expect(BlockReference.fraction(tokens: 500, reference: 1_000) == 0.5)
        #expect(BlockReference.fraction(tokens: 5_000, reference: 1_000) == 1)
        #expect(BlockReference.fraction(tokens: 0, reference: 1_000) == 0)
    }

    @Test("a zero reference never divides by zero")
    func zeroReferenceSafe() {
        #expect(BlockReference.fraction(tokens: 1_000, reference: 0) == 0)
    }

    @Test("every mode has a label, and off has none to show")
    func labels() {
        #expect(BlockReference.label(for: .off).isEmpty)
        #expect(!BlockReference.label(for: .peak).isEmpty)
        #expect(!BlockReference.label(for: .custom).isEmpty)
    }

    // MARK: - Menu bar metric

    @Test("every metric has a distinct label and a stable raw value")
    func metricLabels() {
        let labels = Set(MenuBarMetric.allCases.map(\.label))
        #expect(labels.count == MenuBarMetric.allCases.count)

        // Raw values are persisted in UserDefaults — renaming one silently
        // resets every user's choice, so pin them.
        #expect(MenuBarMetric.iconOnly.rawValue == "iconOnly")
        #expect(MenuBarMetric.todayTokens.rawValue == "todayTokens")
        #expect(MenuBarMetric.todayCost.rawValue == "todayCost")
        #expect(MenuBarMetric.blockProgress.rawValue == "blockProgress")
        #expect(MenuBarMetric.planMultiple.rawValue == "planMultiple")
    }

    @Test("metrics that can come up empty explain why in Settings")
    func metricRequirements() {
        #expect(MenuBarMetric.iconOnly.requirement == nil)
        #expect(MenuBarMetric.todayTokens.requirement == nil)
        // These three depend on configuration the user may not have done yet.
        #expect(MenuBarMetric.todayCost.requirement != nil)
        #expect(MenuBarMetric.blockProgress.requirement != nil)
        #expect(MenuBarMetric.planMultiple.requirement != nil)
    }

    @Test("an unknown stored raw value falls back instead of crashing")
    func unknownRawValue() {
        #expect(MenuBarMetric(rawValue: "somethingElse") == nil)
        #expect(BlockReferenceMode(rawValue: "somethingElse") == nil)
    }
}
