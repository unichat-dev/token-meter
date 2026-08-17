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

    /// This billing period's observed usage against what the user pays for it.
    /// `.none` until a plan is declared in Settings.
    private(set) var planValue: PlanValue = .none

    /// What prompt caching is doing to this billing period's cost.
    private(set) var cacheEfficiency = CacheEfficiency(
        cacheReadTokens: 0, cacheWriteTokens: 0, freshInputTokens: 0,
        actualCostUSD: 0, withoutCacheCostUSD: 0
    )

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
    /// Event id → its slot in `events`, for dedupe across the DB load and the
    /// log re-backfill after relaunch (the DB's unique constraint is the
    /// durable layer of the same rule).
    ///
    /// A map rather than a `Set` so a re-scanned event can **refresh** the row
    /// it matches instead of being dropped. That's what lets a parser or
    /// pricing change reach history that was ingested by an older build —
    /// dropping the re-scan would freeze old rows at the old numbers forever.
    /// `events` is only ever appended to, so stored indices stay valid.
    private var eventIndex: [String: Int] = [:]

    /// Oldest event timestamp seen. Tracked incrementally because log backfill
    /// yields in file order, not time order — so `events.first` is not the
    /// earliest. Used to tell whether history actually covers a billing period.
    private var earliestEventAt: Date?

    /// Running day × model totals. Every rollup except the 5-hour block reads
    /// this instead of rescanning `events`.
    private var usageIndex = UsageIndex()

    /// Reconstructed blocks, rebuilt only when events changed rather than on
    /// every throttled refresh.
    private var cachedActiveBlocks: [UsageBlock] = []
    private var blocksDirty = true
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

    // MARK: Plan

    /// The plan the user says they're on (Settings → Plan).
    var subscriptionPlan: SubscriptionPlan {
        let raw = UserDefaults.standard.string(forKey: PreferenceKey.subscriptionPlan) ?? ""
        return SubscriptionPlan(rawValue: raw) ?? .unset
    }

    /// What that plan costs per month. Falls back to the preset list price so a
    /// freshly-picked plan is useful before the user touches the field.
    var planMonthlyPriceUSD: Decimal {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: PreferenceKey.planMonthlyPriceUSD) != nil {
            let stored = defaults.double(forKey: PreferenceKey.planMonthlyPriceUSD)
            if stored > 0 { return Decimal(stored) }
        }
        return subscriptionPlan.defaultMonthlyPriceUSD ?? 0
    }

    /// Day of the month the subscription renews (1...28).
    var planCycleStartDay: Int {
        let stored = UserDefaults.standard.integer(forKey: PreferenceKey.planCycleStartDay)
        return BillingPeriod.dayRange.contains(stored) ? stored : 1
    }

    func setSubscriptionPlan(_ plan: SubscriptionPlan) {
        let defaults = UserDefaults.standard
        defaults.set(plan.rawValue, forKey: PreferenceKey.subscriptionPlan)
        // Switching plans adopts the new list price; the user can still edit it.
        // Custom keeps whatever they typed.
        if plan != .custom, let preset = plan.defaultMonthlyPriceUSD {
            defaults.set(NSDecimalNumber(decimal: preset).doubleValue,
                         forKey: PreferenceKey.planMonthlyPriceUSD)
        }
        recomputeRollups()
    }

    func setPlanMonthlyPrice(_ price: Decimal) {
        UserDefaults.standard.set(
            NSDecimalNumber(decimal: max(0, price)).doubleValue,
            forKey: PreferenceKey.planMonthlyPriceUSD
        )
        recomputeRollups()
    }

    func setPlanCycleStartDay(_ day: Int) {
        let clamped = min(max(day, BillingPeriod.dayRange.lowerBound), BillingPeriod.dayRange.upperBound)
        UserDefaults.standard.set(clamped, forKey: PreferenceKey.planCycleStartDay)
        recomputeRollups()
    }

    // MARK: Budgets & notifications

    /// Whether we're allowed to post budget alerts.
    private(set) var notificationPermission: NotificationPermission = .unknown

    /// Posts the alerts. Injectable so tests never reach the real
    /// notification framework.
    @ObservationIgnored
    var notifier: any BudgetNotifying = UserNotificationService()

    /// Thresholds already fired, per window instance. Persisted so relaunching
    /// mid-day doesn't replay alerts the user already saw.
    @ObservationIgnored
    private var alertLedger = BudgetAlertLedger()

    /// The user's configured budgets, keyed by scope.
    private(set) var budgets: [BudgetScope: Budget] = [:]

    func budget(for scope: BudgetScope) -> Budget {
        budgets[scope] ?? Budget(scope: scope)
    }

    func setBudget(_ budget: Budget) {
        budgets[budget.scope] = budget
        persistBudgets()
        // A changed ceiling makes past firings meaningless — a budget raised
        // after hitting 100% should be able to alert again.
        alertLedger = BudgetAlertLedger()
        persistLedger()
        recomputeRollups()
    }

    /// Any budget switched on. Drives whether we bother asking for permission.
    var hasEnabledBudget: Bool {
        budgets.values.contains { $0.isEnabled }
    }

    func refreshNotificationPermission() async {
        notificationPermission = await notifier.currentPermission()
    }

    func requestNotificationPermission() async {
        notificationPermission = await notifier.requestPermission()
    }

    private func loadBudgets() {
        guard
            let data = UserDefaults.standard.data(forKey: PreferenceKey.budgets),
            let stored = try? JSONDecoder().decode([Budget].self, from: data)
        else { return }
        budgets = Dictionary(uniqueKeysWithValues: stored.map { ($0.scope, $0) })
    }

    private func persistBudgets() {
        guard let data = try? JSONEncoder().encode(Array(budgets.values)) else { return }
        UserDefaults.standard.set(data, forKey: PreferenceKey.budgets)
    }

    private func loadLedger() {
        guard
            let data = UserDefaults.standard.data(forKey: PreferenceKey.budgetAlertLedger),
            let stored = try? JSONDecoder().decode(BudgetAlertLedger.self, from: data)
        else { return }
        alertLedger = stored
    }

    private func persistLedger() {
        guard let data = try? JSONEncoder().encode(alertLedger) else { return }
        UserDefaults.standard.set(data, forKey: PreferenceKey.budgetAlertLedger)
    }

    // MARK: Launch at login

    /// Read back from `SMAppService` rather than stored, because the user can
    /// change it in System Settings behind our back.
    var launchesAtLogin: Bool { LaunchAtLogin.isEnabled }
    var launchAtLoginNeedsApproval: Bool { LaunchAtLogin.isBlockedBySystemSettings }

    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.setEnabled(enabled)
    }

    // MARK: Updates

    private(set) var updateStatus: UpdateStatus = .unknown

    func checkForUpdates() async {
        updateStatus = .checking
        updateStatus = await UpdateChecker().check()
    }

    // MARK: Export

    /// Serializes events in `interval` for the user to save.
    func exportData(in interval: DateInterval, format: UsageExport.Format) throws -> Data {
        try UsageExport.data(
            for: events(in: interval),
            format: format,
            resolver: pricingResolver
        )
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
        loadBudgets()
        loadLedger()

        ingestTask = Task { [weak self] in
            // 1. Pricing first (cheap, local), then the store — the UI shows
            //    priced history before any log re-scan finishes.
            await self?.startPricing()
            await self?.refreshNotificationPermission()
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
            let calendar = Calendar.current
            for event in persisted where eventIndex[event.id] == nil {
                eventIndex[event.id] = events.count
                events.append(event)
                usageIndex.insert(event, calendar: calendar)
            }
            blocksDirty = true
            // `loadAll` returns oldest-first, so the first row dates the history.
            if let oldest = persisted.first?.timestamp,
               earliestEventAt.map({ oldest < $0 }) ?? true {
                earliestEventAt = oldest
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
        let calendar = Calendar.current

        if let existing = eventIndex[event.id] {
            // Same event, re-read from the log after a relaunch. Usually
            // identical and ignorable — but when a newer build extracts more
            // from the same line (e.g. the cache-write TTL split), this is how
            // the stored row and the in-memory copy pick the new fields up.
            let previous = events[existing]
            guard previous != event else { return }
            usageIndex.remove(previous, calendar: calendar)
            usageIndex.insert(event, calendar: calendar)
            events[existing] = event
            pendingPersist.append(event) // upserts on eventID
            blocksDirty = true
            rollupsDirty = true
            scheduleRollupRecompute()
            return
        }

        eventIndex[event.id] = events.count
        events.append(event)
        usageIndex.insert(event, calendar: calendar)
        if earliestEventAt.map({ event.timestamp < $0 }) ?? true {
            earliestEventAt = event.timestamp
        }
        ingestedEventCount += 1
        pendingPersist.append(event)
        blocksDirty = true
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

        // Every window below reads pre-aggregated day buckets rather than
        // rescanning history, so this stays flat as the archive grows.
        let todayAggregate = usageIndex.aggregate(on: now, calendar: calendar)
        var today = todayAggregate.summary
        today.estimatedCostUSD = CostEngine.totals(
            for: todayAggregate, resolver: resolver
        ).costIfAnyPriced
        todaySummary = today

        var week = UsageSummary.empty
        if let weekInterval = calendar.dateInterval(of: .weekOfYear, for: now) {
            let weekAggregate = usageIndex.aggregate(in: weekInterval)
            week = weekAggregate.summary
            week.estimatedCostUSD = CostEngine.totals(
                for: weekAggregate, resolver: resolver
            ).costIfAnyPriced
        }
        weekSummary = week

        unpricedModels = CostEngine.totals(
            for: usageIndex.aggregateAll(), resolver: resolver
        ).unpricedModels

        let period = BillingPeriod.current(
            containing: now, cycleStartDay: planCycleStartDay, calendar: calendar
        )
        let periodAggregate = usageIndex.aggregate(in: period)
        let periodTotals = CostEngine.totals(for: periodAggregate, resolver: resolver)
        planValue = PlanValue(
            plan: subscriptionPlan,
            monthlyPriceUSD: planMonthlyPriceUSD,
            period: period,
            observedCostUSD: periodTotals.cost,
            eventCount: periodAggregate.eventCount,
            unpricedModels: periodTotals.unpricedModels,
            isPartialPeriod: (earliestEventAt ?? now) > period.start
        )

        cacheEfficiency = CacheEfficiency.make(
            aggregate: periodAggregate, resolver: resolver
        )

        ollamaTodayTokens = isOllamaTrackingEnabled ? todayAggregate.ollamaTokens : 0

        // Blocks are the one window that doesn't align to day boundaries, so
        // they're still reconstructed from raw events — cheap next to the
        // aggregates, and only when new events actually arrived.
        if blocksDirty {
            blocksDirty = false
            let claudeOnly = events.filter { $0.provider == .claudeCode }
            let blocks = UsageRollups.blocks(from: claudeOnly)
            cachedActiveBlocks = blocks
        }
        currentBlock = UsageRollups.activeBlock(in: cachedActiveBlocks, now: now)
        peakBlockTokens = UsageRollups.peakBlockTokens(in: cachedActiveBlocks, now: now)

        // Last, so every window it reads (block included) is already current.
        evaluateBudgets(now: now, calendar: calendar)

        publishWidgetSnapshot()
    }

    // MARK: - Budget evaluation

    /// Current usage for a scope, in that scope's unit. `nil` when the window
    /// has nothing to measure yet (no active block, nothing priced).
    private func budgetUsage(for scope: BudgetScope) -> Decimal? {
        switch scope {
        case .block:
            guard let block = currentBlock else { return nil }
            return Decimal(block.tokens.total)
        case .daily:
            return todaySummary.estimatedCostUSD
        case .weekly:
            return weekSummary.estimatedCostUSD
        case .billingPeriod:
            return planValue.observedCostUSD
        }
    }

    /// The ceiling for a scope. The block scope reuses the reference already
    /// configured in Usage Windows rather than asking for the same number
    /// twice; everything else uses the budget's own limit.
    private func budgetLimit(for budget: Budget) -> Decimal? {
        guard budget.scope == .block else {
            return budget.limit > 0 ? budget.limit : nil
        }
        let mode = BlockReferenceMode(
            rawValue: UserDefaults.standard.string(forKey: PreferenceKey.blockReferenceMode) ?? ""
        ) ?? .off
        let custom = UserDefaults.standard.integer(forKey: PreferenceKey.blockReferenceCustomTokens)
        guard let reference = BlockReference.tokens(
            mode: mode, custom: custom, peak: peakBlockTokens
        ) else { return nil }
        return Decimal(reference)
    }

    private func evaluateBudgets(now: Date, calendar: Calendar) {
        guard hasEnabledBudget, notificationPermission.canPost else { return }

        var alerts: [BudgetAlert] = []
        var activeKeys: Set<String> = []

        for scope in BudgetScope.allCases {
            let budget = budget(for: scope)
            guard budget.isEnabled else { continue }
            guard
                let windowKey = BudgetEvaluator.windowKey(
                    for: scope,
                    now: now,
                    blockStart: currentBlock?.start,
                    billingPeriodStart: planValue.period.start,
                    calendar: calendar
                ),
                let used = budgetUsage(for: scope),
                let limit = budgetLimit(for: budget)
            else { continue }

            activeKeys.insert(BudgetAlertLedger.activeKey(scope, windowKey))

            if let alert = BudgetEvaluator.evaluate(
                budget: budget,
                used: used,
                limit: limit,
                windowKey: windowKey,
                ledger: &alertLedger
            ) {
                alerts.append(alert)
            }
        }

        // Windows that rolled over drop out of the ledger, so it stays small
        // no matter how long the app runs.
        alertLedger.prune(keeping: activeKeys)

        guard !alerts.isEmpty else { return }
        persistLedger()
        let notifier = self.notifier
        Task {
            for alert in alerts {
                await notifier.post(alert)
            }
        }
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
