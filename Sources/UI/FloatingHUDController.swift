// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Owns the "pin to screen" floating widget — an always-on-top HUD panel that
/// mirrors today's estimated usage without opening a window or stealing focus.
///
/// It's a non-activating `NSPanel` at the floating window level, so it hovers
/// above other apps' windows, joins every Space, and never appears in the Dock
/// or ⌘-Tab. The app stays a menu-bar accessory; this is the ambient readout
/// for people who want the number on screen all the time. Live numbers come
/// from the same `AppModel` the popover uses.
@MainActor
final class FloatingHUDController {
    private unowned let model: AppModel
    private var panel: NSPanel?

    init(model: AppModel) {
        self.model = model
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        // `orderFrontRegardless` (not `makeKeyAndOrderFront`): show without
        // activating the app or taking key focus from whatever's in front.
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 220, height: 148),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // Clear window: the SwiftUI card draws its own rounded material, so the
        // panel itself is just a transparent, shadowed host.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [
            .canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle,
        ]

        // `contentViewController` lets AppKit size the panel to the SwiftUI
        // card's fitting size, so rows appearing/disappearing (e.g. the local
        // Ollama row) never clip.
        panel.contentViewController = NSHostingController(
            rootView: FloatingHUDView().environment(model)
        )

        // Restore the last drag position; otherwise park it top-right.
        panel.setFrameAutosaveName("TokenMeterFloatingHUD")
        if panel.frame.origin == .zero, let screen = NSScreen.main {
            let visible = screen.visibleFrame
            let size = panel.frame.size
            panel.setFrameOrigin(NSPoint(
                x: visible.maxX - size.width - 24,
                y: visible.maxY - size.height - 24
            ))
        }
        return panel
    }
}

// MARK: - View

/// Compact card shown inside the floating panel. Honesty guardrail applies:
/// every number here is log-derived and labeled estimated.
private struct FloatingHUDView: View {
    @Environment(AppModel.self) private var model

    private var summary: UsageSummary { model.todaySummary }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(summary.tokens.total, format: .number.notation(.compactName))
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .contentTransition(.numericText())
                Text("tokens")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text(costText)
                    .font(.system(.body, design: .rounded, weight: .medium))
                    .foregroundStyle(summary.estimatedCostUSD == nil ? .secondary : .primary)
                    .contentTransition(.numericText())
            }
            .help("\(summary.tokens.total.formatted()) tokens today (estimated)")

            Divider()
            contextRows
            footer
        }
        .padding(12)
        .frame(width: 220)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08))
        )
        .onAppear { model.refreshNow() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "gauge.with.needle")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Today")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            EstimatedBadge()
            Button {
                model.setFloatingHUDVisible(false)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Hide the floating widget (Settings → General to bring it back).")
        }
    }

    private var costText: String {
        summary.estimatedCostUSD.map { "≈" + $0.formatted(.currency(code: "USD")) } ?? "—"
    }

    @ViewBuilder
    private var contextRows: some View {
        if let block = model.currentBlock {
            row(
                label: "5-hr block",
                systemImage: "hourglass",
                value: block.tokens.total,
                trailing: Text(block.end, style: .relative) + Text(" left")
            )
        }
        row(
            label: "This week",
            systemImage: "calendar",
            value: model.weekSummary.tokens.total,
            trailing: nil
        )
        if showsOllamaRow {
            row(
                label: "Local",
                systemImage: "desktopcomputer",
                value: model.ollamaTodayTokens,
                trailing: nil
            )
        }
    }

    private var showsOllamaRow: Bool {
        guard model.isOllamaTrackingEnabled else { return false }
        if case .running = model.ollamaState.server { return true }
        return model.ollamaTodayTokens > 0
    }

    private func row(label: String, systemImage: String, value: Int, trailing: Text?) -> some View {
        HStack(spacing: 5) {
            Label(label, systemImage: systemImage)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 4)
            if let trailing {
                trailing
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Text(value, format: .number.notation(.compactName))
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .contentTransition(.numericText())
        }
    }

    private var footer: some View {
        Text("estimated — not your real quota · drag to move")
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}
