// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// Window scene identifiers.
enum WindowID {
    static let main = "main"
}

/// Sections of the centralized desktop window.
///
/// Settings pages are cases here rather than a nested navigator: the window
/// already owns a sidebar, and putting a second one inside it would bury every
/// preference two clicks deep behind an unlabeled icon strip. Listing the pages
/// in the one sidebar makes all of them reachable in a single click.
enum MainSection: Identifiable, Hashable {
    case overview
    case history
    case settings(SettingsSection)

    /// The entry point used when something just wants "open Settings".
    static let settingsHome = MainSection.settings(.general)

    static let topLevel: [MainSection] = [.overview, .history]
    static let settingsPages: [MainSection] = SettingsSection.allCases.map { .settings($0) }

    var id: String {
        switch self {
        case .overview: "overview"
        case .history: "history"
        case .settings(let page): "settings.\(page.rawValue)"
        }
    }

    var label: String {
        switch self {
        case .overview: "Overview"
        case .history: "History"
        case .settings(let page): page.label
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "gauge.with.needle"
        case .history: "chart.bar.xaxis"
        case .settings(let page): page.systemImage
        }
    }

    var settingsPage: SettingsSection? {
        if case .settings(let page) = self { return page }
        return nil
    }
}

/// The full desktop app: a sidebar-driven window that gathers the overview,
/// usage history, and settings in one place — so TokenMeter is usable as a
/// regular app, not only from the menu bar. The menu-bar popover stays the
/// quick glance and opens this window.
struct MainWindowView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selection = Binding<MainSection?>(
            get: { model.mainSelection },
            set: { if let value = $0 { model.mainSelection = value } }
        )

        NavigationSplitView {
            List(selection: selection) {
                ForEach(MainSection.topLevel) { section in
                    Label(section.label, systemImage: section.systemImage)
                        .tag(section)
                }
                Section("Settings") {
                    ForEach(MainSection.settingsPages) { section in
                        Label(section.label, systemImage: section.systemImage)
                            .tag(section)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 176, ideal: 196, max: 240)
        } detail: {
            Group {
                switch model.mainSelection {
                case .overview: OverviewPane()
                case .history: HistoryView()
                case .settings(let page): SettingsPageView(section: page)
                }
            }
            .frame(minWidth: 640, minHeight: 540)
        }
        .navigationTitle("Token Meter")
        .onAppear {
            model.refreshNow()
            model.windowAppeared()
        }
        .onDisappear {
            model.windowDisappeared()
        }
    }
}

/// Window-sized dashboard: today's estimated usage, the current 5-hour Claude
/// block, this week, and per-source status. Reuses the popover's tile and
/// badge components; all log-derived numbers are labeled **estimated**.
struct OverviewPane: View {
    @Environment(AppModel.self) private var model

    private var summary: UsageSummary { model.todaySummary }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                todayGlance
                tiles
                if model.planValue.plan.showsValueComparison {
                    planValuePanel
                }
                if model.cacheEfficiency.hasData {
                    cachePanel
                }
                usageWindows
                sourcesSection
                footer
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { model.refreshNow() }
    }

    private var header: some View {
        HStack {
            Label("Overview", systemImage: "gauge.with.needle")
                .font(.title2.weight(.semibold))
            Spacer()
            EstimatedBadge()
        }
    }

    private var todayGlance: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(summary.tokens.total, format: .number.notation(.compactName))
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .contentTransition(.numericText())
                    Text("tokens")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Est. cost")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text(summary.estimatedCostUSD.map {
                    $0.formatted(.currency(code: "USD"))
                } ?? "—")
                    .font(.system(.title, design: .rounded, weight: .medium))
                    .foregroundStyle(summary.estimatedCostUSD == nil ? .secondary : .primary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var tiles: some View {
        HStack(spacing: 10) {
            SummaryTile(title: "Input", value: summary.tokens.input, systemImage: "arrow.down.circle")
            SummaryTile(title: "Output", value: summary.tokens.output, systemImage: "arrow.up.circle")
            SummaryTile(
                title: "Cache",
                value: summary.tokens.cacheRead + summary.tokens.cacheCreation,
                systemImage: "archivebox"
            )
        }
    }

    // MARK: - Plan value

    /// The reframe: the same estimated cost, stated as what it bought against
    /// what the user pays. This is the answer to "why does it say $2,530 when
    /// my plan is $20?"
    private var planValuePanel: some View {
        let value = model.planValue
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Plan value")
                    .font(.headline)
                Spacer()
                Text(PlanValueFormat.periodLabel(value))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(value.observedCostUSD, format: .currency(code: "USD"))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text("of usage on a \(value.monthlyPriceUSD.formatted(.currency(code: "USD"))) plan")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            if let multiple = value.valueMultiple {
                HStack(spacing: 8) {
                    Text(PlanValueFormat.multiple(multiple))
                        .font(.system(.title2, design: .rounded, weight: .bold))
                        .foregroundStyle(value.hasBrokenEven ? .green : .orange)
                        .monospacedDigit()
                    Text(value.hasBrokenEven ? "return on what you pay" : "of the way to breaking even")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Text(PlanValueFormat.caveat(for: value))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - Cache efficiency

    /// Cache reads dominate an agentic-coding bill, so this is the one panel
    /// that points at something the user can actually change.
    private var cachePanel: some View {
        let cache = model.cacheEfficiency
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Prompt caching")
                    .font(.headline)
                Spacer()
                Text(PlanValueFormat.periodLabel(model.planValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(cache.savingsUSD, format: .currency(code: "USD"))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .foregroundStyle(cache.savingsUSD > 0 ? .green : .primary)
                    .contentTransition(.numericText())
                    .monospacedDigit()
                Text("avoided by caching")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                cacheStat(
                    "Cache hit rate",
                    cache.hitRate.formatted(.percent.precision(.fractionLength(0))),
                    help: "Share of prompt tokens served from cache rather than sent fresh."
                )
                cacheStat(
                    "Cost avoided",
                    cache.savingsRate.formatted(.percent.precision(.fractionLength(0))),
                    help: "How much of the uncached figure caching removed."
                )
                cacheStat(
                    "Without caching",
                    cache.withoutCacheCostUSD.formatted(.currency(code: "USD")),
                    help: "The same tokens billed with no cache tiers."
                )
            }

            Text("Compares your actual estimated cost against the same traffic billed with every cached token charged as ordinary input. A like-for-like comparison of these exact tokens, not a prediction — without caching you'd likely work in shorter sessions and send fewer.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private func cacheStat(_ title: String, _ value: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(.title3, design: .rounded, weight: .semibold))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .help(help)
    }

    // MARK: - Usage windows

    private var usageWindows: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Usage windows")
                .font(.headline)
            HStack(spacing: 10) {
                windowCard(
                    title: "5-hour block",
                    systemImage: "hourglass",
                    value: model.currentBlock?.tokens.total,
                    caption: blockCaption
                )
                windowCard(
                    title: "This week",
                    systemImage: "calendar",
                    value: model.weekSummary.tokens.total,
                    caption: "calendar week (estimated)"
                )
            }
        }
    }

    private var blockCaption: String {
        guard let block = model.currentBlock else {
            return "none active — starts with your next Claude Code message"
        }
        return "ends \(block.end.formatted(date: .omitted, time: .shortened)) · Claude only"
    }

    private func windowCard(title: String, systemImage: String, value: Int?, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value ?? 0, format: .number.notation(.compactName))
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
            Text(caption)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Sources

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sources")
                .font(.headline)
            sourceRow(name: "Claude Code", status: model.logAccessStatus, root: model.logsRootDisplayPath)
            sourceRow(name: "Codex CLI", status: model.codexAccessStatus, root: model.codexLogsRootDisplayPath)
            if showsOllamaRow {
                HStack(spacing: 8) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Local (Ollama)").font(.callout)
                    Spacer()
                    Text("\(model.ollamaTodayTokens.formatted(.number.notation(.compactName))) tokens today")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var showsOllamaRow: Bool {
        guard model.isOllamaTrackingEnabled else { return false }
        if case .running = model.ollamaState.server { return true }
        return model.ollamaTodayTokens > 0
    }

    private func sourceRow(name: String, status: LogAccessStatus, root: String) -> some View {
        HStack(spacing: 8) {
            Circle().fill(color(for: status)).frame(width: 7, height: 7)
            Text(name).font(.callout)
            Spacer()
            Text(text(for: status, root: root))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func color(for status: LogAccessStatus) -> Color {
        switch status {
        case .checking: .gray
        case .accessible: .green
        case .notFound: .orange
        case .denied: .red
        }
    }

    private func text(for status: LogAccessStatus, root: String) -> String {
        switch status {
        case .checking: "Checking…"
        case .accessible: "Watching \(root)"
        case .notFound: "No logs found"
        case .denied: "Needs Full Disk Access"
        }
    }

    private var footer: some View {
        Text("All log-derived numbers are estimates reconstructed from local CLI logs — not billing data, not your real subscription quota. The 5-hour block reflects Claude Code only.")
            .font(.caption)
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

#Preview {
    MainWindowView()
        .environment(AppModel())
}
