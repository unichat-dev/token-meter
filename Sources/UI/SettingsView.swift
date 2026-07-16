// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// UserDefaults keys for non-secret preferences. Secrets never go here —
/// API keys live in `KeychainStore` only (SECURITY.md).
enum PreferenceKey {
    /// Custom Claude Code logs root; empty string means "use the default".
    static let claudeLogsPathOverride = "claudeLogsPathOverride"
    /// Raw `BlockReferenceMode` for 5-hour-block progress display.
    static let blockReferenceMode = "blockReferenceMode"
    /// Token count for `BlockReferenceMode.custom`.
    static let blockReferenceCustomTokens = "blockReferenceCustomTokens"
    /// URL of the pricing feed (our repo's `pricing-feed/pricing.json`).
    /// Empty disables remote refresh — bundled prices + overrides apply.
    static let pricingFeedURL = "pricingFeedURL"
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

/// Settings window: data sources, usage windows, pricing, permissions.
struct SettingsView: View {
    var body: some View {
        TabView {
            DataSourcesSettingsTab()
                .tabItem { Label("Data Sources", systemImage: "folder") }
            UsageWindowsSettingsTab()
                .tabItem { Label("Usage Windows", systemImage: "hourglass") }
            PricingSettingsTab()
                .tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
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
                Text("Anthropic publishes no official token numbers for the Pro/Max 5-hour window, and TokenMeter can't read your real quota. These references are optional context only — your own history or your own number — and the displayed block is reconstructed from local logs (estimated).")
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
    @AppStorage(PreferenceKey.claudeLogsPathOverride)
    private var claudeLogsPathOverride = ""

    /// Default location of Claude Code's JSONL logs.
    private static let defaultClaudeLogsPath = "~/.claude/projects"

    var body: some View {
        Form {
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
                Text("Leave empty to use the default (\(Self.defaultClaudeLogsPath)). Changes take effect after relaunching TokenMeter.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.bottom, 8)
    }
}

// MARK: - Pricing

struct PricingSettingsTab: View {
    @Environment(AppModel.self) private var model

    @AppStorage(PreferenceKey.pricingFeedURL)
    private var feedURLString = ""

    @State private var isRefreshing = false

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
            LabeledContent("Prices") {
                Text(feedStatusText)
            }
            TextField(
                "Feed URL",
                text: $feedURLString,
                prompt: Text(AppModel.defaultPricingFeedURL.absoluteString)
            )
            .autocorrectionDisabled()
            Button(isRefreshing ? "Refreshing…" : "Refresh Now") {
                isRefreshing = true
                Task {
                    await model.refreshPricingNow()
                    isRefreshing = false
                }
            }
            .disabled(isRefreshing)
        } header: {
            Text("Pricing feed")
        } footer: {
            Text("The feed is TokenMeter's own daily-updated pricing file (pricing-feed/ in the repo), normalized from community-maintained data. Leave the URL empty to use the official feed; set one to override. Checked about once a day while the app runs. Your edits below always win over feed prices.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                Text("If macOS blocks access to the log folder, grant TokenMeter Full Disk Access, then quit and reopen the app.")
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
            "\(model.logsRootDisplayPath) doesn't exist. Install Claude Code or run a session to create it, or point TokenMeter elsewhere in Data Sources. TokenMeter picks it up automatically once it appears."
        case .denied:
            "\(model.logsRootDisplayPath) exists but can't be read. Grant Full Disk Access below, then relaunch TokenMeter."
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
