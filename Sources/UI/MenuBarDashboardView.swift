// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The menu-bar popover dashboard.
///
/// UI copy rule: every number derived from local logs is labeled
/// **estimated** — never presented as real subscription quota.
struct MenuBarDashboardView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    private var summary: UsageSummary { model.todaySummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            todayGlance
            tiles
            if !summary.hasData {
                emptyStateNote
            }
            Divider()
            usageWindows
            statusRow
            Divider()
            footer
        }
        .padding(12)
        .frame(width: 320)
        .onAppear {
            model.refreshNow()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Label("Token Meter", systemImage: "gauge.with.needle")
                .font(.headline)
            Spacer()
            EstimatedBadge()
        }
    }

    /// Today's total tokens + estimated cost "at a glance".
    private var todayGlance: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Today")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(summary.tokens.total, format: .number.notation(.compactName))
                        .font(.system(.title, design: .rounded, weight: .semibold))
                        .contentTransition(.numericText())
                    Text("tokens")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .help("\(summary.tokens.total.formatted()) tokens (estimated)")
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("Est. cost")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(costText)
                    .font(.system(.title2, design: .rounded, weight: .medium))
                    .foregroundStyle(summary.estimatedCostUSD == nil ? .secondary : .primary)
                    .contentTransition(.numericText())
                    .help(costHelp)
            }
        }
    }

    private var costText: String {
        summary.estimatedCostUSD?.formatted(.currency(code: "USD")) ?? "—"
    }

    private var costHelp: String {
        if summary.estimatedCostUSD == nil {
            return "No priced usage today. Prices live in Settings → Pricing."
        }
        if model.unpricedModels.isEmpty {
            return "Estimated from your pricing table — not an invoice, not your subscription quota."
        }
        return "Estimated from your pricing table — not an invoice. Some models are unpriced and excluded (see Settings → Pricing)."
    }

    // MARK: - Tiles

    private var tiles: some View {
        HStack(spacing: 8) {
            SummaryTile(
                title: "Input",
                value: summary.tokens.input,
                systemImage: "arrow.down.circle"
            )
            SummaryTile(
                title: "Output",
                value: summary.tokens.output,
                systemImage: "arrow.up.circle"
            )
            SummaryTile(
                title: "Cache",
                value: summary.tokens.cacheRead + summary.tokens.cacheCreation,
                systemImage: "archivebox"
            )
        }
    }

    private var emptyStateNote: some View {
        Text(
            model.logAccessStatus == .accessible
                ? "No Claude Code usage recorded today."
                : "No usage data yet."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: - Usage windows (estimated, never real quota)

    @AppStorage(PreferenceKey.blockReferenceMode)
    private var referenceModeRaw = BlockReferenceMode.off.rawValue

    @AppStorage(PreferenceKey.blockReferenceCustomTokens)
    private var customReferenceTokens = 0

    /// Optional comparison value for the block progress bar. `nil` → no bar.
    private var blockReferenceTokens: Int? {
        switch BlockReferenceMode(rawValue: referenceModeRaw) ?? .off {
        case .off:
            nil
        case .peak:
            model.peakBlockTokens > 0 ? model.peakBlockTokens : nil
        case .custom:
            customReferenceTokens > 0 ? customReferenceTokens : nil
        }
    }

    private var referenceLabel: String {
        switch BlockReferenceMode(rawValue: referenceModeRaw) ?? .off {
        case .off: ""
        case .peak: "your highest past block"
        case .custom: "your custom reference"
        }
    }

    private var usageWindows: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let block = model.currentBlock {
                HStack(alignment: .firstTextBaseline) {
                    Label("5-hour block", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(block.tokens.total, format: .number.notation(.compactName))
                        .font(.system(.callout, design: .rounded, weight: .semibold))
                        .contentTransition(.numericText())
                        .help("\(block.tokens.total.formatted()) tokens in the current block (estimated)")
                }

                if let reference = blockReferenceTokens {
                    ProgressView(
                        value: Double(min(block.tokens.total, reference)),
                        total: Double(reference)
                    )
                    .controlSize(.small)
                    .tint(block.tokens.total >= reference ? .orange : .accentColor)
                    Text("\(percent(block.tokens.total, of: reference)) of \(referenceLabel) — estimated, not your real quota")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                // `style: .relative` self-updates — the countdown stays live
                // while the popover is open, no timer needed.
                (Text("Ends \(block.end, format: .dateTime.hour().minute()) · ")
                    + Text(block.end, style: .relative)
                    + Text(" left"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                HStack {
                    Label("5-hour block", systemImage: "hourglass")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("none active")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .help("Blocks are reconstructed from log timestamps (estimated). A new one starts with your next Claude Code message.")
                }
            }

            HStack(alignment: .firstTextBaseline) {
                Label("This week", systemImage: "calendar")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(model.weekSummary.tokens.total, format: .number.notation(.compactName))
                    .font(.system(.callout, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())
                    .help("\(model.weekSummary.tokens.total.formatted()) tokens this calendar week (estimated)")
            }

            if showsOllamaRow {
                ollamaRow
            }
        }
    }

    // MARK: - Local models (Ollama)

    private var showsOllamaRow: Bool {
        guard model.isOllamaTrackingEnabled else { return false }
        if case .running = model.ollamaState.server { return true }
        return model.ollamaTodayTokens > 0
    }

    private var ollamaRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Label("Local (Ollama)", systemImage: "desktopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            if let rate = model.ollamaTokensPerSecond {
                Text("\(rate, format: .number.precision(.fractionLength(0))) tok/s")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .help("Average generation speed over recent local requests (this session).")
            }
            Text(model.ollamaTodayTokens, format: .number.notation(.compactName))
                .font(.system(.callout, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
                .help("\(model.ollamaTodayTokens.formatted()) local-model tokens today (measured, no cost). Captured via the proxy — see Settings → Data Sources.")
        }
    }

    private func percent(_ value: Int, of reference: Int) -> String {
        let ratio = Double(value) / Double(reference)
        return ratio.formatted(.percent.precision(.fractionLength(0)))
    }

    // MARK: - Watcher status

    private var statusRow: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .help("Claude Code log watcher status. Configure in Settings.")
    }

    private var statusText: String {
        switch model.logAccessStatus {
        case .checking:
            "Checking log access…"
        case .accessible:
            "Watching \(model.logsRootDisplayPath)"
        case .notFound:
            "No Claude Code logs at \(model.logsRootDisplayPath)"
        case .denied:
            "Can't read logs — grant Full Disk Access (Settings → Permissions)"
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

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Button {
                open(.overview)
            } label: {
                Label("Open Token Meter", systemImage: "macwindow")
            }

            Spacer()

            Button {
                open(.settings)
            } label: {
                Label("Settings", systemImage: "gear")
            }

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .controlSize(.small)
    }

    /// Opens the centralized main window on `section`.
    private func open(_ section: MainSection) {
        model.mainSelection = section
        openWindow(id: WindowID.main)
        activateApp()
        dismiss()
    }

    /// LSUIElement apps are "accessory" processes — without an explicit
    /// activation, windows we open would appear behind the frontmost app.
    private func activateApp() {
        NSApp.activate()
    }
}

/// Small capsule marking log-derived numbers as estimates (honesty guardrail).
struct EstimatedBadge: View {
    var body: some View {
        Text("estimated")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: Capsule())
            .help("Log-derived numbers are estimates, not your real subscription quota.")
    }
}

#Preview {
    MenuBarDashboardView()
        .environment(AppModel())
}
