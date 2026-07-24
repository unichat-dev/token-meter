// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation
import WidgetKit
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

    /// Which pane the main window shows. Bound by ``MainWindowView`` and set by
    /// the menu-bar popover so "Open TokenMeter" / "Settings" land on the right
    /// section.
    var mainSelection: MainSection = .overview

    /// Guards the launch auto-open so the main window opens once per run, not
    /// every time the menu-bar item re-renders.
    @ObservationIgnored var didAutoOpenMainWindow = false

    /// Where we're reading Claude Code logs from (for display).
    private(set) var logsRoot: URL = ClaudeCodeLogLocator.defaultRoot

    /// Codex CLI log access — same FDA-guidance flow as Claude Code.
    private(set) var codexAccessStatus: LogAccessStatus = .checking
    private(set) var codexLogsRoot: URL = CodexLogLocator.defaultRoot

    private var events: [UsageEvent] = []
    /// In-memory dedupe across DB load + log re-backfill after relaunch
    /// (the DB's unique constraint is the durable layer of the same rule).
    private var seenEventIDs: Set<String> = []
    private var ingestTask: Task<Void, Never>?
    private var codexIngestTask: Task<Void, Never>?
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

    // MARK: Ollama

    private(set) var ollamaState = OllamaState()
    /// Today's local-model tokens (kept apart from the metered "Today" glance).
    private(set) var ollamaTodayTokens = 0
    /// Rolling average generation speed over recent captured responses,
    /// this session only.
    private(set) var ollamaTokensPerSecond: Double?
    private var ollamaTask: Task<Void, Never>?
    private var recentOllamaRates: [Double] = []

    var isOllamaTrackingEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.ollamaEnabled)
    }

    var ollamaUpstreamURL: URL {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.ollamaUpstreamURL) ?? ""
        return URL(string: raw.isEmpty ? "http://127.0.0.1:11434" : raw)
            ?? URL(string: "http://127.0.0.1:11434")!
    }

    var ollamaProxyPort: UInt16 {
        let raw = UserDefaults.standard.integer(forKey: PreferenceKey.ollamaProxyPort)
        return raw > 0 && raw <= 65_535 ? UInt16(raw) : 11_435
    }

    // MARK: Dock icon

    /// Count of regular windows (dashboard, settings) currently visible —
    /// drives the `whileWindowsOpen` Dock mode.
    private var visibleWindowCount = 0

    // MARK: Floating HUD ("pin to screen")

    /// Owns the always-on-top floating widget panel. Created lazily so its
    /// `unowned` back-reference to `self` is safe, and ignored by observation
    /// (it's a controller, not derived UI state).
    @ObservationIgnored
    private lazy var floatingHUD = FloatingHUDController(model: self)

    /// Whether the floating widget is pinned on screen (Settings → General).
    var isFloatingHUDEnabled: Bool {
        UserDefaults.standard.bool(forKey: PreferenceKey.floatingHUDEnabled)
    }

    /// Distinct *metered* models in ingested usage, biggest first — drives
    /// the pricing editor's row list (local models can't be priced).
    var modelsSeenInUsage: [String] {
        UsageAggregation.totals(events: events.filter { $0.provider.isMetered }) { $0.model }
            .map(\.key)
    }

    /// What the UI is allowed to show: with Ollama tracking off, local-model
    /// events disappear from every display (history stays in the DB and
    /// returns if tracking is re-enabled).
    private var displayEvents: [UsageEvent] {
        isOllamaTrackingEnabled ? events : events.filter { $0.provider != .ollama }
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

        // Codex CLI logs — same incremental JSONL machinery, its own root.
        // Runs alongside Claude Code (idempotent ingest; independent stream).
        let codexOverride = UserDefaults.standard.string(
            forKey: PreferenceKey.codexLogsPathOverride
        )
        let codexLocator = CodexLogLocator(
            pathOverride: (codexOverride?.isEmpty == false) ? codexOverride : nil
        )
        codexLogsRoot = codexLocator.rootURL
        let codexSource = CodexLogSource(locator: codexLocator)
        codexIngestTask = Task { [weak self] in
            do {
                for try await event in codexSource.events() {
                    guard let self else { return }
                    self.ingest(event)
                }
            } catch {
                Logger.app.error("codex stream ended: \(error, privacy: .public)")
            }
        }

        // Periodic upkeep: rollup refresh (so "Today"/the block countdown
        // stay correct across midnight and block expiry even with no new
        // events), access-status refresh, Ollama server status, and the
        // daily pricing-feed check.
        maintenanceTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard let self else { return }
                self.recomputeRollups()
                self.refreshAccessStatus()
                await self.refreshOllamaServerStatus()
                await self.refreshPricingIfDue()
            }
        }

        applyActivationPolicy()
        applyFloatingHUD()
        if isOllamaTrackingEnabled {
            startOllamaCapture()
        }
        Task { await refreshOllamaServerStatus() }
    }

    // MARK: - Ollama

    /// Live toggle from Settings — no relaunch needed. Toggling off also
    /// removes local-model data from every display (see `displayEvents`).
    func setOllamaTracking(enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: PreferenceKey.ollamaEnabled)
        if enabled {
            startOllamaCapture()
        } else {
            stopOllamaCapture()
        }
        recomputeRollups()
        Task { await refreshOllamaServerStatus() }
    }

    private func startOllamaCapture() {
        guard ollamaTask == nil else { return }
        let upstream = ollamaUpstreamURL
        let source = OllamaProxySource(
            listenPort: ollamaProxyPort,
            upstreamHost: upstream.host() ?? "127.0.0.1",
            upstreamPort: UInt16(upstream.port ?? 11_434)
        )
        ollamaState.capturePort = ollamaProxyPort
        ollamaState.captureError = nil

        ollamaTask = Task { [weak self] in
            do {
                for try await event in source.events() {
                    guard let self else { return }
                    self.recordOllamaThroughput(event)
                    self.ingest(event)
                }
            } catch {
                // Usually the port is taken. Surface it; don't crash-loop.
                Logger.dataSources.error("ollama proxy stopped: \(error, privacy: .public)")
                guard let self else { return }
                self.ollamaState.capturePort = nil
                self.ollamaState.captureError = "Capture failed — is port \(self.ollamaProxyPort) already in use?"
            }
        }
    }

    private func stopOllamaCapture() {
        ollamaTask?.cancel()
        ollamaTask = nil
        ollamaState.capturePort = nil
        ollamaState.captureError = nil
    }

    private func refreshOllamaServerStatus() async {
        guard isOllamaTrackingEnabled else {
            ollamaState.server = .unknown
            return
        }
        let client = OllamaStatusClient(baseURL: ollamaUpstreamURL)
        ollamaState.server = await client.check()
    }

    private func recordOllamaThroughput(_ event: UsageEvent) {
        guard let rate = event.timing?.tokensPerSecond(outputTokens: event.tokens.output) else {
            return
        }
        recentOllamaRates.append(rate)
        if recentOllamaRates.count > 20 {
            recentOllamaRates.removeFirst()
        }
        ollamaTokensPerSecond = recentOllamaRates.reduce(0, +) / Double(recentOllamaRates.count)
    }

    // MARK: - Dock icon / activation policy

    /// Called by regular windows (dashboard, settings) as they come and go.
    func windowAppeared() {
        visibleWindowCount += 1
        applyActivationPolicy()
    }

    func windowDisappeared() {
        visibleWindowCount = max(0, visibleWindowCount - 1)
        applyActivationPolicy()
    }

    /// Toggle the floating "pin to screen" widget and remember the choice.
    func setFloatingHUDVisible(_ visible: Bool) {
        UserDefaults.standard.set(visible, forKey: PreferenceKey.floatingHUDEnabled)
        applyFloatingHUD()
    }

    /// Show/hide the floating widget to match the stored preference. Called at
    /// launch and whenever the toggle changes.
    func applyFloatingHUD() {
        if isFloatingHUDEnabled {
            floatingHUD.show()
            refreshNow()
        } else {
            floatingHUD.hide()
        }
    }

    /// The app always lives in the menu bar (`LSUIElement` keeps launch
    /// quiet); this flips the Dock/⌘-Tab presence at runtime per preference.
    func applyActivationPolicy() {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.dockIconMode) ?? ""
        let mode = DockIconMode(rawValue: raw) ?? .whileWindowsOpen
        let wantsRegular = switch mode {
        case .always: true
        case .never: false
        case .whileWindowsOpen: visibleWindowCount > 0
        }
        // NSApplication.shared (not NSApp): this can run from App.init,
        // before the NSApp global is set.
        let app = NSApplication.shared
        let policy: NSApplication.ActivationPolicy = wantsRegular ? .regular : .accessory
        guard app.activationPolicy() != policy else { return }
        app.setActivationPolicy(policy)
        if wantsRegular {
            app.activate()
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

    /// Where to fetch prices from and how to decode them, per the Settings
    /// picker. `nil` disables remote refresh (a Custom source with no URL) —
    /// bundled/cached prices + user edits still apply.
    var pricingRefreshTarget: (url: URL, format: PricingFeedFormat)? {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.pricingSource) ?? ""
        switch PricingSource(rawValue: raw) ?? .liteLLM {
        case .liteLLM:
            return (LiteLLMPricingParser.upstreamURL, .liteLLM)
        case .tokenMeterFeed:
            return (Self.defaultPricingFeedURL, .tokenMeter)
        case .custom:
            let custom = UserDefaults.standard.string(forKey: PreferenceKey.pricingFeedURL) ?? ""
            guard !custom.isEmpty, let url = URL(string: custom) else { return nil }
            return (url, .tokenMeter)
        }
    }

    private func refreshPricingIfDue() async {
        guard let pricingService, let target = pricingRefreshTarget else { return }
        guard await pricingService.isDue else { return }
        if let result = await pricingService.refresh(from: target.url, format: target.format) {
            apply(result)
        }
    }

    /// Manual "Refresh Now" from Settings; ignores the 24 h schedule.
    func refreshPricingNow() async {
        guard let pricingService, let target = pricingRefreshTarget else { return }
        if let result = await pricingService.refresh(from: target.url, format: target.format) {
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
        // Same URL-readability classification, applied to the Codex root.
        codexAccessStatus = ClaudeCodeLogLocator.checkAccess(at: codexLogsRoot)
    }

    /// `~`-abbreviated Codex logs path for UI copy.
    var codexLogsRootDisplayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let path = codexLogsRoot.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    /// Called when the popover opens so the display is current immediately,
    /// not up to a throttle-interval stale.
    func refreshNow() {
        refreshAccessStatus()
        recomputeRollups()
    }

    /// Events within `interval` (end-exclusive) — feeds the details window.
    func events(in interval: DateInterval) -> [UsageEvent] {
        displayEvents.filter { interval.contains($0.timestamp) && $0.timestamp != interval.end }
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

        // The popover glance, week row, and 5-hour blocks describe *metered*
        // usage (Claude Code today). Local models get their own row —
        // mixing free local tokens into those numbers would be misleading.
        let metered = events.filter { $0.provider.isMetered }

        var today = UsageSummary.daily(from: metered, on: now, calendar: calendar)
        let todayMetered = metered.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        today.estimatedCostUSD = CostEngine.totals(for: todayMetered, resolver: resolver).costIfAnyPriced
        todaySummary = today

        weekSummary = UsageRollups.weekly(from: metered, containing: now, calendar: calendar)
        unpricedModels = CostEngine.totals(for: events, resolver: resolver).unpricedModels

        ollamaTodayTokens = isOllamaTrackingEnabled
            ? events
                .filter { $0.provider == .ollama && calendar.isDate($0.timestamp, inSameDayAs: now) }
                .reduce(0) { $0 + $1.tokens.total }
            : 0

        // The 5-hour block is a Claude Pro/Max subscription concept — scope it
        // to Claude Code so Codex/GPT usage never inflates the Claude window.
        let claudeOnly = metered.filter { $0.provider == .claudeCode }
        let blocks = UsageRollups.blocks(from: claudeOnly)
        currentBlock = UsageRollups.activeBlock(in: blocks, now: now)
        peakBlockTokens = UsageRollups.peakBlockTokens(in: blocks, now: now)

        publishWidgetSnapshot()
    }

    // MARK: - Widget snapshot

    private var lastWidgetSnapshot: WidgetSnapshot?
    private var lastWidgetReloadAt = Date.distantPast

    /// Writes the shared snapshot for the widget (sandboxed — it can't read
    /// our data directly) and asks WidgetKit to reload, throttled to respect
    /// the refresh budget. The widget's own timeline re-reads the file every
    /// 15 minutes regardless.
    private func publishWidgetSnapshot() {
        let snapshot = WidgetSnapshot(
            updatedAt: .now,
            todayTokens: todaySummary.tokens.total,
            todayCostUSD: todaySummary.estimatedCostUSD,
            blockTokens: currentBlock?.tokens.total,
            blockEndsAt: currentBlock?.end,
            weekTokens: weekSummary.tokens.total,
            localTokens: ollamaTodayTokens
        )
        guard !snapshot.hasSameContent(as: lastWidgetSnapshot) else { return }
        lastWidgetSnapshot = snapshot
        snapshot.save()

        if Date.now.timeIntervalSince(lastWidgetReloadAt) >= 15 * 60 {
            lastWidgetReloadAt = .now
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
