// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// UserDefaults keys for non-secret preferences. Secrets never go here —
/// API keys live in `KeychainStore` only (SECURITY.md).
enum PreferenceKey {
    /// Custom Claude Code logs root; empty string means "use the default".
    static let claudeLogsPathOverride = "claudeLogsPathOverride"
    /// Custom Codex CLI logs root; empty string means "use the default".
    static let codexLogsPathOverride = "codexLogsPathOverride"
    /// Raw `BlockReferenceMode` for 5-hour-block progress display.
    static let blockReferenceMode = "blockReferenceMode"
    /// Token count for `BlockReferenceMode.custom`.
    static let blockReferenceCustomTokens = "blockReferenceCustomTokens"
    /// Raw `PricingSource` — where the app pulls live prices from.
    static let pricingSource = "pricingSource"
    /// Custom pricing feed URL (our compact schema); used only when
    /// `pricingSource` is `.custom`. Empty disables remote refresh.
    static let pricingFeedURL = "pricingFeedURL"
    /// Whether the Ollama capture proxy is running.
    static let ollamaEnabled = "ollamaEnabled"
    /// Base URL of the real Ollama server; empty = http://127.0.0.1:11434.
    static let ollamaUpstreamURL = "ollamaUpstreamURL"
    /// Local port the capture proxy listens on; 0/unset = 11435.
    static let ollamaProxyPort = "ollamaProxyPort"
    /// Raw `DockIconMode` — when the app shows a Dock icon.
    static let dockIconMode = "dockIconMode"
    /// Whether the always-on-top floating widget ("pin to screen") is shown.
    static let floatingHUDEnabled = "floatingHUDEnabled"
    /// Raw `SubscriptionPlan` — what the user pays for their AI tools.
    static let subscriptionPlan = "subscriptionPlan"
    /// Monthly plan price in USD (Double in defaults, Decimal in use).
    static let planMonthlyPriceUSD = "planMonthlyPriceUSD"
    /// Day of month the subscription renews (1...28).
    static let planCycleStartDay = "planCycleStartDay"
    /// Raw `MenuBarMetric` — what the status item shows beside its icon.
    static let menuBarMetric = "menuBarMetric"
    /// Whether the main window opens automatically at every launch.
    static let openWindowAtLaunch = "openWindowAtLaunch"
    /// Set once the app has completed a first run, so the initial
    /// orientation window opens exactly once rather than every launch.
    static let hasCompletedFirstRun = "hasCompletedFirstRun"
    /// JSON-encoded `[Budget]` — the user's configured usage ceilings.
    static let budgets = "budgets"
    /// JSON-encoded `BudgetAlertLedger` — which thresholds already notified.
    static let budgetAlertLedger = "budgetAlertLedger"
}

/// When Token Meter appears in the Dock (and ⌘-Tab) like a regular app.
/// It always lives in the menu bar; this only controls the Dock presence.
enum DockIconMode: String, CaseIterable {
    /// Dock icon appears while the dashboard or settings window is open —
    /// windowed work feels like a normal app, idle stays menu-bar-only.
    case whileWindowsOpen
    /// Regular app at all times.
    case always
    /// Menu-bar-only at all times (windows may open behind other apps).
    case never
}

/// What (if anything) the 5-hour block progress bar compares against.
///
/// Honesty guardrail: there are **no official token numbers** for the
/// Pro/Max 5-hour window, so we never ship a hardcoded "plan limit". The
/// only references offered are the user's own history or their own number —
/// optional context, never authoritative quota.
enum BlockReferenceMode: String, CaseIterable {
    case off
    /// Compare against the user's highest *completed* block (self-derived).
    case peak
    /// Compare against a user-entered token count.
    case custom
}

/// Resolves a block-progress reference from the stored settings.
///
/// A pure function rather than a computed property on `AppModel`, because the
/// inputs live in `UserDefaults` and every reader observes them via
/// `@AppStorage` for reactivity — the popover, the status item and Settings all
/// pass their own bindings in and get the same answer.
enum BlockReference {
    /// The comparison value, or `nil` when there's nothing meaningful to
    /// compare against (mode off, or no history/number yet).
    static func tokens(mode: BlockReferenceMode, custom: Int, peak: Int) -> Int? {
        switch mode {
        case .off: nil
        case .peak: peak > 0 ? peak : nil
        case .custom: custom > 0 ? custom : nil
        }
    }

    /// Human phrase naming what the bar compares against.
    static func label(for mode: BlockReferenceMode) -> String {
        switch mode {
        case .off: ""
        case .peak: "your highest past block"
        case .custom: "your custom reference"
        }
    }

    /// Progress as a 0...1 fraction, clamped so an over-reference block shows a
    /// full bar rather than overflowing.
    static func fraction(tokens: Int, reference: Int) -> Double {
        guard reference > 0 else { return 0 }
        return min(1, Double(tokens) / Double(reference))
    }
}

/// What the menu-bar status item displays next to the gauge glyph.
///
/// A menu-bar meter that shows nothing but an icon is a launcher, not a meter —
/// this is the whole point of the app being in the menu bar.
enum MenuBarMetric: String, CaseIterable, Identifiable {
    /// Just the glyph — for people who want the app quiet.
    case iconOnly
    case todayTokens
    case todayCost
    /// How far through the current 5-hour block, against the chosen reference.
    case blockProgress
    /// This billing period's value multiple (needs a plan in Settings).
    case planMultiple

    var id: String { rawValue }

    var label: String {
        switch self {
        case .iconOnly: "Icon only"
        case .todayTokens: "Today's tokens"
        case .todayCost: "Today's estimated cost"
        case .blockProgress: "5-hour block progress"
        case .planMultiple: "Plan value multiple"
        }
    }

    /// Why the metric might show a dash, so Settings can say so up front.
    var requirement: String? {
        switch self {
        case .iconOnly, .todayTokens: nil
        case .todayCost: "Needs priced models — see Pricing."
        case .blockProgress: "Needs a reference — see Usage Windows."
        case .planMultiple: "Needs a plan — see Plan."
        }
    }
}

/// Where the app pulls live model prices from. All three resolve to the same
/// bundled/override layering; this only picks the *remote* base.
enum PricingSource: String, CaseIterable {
    /// LiteLLM's raw table, normalized in-app — works without our feed being
    /// published. The sensible default while the feed repo is private.
    case liteLLM = "litellm"
    /// Token Meter's own `pricing-feed/pricing.json` on GitHub.
    case tokenMeterFeed = "tokenmeter"
    /// A user-supplied URL in Token Meter's compact schema.
    case custom

    var label: String {
        switch self {
        case .liteLLM: "LiteLLM (direct)"
        case .tokenMeterFeed: "Token Meter feed"
        case .custom: "Custom URL"
        }
    }
}

/// One page of preferences.
///
/// Ordered by how often people need them, not alphabetically: the things you
/// set up once and revisit (plan, budgets) sit near the top, plumbing near the
/// bottom.
enum SettingsSection: String, CaseIterable, Identifiable, Hashable {
    case general
    case plan
    case budgets
    case dataSources
    case usageWindows
    case pricing
    case permissions

    var id: String { rawValue }

    var label: String {
        switch self {
        case .general: "General"
        case .plan: "Plan"
        case .budgets: "Budgets"
        case .dataSources: "Data Sources"
        case .usageWindows: "Usage Windows"
        case .pricing: "Pricing"
        case .permissions: "Permissions"
        }
    }

    var systemImage: String {
        switch self {
        case .general: "gearshape"
        case .plan: "creditcard"
        case .budgets: "bell.badge"
        case .dataSources: "folder"
        case .usageWindows: "hourglass"
        case .pricing: "dollarsign.circle"
        case .permissions: "lock.shield"
        }
    }

    /// One line of orientation under the page title, so a section's purpose is
    /// readable without opening it and guessing.
    var summary: String {
        switch self {
        case .general: "Menu bar readout, launch behavior, Dock icon, floating widget."
        case .plan: "What you pay, so usage can be shown as value rather than a bill."
        case .budgets: "Usage ceilings and the notifications that warn you."
        case .dataSources: "Where Claude Code, Codex and Ollama usage is read from."
        case .usageWindows: "What the 5-hour block progress compares against."
        case .pricing: "Where per-model prices come from, and per-model overrides."
        case .permissions: "Full Disk Access, needed to read the CLI logs."
        }
    }
}

/// The settings content, reused by both the ⌘, Settings scene and the main
/// window's Settings pane — so preferences live in one place.
///
/// A sidebar rather than a tab strip: at seven pages the icon-only toolbar was
/// cramped and unlabeled, so finding anything meant clicking through every icon
/// to see what it was. A list shows all seven names at once, matches the main
/// window's own navigation, and has room to say what each page is for.
struct SettingsNavigator: View {
    @State private var selection: SettingsSection = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSection.allCases, selection: $selection) { section in
                Label(section.label, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 184, max: 220)
        } detail: {
            SettingsPageView(section: selection)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

/// A single settings page, headed by its name and purpose.
///
/// Shared by the ⌘, window (which supplies its own sidebar) and the main
/// window (whose sidebar already lists every page), so the two can never drift
/// apart.
struct SettingsPageView: View {
    let section: SettingsSection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.label)
                        .font(.title2.weight(.semibold))
                    Text(section.summary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 20)

                page
            }
        }
        .frame(minWidth: 440)
    }

    @ViewBuilder
    private var page: some View {
        switch section {
        case .general: GeneralSettingsTab()
        case .plan: PlanSettingsTab()
        case .budgets: BudgetsSettingsTab()
        case .dataSources: DataSourcesSettingsTab()
        case .usageWindows: UsageWindowsSettingsTab()
        case .pricing: PricingSettingsTab()
        case .permissions: PermissionsSettingsTab()
        }
    }
}

/// The ⌘, Settings scene wrapper — sized for the sidebar + Dock-policy window
/// tracking. Resizable rather than fixed: the sidebar needs room, and pages
/// like Pricing hold a long scrolling list.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsNavigator()
            .frame(minWidth: 660, idealWidth: 720, minHeight: 460, idealHeight: 560)
            .onAppear { model.windowAppeared() }
            .onDisappear { model.windowDisappeared() }
    }
}

// MARK: - General

struct GeneralSettingsTab: View {
    @Environment(AppModel.self) private var model

    @AppStorage(PreferenceKey.dockIconMode)
    private var dockIconModeRaw = DockIconMode.whileWindowsOpen.rawValue

    @AppStorage(PreferenceKey.floatingHUDEnabled)
    private var floatingHUDEnabled = false

    @AppStorage(PreferenceKey.menuBarMetric)
    private var menuBarMetricRaw = MenuBarMetric.todayTokens.rawValue

    @AppStorage(PreferenceKey.openWindowAtLaunch)
    private var openWindowAtLaunch = false

    /// Mirrors the real `SMAppService` state, refreshed on appear because the
    /// user can change it in System Settings while we're open.
    @State private var launchAtLogin = false

    private var menuBarMetric: MenuBarMetric {
        MenuBarMetric(rawValue: menuBarMetricRaw) ?? .todayTokens
    }

    var body: some View {
        Form {
            Section {
                Picker("Menu bar shows", selection: $menuBarMetricRaw) {
                    ForEach(MenuBarMetric.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
            } header: {
                Text("Menu bar")
            } footer: {
                Text(menuBarFooter)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Toggle("Start Token Meter at login", isOn: Binding(
                    get: { launchAtLogin },
                    set: { newValue in
                        model.setLaunchAtLogin(newValue)
                        launchAtLogin = model.launchesAtLogin
                    }
                ))
                if model.launchAtLoginNeedsApproval {
                    HStack(spacing: 8) {
                        Label("Waiting for approval in System Settings", systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                        Button("Open Login Items") { LaunchAtLogin.openSystemSettings() }
                            .controlSize(.small)
                    }
                }
                Toggle("Open the main window at launch", isOn: $openWindowAtLaunch)
            } header: {
                Text("At launch")
            } footer: {
                Text("Token Meter only records usage while it's running, so starting at login is what keeps history complete. The window stays closed by default so it starts quietly in the menu bar — it always opens on your first run, and whenever you click the Dock icon or \"Open Token Meter\".")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                updateRow
            } header: {
                Text("Updates")
            } footer: {
                Text("Checks the project's GitHub releases for a newer version and links to it. Nothing is downloaded or installed automatically, and nothing about your usage is sent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section {
                Picker("Show in Dock", selection: $dockIconModeRaw) {
                    Text("While a window is open").tag(DockIconMode.whileWindowsOpen.rawValue)
                    Text("Always").tag(DockIconMode.always.rawValue)
                    Text("Never (menu bar only)").tag(DockIconMode.never.rawValue)
                }
                .pickerStyle(.radioGroup)
                .onChange(of: dockIconModeRaw) {
                    model.applyActivationPolicy()
                }
            } header: {
                Text("App behavior")
            } footer: {
                Text("Token Meter always lives in the menu bar. With a Dock icon it also behaves like a regular app — ⌘-Tab switching, standard menus, windows in front. \"Never\" keeps it menu-bar-only, but windows may open behind other apps.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Pin a floating widget on screen", isOn: $floatingHUDEnabled)
                    .onChange(of: floatingHUDEnabled) {
                        model.setFloatingHUDVisible(floatingHUDEnabled)
                    }
            } header: {
                Text("Floating widget")
            } footer: {
                Text("Keeps a small always-on-top card on screen with today's estimated tokens, cost, and the current 5-hour block. Drag it anywhere; it floats above other windows and appears on every Space without stealing focus. Close it from the card's ✕ or here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onAppear {
            launchAtLogin = model.launchesAtLogin
            if case .unknown = model.updateStatus {
                Task { await model.checkForUpdates() }
            }
        }
    }

    @ViewBuilder
    private var updateRow: some View {
        switch model.updateStatus {
        case .checking:
            LabeledContent("Version") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text("Checking…").foregroundStyle(.secondary)
                }
            }
        case .updateAvailable(let current, let latest, let url):
            VStack(alignment: .leading, spacing: 6) {
                Label("Version \(latest) is available", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(.green)
                Text("You're running \(current).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Link("View release", destination: url)
                    .controlSize(.small)
            }
        case .upToDate(let current):
            LabeledContent("Version") {
                HStack(spacing: 6) {
                    Text(current).monospacedDigit()
                    Text("· up to date").foregroundStyle(.secondary)
                }
            }
        case .failed:
            LabeledContent("Version") {
                HStack(spacing: 8) {
                    Text("Couldn't check").foregroundStyle(.secondary)
                    Button("Retry") { Task { await model.checkForUpdates() } }
                        .controlSize(.small)
                }
            }
        case .unknown:
            LabeledContent("Version") {
                Button("Check for Updates") {
                    Task { await model.checkForUpdates() }
                }
                .controlSize(.small)
            }
        }
    }

    private var menuBarFooter: String {
        let base = "The status item shows this beside the gauge. Log-derived numbers are estimates, and the readout hides itself rather than showing a placeholder when there's nothing to report yet."
        guard let requirement = menuBarMetric.requirement else { return base }
        return "\(base) \(requirement)"
    }
}

// MARK: - Plan

/// Lets the user say what they actually pay, which is the only way the app can
/// tell them what a big estimated-cost number means. Without it, "$2,530" reads
/// like a bill; with it, it reads like leverage.
struct PlanSettingsTab: View {
    @Environment(AppModel.self) private var model

    @AppStorage(PreferenceKey.subscriptionPlan)
    private var planRaw = SubscriptionPlan.unset.rawValue

    /// Local edit buffer so the field doesn't fight the user mid-typing.
    @State private var priceText = ""
    @State private var cycleDay = 1

    private var plan: SubscriptionPlan {
        SubscriptionPlan(rawValue: planRaw) ?? .unset
    }

    var body: some View {
        Form {
            Section {
                Picker("Plan", selection: $planRaw) {
                    ForEach(SubscriptionPlan.allCases) { option in
                        Text(option.label).tag(option.rawValue)
                    }
                }
                .onChange(of: planRaw) {
                    model.setSubscriptionPlan(plan)
                    priceText = formattedPrice
                }

                if plan.showsValueComparison {
                    LabeledContent("Monthly price") {
                        HStack(spacing: 4) {
                            Text(verbatim: "$")
                                .foregroundStyle(.secondary)
                            TextField("0", text: $priceText)
                                .frame(width: 80)
                                .multilineTextAlignment(.trailing)
                                .onSubmit(commitPrice)
                            Button("Set", action: commitPrice)
                                .controlSize(.small)
                        }
                    }

                    Picker("Renews on day", selection: $cycleDay) {
                        ForEach(Array(BillingPeriod.dayRange), id: \.self) { day in
                            Text(day.formatted()).tag(day)
                        }
                    }
                    .onChange(of: cycleDay) { model.setPlanCycleStartDay(cycleDay) }
                }
            } header: {
                Text("What you pay")
            } footer: {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if plan.showsValueComparison {
                Section {
                    PlanValueSummary(value: model.planValue)
                } header: {
                    Text("This billing period")
                }
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onAppear {
            priceText = formattedPrice
            cycleDay = model.planCycleStartDay
        }
    }

    private var formattedPrice: String {
        let price = model.planMonthlyPriceUSD
        return price > 0 ? NSDecimalNumber(decimal: price).stringValue : ""
    }

    private func commitPrice() {
        // Accept "20", "20.00", "$20" — reject anything else without clobbering
        // the stored value.
        let cleaned = priceText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        guard let value = Decimal(string: cleaned), value >= 0 else {
            priceText = formattedPrice
            return
        }
        model.setPlanMonthlyPrice(value)
        priceText = formattedPrice
    }

    private var footerText: String {
        switch plan {
        case .unset:
            "Tell Token Meter what you pay and it can show what your usage would have cost on pay-as-you-go API pricing — the number that makes a subscription look like a bargain or a waste. Nothing is sent anywhere."
        case .payAsYouGo:
            "On metered API billing the estimate already approximates your invoice, so there's no plan fee to compare against. It's still an estimate, not a bill."
        default:
            "Prices are the vendor list price at the time this build shipped — edit if yours differs. \"Renews on day\" anchors the period to your actual billing date rather than the 1st."
        }
    }
}

/// The value readout, shared by Settings and the Overview pane.
struct PlanValueSummary: View {
    let value: PlanValue

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Observed usage") {
                Text(value.observedCostUSD, format: .currency(code: "USD"))
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .monospacedDigit()
            }
            LabeledContent("You pay") {
                Text(value.monthlyPriceUSD, format: .currency(code: "USD"))
                    .monospacedDigit()
            }
            if let multiple = value.valueMultiple {
                LabeledContent("Value multiple") {
                    Text(PlanValueFormat.multiple(multiple))
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(value.hasBrokenEven ? .green : .secondary)
                        .monospacedDigit()
                }
            }
            Text(PlanValueFormat.caveat(for: value))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Shared copy + number formatting for the plan comparison, so the menu bar,
/// Overview and Settings can't drift apart on the honesty wording.
enum PlanValueFormat {
    /// "126×" — no decimals once it's large, one below 10 so early days in a
    /// period don't collapse to a flat "0×".
    ///
    /// Locale-aware by default (a German user should read "2,5×"); the
    /// parameter exists so tests can pin a locale instead of depending on
    /// whatever the machine is set to.
    static func multiple(_ value: Decimal, locale: Locale = .autoupdatingCurrent) -> String {
        let number = NSDecimalNumber(decimal: value).doubleValue
        let digits = number < 10 ? 1 : 0
        let formatted = number.formatted(
            .number.precision(.fractionLength(digits)).locale(locale)
        )
        return formatted + "×"
    }

    static func periodLabel(_ value: PlanValue) -> String {
        let start = value.period.start.formatted(.dateTime.month(.abbreviated).day())
        let end = value.period.end.addingTimeInterval(-1)
            .formatted(.dateTime.month(.abbreviated).day())
        return "\(start) – \(end)"
    }

    /// The honesty line. Every claim here has to stay defensible: the figure is
    /// a floor built from local logs, not a bill and not a guarantee.
    static func caveat(for value: PlanValue) -> String {
        var parts = [
            "Estimated API list-price equivalent of usage Token Meter saw this period — not a bill, and not a refund you're owed."
        ]
        if value.isPartialPeriod {
            parts.append("History doesn't reach the start of this period, so the real figure is higher.")
        }
        if !value.unpricedModels.isEmpty {
            let names = value.unpricedModels.sorted().joined(separator: ", ")
            parts.append("Excludes unpriced models (\(names)).")
        }
        return parts.joined(separator: " ")
    }
}

// MARK: - Budgets

/// Usage ceilings + the notifications that fire when you approach them.
///
/// Honesty guardrail: a budget is the **user's own** ceiling. Nothing here may
/// imply Token Meter knows a vendor quota, because it doesn't.
struct BudgetsSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                permissionRow
            } header: {
                Text("Notifications")
            } footer: {
                Text("Alerts fire at 50%, 80% and 100% of a budget, at most once per window — a long session won't repeat them. Budgets are compared against usage reconstructed from local logs, so they're estimates, not your plan's real quota.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach(BudgetScope.allCases) { scope in
                BudgetRowView(scope: scope)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .task { await model.refreshNotificationPermission() }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch model.notificationPermission {
        case .granted:
            LabeledContent("Permission") {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            }
        case .denied:
            VStack(alignment: .leading, spacing: 6) {
                Label("Notifications are turned off", systemImage: "bell.slash")
                    .foregroundStyle(.orange)
                Text("Your usage is still tracked and shown in the app, but no budget alerts can be delivered. Turn Token Meter back on in System Settings → Notifications.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Notification Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        case .notRequested, .unknown:
            VStack(alignment: .leading, spacing: 6) {
                Text("Token Meter needs permission before it can alert you.")
                    .font(.callout)
                Button("Enable Notifications") {
                    Task { await model.requestNotificationPermission() }
                }
            }
        }
    }
}

/// One budget row. Kept separate so each scope owns its own edit buffer and
/// they don't fight each other while typing.
private struct BudgetRowView: View {
    @Environment(AppModel.self) private var model
    let scope: BudgetScope

    @State private var isEnabled = false
    @State private var limitText = ""

    private var budget: Budget { model.budget(for: scope) }

    var body: some View {
        Section {
            Toggle("Alert me about \(scope.label.lowercased())", isOn: $isEnabled)
                .onChange(of: isEnabled) { commit() }

            if isEnabled && scope != .block {
                LabeledContent("Budget") {
                    HStack(spacing: 4) {
                        Text(verbatim: "$")
                            .foregroundStyle(.secondary)
                        TextField("0", text: $limitText)
                            .frame(width: 80)
                            .multilineTextAlignment(.trailing)
                            .onSubmit(commit)
                        Button("Set", action: commit)
                            .controlSize(.small)
                    }
                }
            }
        } header: {
            Text(scope.label)
        } footer: {
            Text(footer)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            isEnabled = budget.isEnabled
            limitText = budget.limit > 0
                ? NSDecimalNumber(decimal: budget.limit).stringValue
                : ""
        }
    }

    private var footer: String {
        switch scope {
        case .block:
            // No separate number: reusing the existing reference avoids two
            // settings that mean the same thing and can disagree.
            "Measured in tokens against the reference you picked in Usage Windows. With that set to \"Nothing\", there's no ceiling to compare against and this stays quiet."
        case .daily:
            "Estimated cost of today's usage."
        case .weekly:
            "Estimated cost across the calendar week."
        case .billingPeriod:
            "Estimated cost across your plan's billing period — set the renewal day under Plan."
        }
    }

    private func commit() {
        let cleaned = limitText
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        let limit = Decimal(string: cleaned) ?? 0
        model.setBudget(Budget(scope: scope, isEnabled: isEnabled, limit: max(0, limit)))
        limitText = limit > 0 ? NSDecimalNumber(decimal: limit).stringValue : ""
    }
}

// MARK: - Usage Windows

struct UsageWindowsSettingsTab: View {
    @AppStorage(PreferenceKey.blockReferenceMode)
    private var referenceModeRaw = BlockReferenceMode.off.rawValue

    @AppStorage(PreferenceKey.blockReferenceCustomTokens)
    private var customTokens = 0

    private var referenceMode: BlockReferenceMode {
        BlockReferenceMode(rawValue: referenceModeRaw) ?? .off
    }

    var body: some View {
        Form {
            Section {
                Picker("Show block progress against", selection: $referenceModeRaw) {
                    Text("Nothing (just the count)").tag(BlockReferenceMode.off.rawValue)
                    Text("My highest past block").tag(BlockReferenceMode.peak.rawValue)
                    Text("A custom token count").tag(BlockReferenceMode.custom.rawValue)
                }
                .pickerStyle(.radioGroup)

                if referenceMode == .custom {
                    TextField(
                        "Custom reference (tokens)",
                        value: $customTokens,
                        format: .number
                    )
                }
            } header: {
                Text("5-hour block progress")
            } footer: {
                Text("Anthropic publishes no official token numbers for the Pro/Max 5-hour window, and Token Meter can't read your real quota. These references are optional context only — your own history or your own number — and the displayed block is reconstructed from local logs (estimated).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }
}

// MARK: - Data Sources

struct DataSourcesSettingsTab: View {
    @Environment(AppModel.self) private var model

    @AppStorage(PreferenceKey.claudeLogsPathOverride)
    private var claudeLogsPathOverride = ""

    @AppStorage(PreferenceKey.codexLogsPathOverride)
    private var codexLogsPathOverride = ""

    @AppStorage(PreferenceKey.ollamaEnabled)
    private var ollamaEnabled = false

    @AppStorage(PreferenceKey.ollamaUpstreamURL)
    private var ollamaUpstreamURL = ""

    @AppStorage(PreferenceKey.ollamaProxyPort)
    private var ollamaProxyPort = 11_435

    /// Default location of Claude Code's JSONL logs.
    private static let defaultClaudeLogsPath = "~/.claude/projects"
    /// Default location of Codex CLI's session logs.
    private static let defaultCodexLogsPath = "~/.codex/sessions"

    var body: some View {
        Form {
            claudeSection
            codexSection
            ollamaSection
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    private var claudeSection: some View {
        Section {
            TextField(
                "Claude Code logs",
                text: $claudeLogsPathOverride,
                prompt: Text(Self.defaultClaudeLogsPath)
            )
            .autocorrectionDisabled()
            if !claudeLogsPathOverride.isEmpty {
                Button("Reset to Default") {
                    claudeLogsPathOverride = ""
                }
            }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("Leave empty to use the default (\(Self.defaultClaudeLogsPath)). Changes take effect after relaunching Token Meter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Codex

    private var codexSection: some View {
        Section {
            LabeledContent("Status") {
                Text(accessStatusText(model.codexAccessStatus, root: model.codexLogsRootDisplayPath))
                    .foregroundStyle(accessStatusColor(model.codexAccessStatus))
                    .multilineTextAlignment(.trailing)
            }
            TextField(
                "Codex CLI logs",
                text: $codexLogsPathOverride,
                prompt: Text(Self.defaultCodexLogsPath)
            )
            .autocorrectionDisabled()
            if !codexLogsPathOverride.isEmpty {
                Button("Reset to Default") {
                    codexLogsPathOverride = ""
                }
            }
        } header: {
            Text("Codex CLI")
        } footer: {
            Text("OpenAI's Codex CLI logs token usage locally, same as Claude Code. Leave empty to use the default (\(Self.defaultCodexLogsPath)). Counts are **estimated** (local logs under-report) and reading them needs Full Disk Access (see Permissions). Changes take effect after relaunching Token Meter.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// Readability status line, shared by the log-based sources.
    private func accessStatusText(_ status: LogAccessStatus, root: String) -> String {
        switch status {
        case .checking: "Checking…"
        case .accessible: "Watching \(root)"
        case .notFound: "No logs at \(root)"
        case .denied: "Can't read — grant Full Disk Access"
        }
    }

    private func accessStatusColor(_ status: LogAccessStatus) -> Color {
        switch status {
        case .checking: .secondary
        case .accessible: .green
        case .notFound: .orange
        case .denied: .red
        }
    }

    // MARK: Ollama

    private var ollamaSection: some View {
        Section {
            Toggle("Track local models (Ollama)", isOn: $ollamaEnabled)
                .onChange(of: ollamaEnabled) { _, enabled in
                    model.setOllamaTracking(enabled: enabled)
                }

            if ollamaEnabled {
                LabeledContent("Server") {
                    Text(serverStatusText)
                }
                LabeledContent("Capture") {
                    Text(captureStatusText)
                        .foregroundStyle(model.ollamaState.captureError == nil ? .primary : Color.orange)
                }
                TextField(
                    "Ollama server URL",
                    text: $ollamaUpstreamURL,
                    prompt: Text("http://127.0.0.1:11434")
                )
                .autocorrectionDisabled()
                TextField("Proxy port", value: $ollamaProxyPort, format: .number.grouping(.never))
            }
        } header: {
            Text("Local models (Ollama)")
        } footer: {
            Text(ollamaFooterText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var serverStatusText: String {
        switch model.ollamaState.server {
        case .unknown:
            "Checking…"
        case .notInstalled:
            "Not installed"
        case .notRunning:
            "Installed, not running"
        case .running(let version, let installed, let loaded):
            "Running v\(version) · \(installed) models installed · \(loaded) loaded"
        }
    }

    private var captureStatusText: String {
        if let error = model.ollamaState.captureError {
            return error
        }
        if let port = model.ollamaState.capturePort {
            return "Listening on 127.0.0.1:\(port)"
        }
        return "Off"
    }

    private var ollamaFooterText: String {
        var text = "Ollama has no usage-history API — token counts only exist inside each response. Token Meter runs a local pass-through proxy: point your apps at http://127.0.0.1:\(ollamaProxyPort) (e.g. export OLLAMA_HOST, or the base-URL setting in your client) and requests are forwarded to Ollama untouched while token counts are read from the responses. Loopback-only; prompts are never inspected or stored."
        text += " Counts are measured by the runtime, with no cost (local). Note: Ollama may report an inaccurate prompt token count when a prompt exceeds the model's context window."
        if ollamaEnabled {
            text += " URL/port changes apply the next time tracking is toggled on."
        }
        return text
    }
}

// MARK: - Pricing

struct PricingSettingsTab: View {
    @Environment(AppModel.self) private var model

    @AppStorage(PreferenceKey.pricingSource)
    private var pricingSourceRaw = PricingSource.liteLLM.rawValue

    @AppStorage(PreferenceKey.pricingFeedURL)
    private var feedURLString = ""

    @State private var isRefreshing = false

    private var pricingSource: PricingSource {
        PricingSource(rawValue: pricingSourceRaw) ?? .liteLLM
    }

    var body: some View {
        Form {
            feedSection
            modelsSection
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }

    // MARK: Feed

    private var feedSection: some View {
        Section {
            Picker("Source", selection: $pricingSourceRaw) {
                ForEach(PricingSource.allCases, id: \.rawValue) { source in
                    Text(source.label).tag(source.rawValue)
                }
            }
            .onChange(of: pricingSourceRaw) { refreshNow() }

            if pricingSource == .custom {
                TextField(
                    "Feed URL",
                    text: $feedURLString,
                    prompt: Text(AppModel.defaultPricingFeedURL.absoluteString)
                )
                .autocorrectionDisabled()
            }

            LabeledContent("Prices") {
                Text(feedStatusText)
            }
            Button(isRefreshing ? "Refreshing…" : "Refresh Now") {
                refreshNow()
            }
            .disabled(isRefreshing)
        } header: {
            Text("Pricing source")
        } footer: {
            Text(sourceFooter)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var sourceFooter: String {
        switch pricingSource {
        case .liteLLM:
            "Pulls prices straight from LiteLLM's community-maintained table (MIT), normalized in the app. Works without any Token Meter server. Checked about once a day while the app runs; your edits below always win."
        case .tokenMeterFeed:
            "Token Meter's own daily-updated pricing file (pricing-feed/ in the repo), normalized from the same community data. Requires the feed repo to be published; falls back to bundled prices otherwise."
        case .custom:
            "Point at any URL serving Token Meter's compact pricing schema. Leave empty to disable remote refresh (bundled prices + your edits still apply)."
        }
    }

    private func refreshNow() {
        isRefreshing = true
        Task {
            await model.refreshPricingNow()
            isRefreshing = false
        }
    }

    private var feedStatusText: String {
        guard let status = model.pricingStatus else { return "unavailable" }
        let date = status.generatedAt.formatted(date: .abbreviated, time: .omitted)
        return "\(status.modelCount) models · \(status.origin.rawValue) · updated \(date)"
    }

    // MARK: Model rows

    /// Models worth showing: everything seen in usage plus anything the user
    /// has overridden (even if not seen lately).
    private var editableModels: [String] {
        var names = model.modelsSeenInUsage
        for overridden in model.pricingOverrides.keys where !names.contains(overridden) {
            names.append(overridden)
        }
        return names
    }

    private var modelsSection: some View {
        Section {
            if editableModels.isEmpty {
                Text("Models appear here once usage is recorded.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(editableModels, id: \.self) { name in
                    PricingRowView(modelName: name)
                }
            }
        } header: {
            Text("Model prices (USD per million tokens)")
        } footer: {
            Text("Prices are user-maintained estimates, not invoices. Editing a value stores a local override that wins over the feed; Reset returns to feed pricing. Models without any price are excluded from cost totals — the app never guesses.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One editable pricing row. Shows the effective price; any edit becomes a
/// local override.
private struct PricingRowView: View {
    @Environment(AppModel.self) private var model
    let modelName: String

    var body: some View {
        let effective = model.pricingResolver.pricing(for: modelName)
        let hasOverride = model.pricingOverrides[modelName] != nil

        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(modelName)
                    .font(.callout.weight(.medium))
                if hasOverride {
                    Text("override")
                        .font(.caption2)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                }
                if effective == nil {
                    Text("no price — excluded from costs")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Spacer()
                if hasOverride {
                    Button("Reset") {
                        model.setPricingOverride(model: modelName, pricing: nil)
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                tierField("In", value: effective?.inputPerMTok) { newValue in
                    save { $0.inputPerMTok = newValue ?? 0 }
                }
                tierField("Out", value: effective?.outputPerMTok) { newValue in
                    save { $0.outputPerMTok = newValue ?? 0 }
                }
                tierField("Cache read", value: effective?.cacheReadPerMTok) { newValue in
                    save { $0.cacheReadPerMTok = newValue }
                }
                tierField("Cache write", value: effective?.cacheWritePerMTok) { newValue in
                    save { $0.cacheWritePerMTok = newValue }
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// Applies an edit on top of the effective price (or zeros) and stores
    /// it as this model's override.
    private func save(_ mutate: (inout ModelPricing) -> Void) {
        var pricing = model.pricingResolver.pricing(for: modelName)
            ?? ModelPricing(inputPerMTok: 0, outputPerMTok: 0)
        mutate(&pricing)
        model.setPricingOverride(model: modelName, pricing: pricing)
    }

    private func tierField(
        _ label: String,
        value: Decimal?,
        onCommit: @escaping (Decimal?) -> Void
    ) -> some View {
        TierFieldView(label: label, initial: value, onCommit: onCommit)
    }
}

/// Small labeled decimal field that commits on submit/focus-out only, so
/// typing doesn't spam overrides.
private struct TierFieldView: View {
    let label: String
    let initial: Decimal?
    let onCommit: (Decimal?) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
            TextField("—", text: $text)
                .textFieldStyle(.roundedBorder)
                .controlSize(.small)
                .frame(width: 76)
                .focused($focused)
                .onSubmit(commit)
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
        }
        .onAppear { text = initial.map { "\($0)" } ?? "" }
        .onChange(of: initial) { _, newValue in
            if !focused { text = newValue.map { "\($0)" } ?? "" }
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parsed = Decimal(string: trimmed, locale: .current) ?? Decimal(string: trimmed)
        let normalized: Decimal? = trimmed.isEmpty ? nil : parsed
        guard normalized != initial else { return }
        onCommit(normalized)
    }
}

// MARK: - Permissions

struct PermissionsSettingsTab: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                LabeledContent("Log access") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(statusColor)
                            .frame(width: 8, height: 8)
                        Text(statusLabel)
                    }
                }
                Button("Check Again") {
                    model.refreshAccessStatus()
                }
            } header: {
                Text("Claude Code logs")
            } footer: {
                Text(statusGuidance)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("If macOS blocks access to the log folder, grant Token Meter Full Disk Access, then quit and reopen the app.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Full Disk Access Settings…") {
                    openFullDiskAccessSettings()
                }
            } header: {
                Text("Full Disk Access")
            } footer: {
                Text("Everything stays on this Mac — log data is never uploaded anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
        .onAppear {
            model.refreshAccessStatus()
        }
    }

    private var statusLabel: String {
        switch model.logAccessStatus {
        case .checking: "Checking…"
        case .accessible: "Readable"
        case .notFound: "Not found"
        case .denied: "Blocked"
        }
    }

    private var statusColor: Color {
        switch model.logAccessStatus {
        case .checking: .gray
        case .accessible: .green
        case .notFound: .orange
        case .denied: .red
        }
    }

    private var statusGuidance: String {
        switch model.logAccessStatus {
        case .checking:
            "Checking whether \(model.logsRootDisplayPath) is readable."
        case .accessible:
            "\(model.logsRootDisplayPath) is readable — usage updates as Claude Code writes its logs."
        case .notFound:
            "\(model.logsRootDisplayPath) doesn't exist. Install Claude Code or run a session to create it, or point Token Meter elsewhere in Data Sources. Token Meter picks it up automatically once it appears."
        case .denied:
            "\(model.logsRootDisplayPath) exists but can't be read. Grant Full Disk Access below, then relaunch Token Meter."
        }
    }

    private func openFullDiskAccessSettings() {
        // Deep link into System Settings → Privacy & Security → Full Disk Access.
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview {
    SettingsView()
        .environment(AppModel())
}
