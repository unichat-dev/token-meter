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

/// The tabbed settings content, reused by both the ⌘, Settings scene and the
/// main window's Settings pane — so preferences live in one place.
struct SettingsTabs: View {
    var body: some View {
        TabView {
            GeneralSettingsTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            DataSourcesSettingsTab()
                .tabItem { Label("Data Sources", systemImage: "folder") }
            UsageWindowsSettingsTab()
                .tabItem { Label("Usage Windows", systemImage: "hourglass") }
            PricingSettingsTab()
                .tabItem { Label("Pricing", systemImage: "dollarsign.circle") }
            PermissionsSettingsTab()
                .tabItem { Label("Permissions", systemImage: "lock.shield") }
        }
    }
}

/// The ⌘, Settings scene wrapper — fixed width + Dock-policy window tracking.
struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsTabs()
            .frame(width: 500)
            .fixedSize(horizontal: false, vertical: true)
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

    var body: some View {
        Form {
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
