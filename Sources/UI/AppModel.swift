// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation
import os

/// App-wide observable state shared by the menu-bar popover, the details
/// window, and settings.
///
/// Owns the ingestion pipeline: consumes ``UsageEvent`` streams from data
/// sources, keeps the in-memory working set backed by the SwiftData store,
/// and derives the rollups the UI shows (today, this week, the current
/// 5-hour block).
@MainActor
@Observable
final class AppModel {
    private(set) var todaySummary: UsageSummary = .empty
    private(set) var weekSummary: UsageSummary = .empty
    /// The reconstructed 5-hour block covering "now" (estimated — see
    /// ``UsageBlock``); `nil` while idle.
    private(set) var currentBlock: UsageBlock?
    /// Largest completed block total — reference for optional progress display.
    private(set) var peakBlockTokens = 0

    private(set) var logAccessStatus: LogAccessStatus = .checking
    private(set) var ingestedEventCount = 0

    /// Where we're reading Claude Code logs from (for display).
    private(set) var logsRoot: URL = ClaudeCodeLogLocator.defaultRoot

    private var events: [UsageEvent] = []
    /// In-memory dedupe across DB load + log re-backfill after relaunch
    /// (the DB's unique constraint is the durable layer of the same rule).
    private var seenEventIDs: Set<String> = []
    private var ingestTask: Task<Void, Never>?
    private var maintenanceTask: Task<Void, Never>?

    /// Durable history. `nil` if the container failed — the app degrades to
    /// in-memory-only rather than refusing to run.
    private var store: UsageHistoryStore?
    /// Events ingested but not yet written to the store; flushed on the same
    /// throttle as rollups so backfill writes in batches, not per event.
    private var pendingPersist: [UsageEvent] = []

    // MARK: Pricing

    private(set) var pricingBase: [String: ModelPricing] = [:]
    private(set) var pricingOverrides: [String: ModelPricing] = [:]
    private(set) var pricingStatus: PricingFeedStatus?
    /// Models seen in usage that have no price — totals exclude them, and
    /// the UI says so instead of hiding the gap.
    private(set) var unpricedModels: Set<String> = []
    private var pricingService: PricingService?

    var pricingResolver: ResolvedPricing {
        ResolvedPricing(base: pricingBase, overrides: pricingOverrides)
    }

    /// Distinct models in ingested usage, biggest first — drives the pricing
    /// editor's row list.
    var modelsSeenInUsage: [String] {
        UsageAggregation.totals(events: events) { $0.model }.map(\.key)
    }

    /// Rollups are recomputed at most every 300 ms while events stream in —
    /// recomputing per event would be O(n²) over a large backfill.
    private var rollupsDirty = false
    private var rollupRecomputeScheduled = false

    /// `~`-abbreviated path for UI copy.
    var logsRootDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = logsRoot.path
        return path.hasPrefix(home)
            ? "~" + path.dropFirst(home.count)
            : path
    }

    /// Starts ingestion + periodic maintenance. Idempotent.
    ///
    /// Note: a Settings path override is picked up at next launch (documented
    /// in the Settings footer) — restarting the pipeline mid-flight isn't
    /// worth the complexity yet.
    func startIfNeeded() {
        guard ingestTask == nil else { return }

        let override = UserDefaults.standard.string(
            forKey: PreferenceKey.claudeLogsPathOverride
        )
        let locator = ClaudeCodeLogLocator(
            pathOverride: (override?.isEmpty == false) ? override : nil
        )
        logsRoot = locator.rootURL
        refreshAccessStatus()

        let source = ClaudeCodeLogSource(locator: locator)
        ingestTask = Task { [weak self] in
            // 1. Pricing first (cheap, local), then the store — the UI shows
            //    priced history before any log re-scan finishes.
            await self?.startPricing()
            await self?.loadPersistedHistory()

            // 2. Then follow the logs. The stream re-yields everything after
            //    a relaunch (offsets are per-run); `seenEventIDs` + the DB's
            //    unique eventID keep that idempotent.
            do {
                for try await event in source.events() {
                    guard let self else { return }
                    self.ingest(event)
                }
            } catch {
                Logger.app.error("claude-code stream ended: \(error, privacy: .public)")
            }
        }

        // Periodic upkeep: rollup refresh (so "Today"/the block countdown
        // stay correct across midnight and block expiry even with no new
        // events), access-status refresh, and the daily pricing-feed check.
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.recomputeRollups()
                self.refreshAccessStatus()
                await self.refreshPricingIfDue()
            }
        }
    }

    // MARK: - Pricing

    private func startPricing() async {
        let directory: URL
        do {
            directory = try Persistence.storeDirectoryURL()
        } catch {
            Logger.app.error("pricing directory unavailable: \(error, privacy: .public)")
            return
        }
        let service = PricingService(directory: directory)
        pricingService = service

        if let initial = await service.loadInitial() {
            apply(initial)
        }
        await refreshPricingIfDue()
    }

    /// The official feed — `pricing-feed/pricing.json` on main, regenerated
    /// daily by CI.
    static let defaultPricingFeedURL = URL(
        string: "https://raw.githubusercontent.com/unichat-dev/token-meter/main/pricing-feed/pricing.json"
    )!

    /// Effective feed URL: the Settings override when set, otherwise the
    /// official feed. An unparseable override disables remote refresh
    /// (bundled/cached prices + user edits still apply).
    var pricingFeedURL: URL? {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.pricingFeedURL) ?? ""
        guard !raw.isEmpty else { return Self.defaultPricingFeedURL }
        return URL(string: raw)
    }

    private func refreshPricingIfDue() async {
        guard let pricingService, let pricingFeedURL else { return }
        guard await pricingService.isDue else { return }
        if let result = await pricingService.refresh(from: pricingFeedURL) {
            apply(result)
        }
    }

    /// Manual "Refresh Now" from Settings; ignores the 24 h schedule.
    func refreshPricingNow() async {
        guard let pricingService, let pricingFeedURL else { return }
        if let result = await pricingService.refresh(from: pricingFeedURL) {
            apply(result)
        }
    }

    private func apply(_ result: PricingService.LoadResult) {
        pricingBase = result.table.models
        pricingOverrides = result.overrides
        pricingStatus = result.status
        recomputeRollups()
    }

    /// Sets (or clears, with `nil`) the user's price for a model.
    func setPricingOverride(model: String, pricing: ModelPricing?) {
        if let pricing {
            pricingOverrides[model] = pricing
        } else {
            pricingOverrides.removeValue(forKey: model)
        }
        let snapshot = pricingOverrides
        Task { [pricingService] in
            await pricingService?.saveOverrides(snapshot)
        }
        recomputeRollups()
    }

    func refreshAccessStatus() {
        logAccessStatus = ClaudeCodeLogLocator.checkAccess(at: logsRoot)
    }

    /// Called when the popover opens so the display is current immediately,
    /// not up to a throttle-interval stale.
    func refreshNow() {
        refreshAccessStatus()
        recomputeRollups()
    }

    /// Events within `interval` (end-exclusive) — feeds the details window.
    func events(in interval: DateInterval) -> [UsageEvent] {
        events.filter { interval.contains($0.timestamp) && $0.timestamp != interval.end }
    }

    // MARK: - Persistence

    private func loadPersistedHistory() async {
        do {
            let container = try UsageHistoryStore.makeContainer()
            let store = UsageHistoryStore(modelContainer: container)
            self.store = store
            let persisted = try await store.loadAll()
            for event in persisted where seenEventIDs.insert(event.id).inserted {
                events.append(event)
            }
            ingestedEventCount = events.count
            recomputeRollups()
            Logger.app.info("loaded \(persisted.count) persisted usage events")
        } catch {
            // Keep running in-memory-only; history just won't survive relaunch.
            Logger.app.error("usage history store unavailable: \(error, privacy: .public)")
        }
    }

    private func flushPendingPersist() {
        guard let store, !pendingPersist.isEmpty else { return }
        let batch = pendingPersist
        pendingPersist = []
        Task {
            do {
                try await store.ingest(batch)
            } catch {
                Logger.app.error("persist batch failed: \(error, privacy: .public)")
            }
        }
    }

    // MARK: - Ingestion

    private func ingest(_ event: UsageEvent) {
        guard seenEventIDs.insert(event.id).inserted else { return }
        events.append(event)
        ingestedEventCount += 1
        pendingPersist.append(event)
        rollupsDirty = true
        scheduleRollupRecompute()
    }

    private func scheduleRollupRecompute() {
        guard !rollupRecomputeScheduled else { return }
        rollupRecomputeScheduled = true
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard let self else { return }
            self.rollupRecomputeScheduled = false
            if self.rollupsDirty {
                self.recomputeRollups()
            }
        }
    }

    private func recomputeRollups() {
        rollupsDirty = false
        flushPendingPersist()
        let now = Date.now
        let calendar = Calendar.current
        let resolver = pricingResolver

        var today = UsageSummary.daily(from: events, on: now, calendar: calendar)
        let todayEvents = events.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        let todayCosts = CostEngine.totals(for: todayEvents, resolver: resolver)
        today.estimatedCostUSD = todayCosts.costIfAnyPriced
        todaySummary = today

        weekSummary = UsageRollups.weekly(from: events, containing: now, calendar: calendar)
        unpricedModels = CostEngine.totals(for: events, resolver: resolver).unpricedModels

        let blocks = UsageRollups.blocks(from: events)
        currentBlock = UsageRollups.activeBlock(in: blocks, now: now)
        peakBlockTokens = UsageRollups.peakBlockTokens(in: blocks, now: now)
    }
}
