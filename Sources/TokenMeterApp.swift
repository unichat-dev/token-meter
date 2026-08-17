// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import SwiftUI

extension Notification.Name {
    /// Posted (locally + across processes) when the app should surface its main
    /// window: on Dock/Finder reopen, or by a duplicate launch handing off to
    /// the instance that's already running.
    static let reopenMainWindow = Notification.Name("com.unichatdigital.tokenmeter.reopen")
}

/// TokenMeter — lives in the menu bar (`LSUIElement = YES` keeps launch
/// quiet), and switches to a regular Dock app while its windows are open
/// (see `AppModel.applyActivationPolicy`; configurable in Settings → General).
///
/// Scenes:
/// - `MenuBarExtra` (`.window` style): the popover dashboard.
/// - `Window` "details": usage history and charts.
/// - `Settings`: general, data sources, usage windows, pricing, permissions.
@main
struct TokenMeterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        // Under XCTest the app is only the test host: starting ingestion here
        // would open the user's real history store and scan their real logs
        // on every test run. Tests build their own models and stores.
        if !RuntimeEnvironment.isRunningTests {
            model.startIfNeeded() // begin log ingestion at launch, not first click
        }
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarDashboardView()
                .environment(model)
        } label: {
            // Rendered into the status item at launch — its `.task` is where we
            // open the main window automatically so the desktop app is ready
            // immediately (a `Window` scene doesn't auto-open under LSUIElement).
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Token Meter", id: WindowID.main) {
            MainWindowView()
                .environment(model)
        }
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

/// The menu-bar status-item content (the gauge glyph). Also the launch hook:
/// it opens the main window once so TokenMeter comes up as a ready desktop app,
/// not just a menu-bar icon. The status item lives for the whole app lifetime,
/// so it's also where we listen for "reopen" and re-surface the main window.
private struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    @AppStorage(PreferenceKey.menuBarMetric)
    private var metricRaw = MenuBarMetric.todayTokens.rawValue

    @AppStorage(PreferenceKey.blockReferenceMode)
    private var blockReferenceModeRaw = BlockReferenceMode.off.rawValue

    @AppStorage(PreferenceKey.blockReferenceCustomTokens)
    private var blockReferenceCustomTokens = 0

    @AppStorage(PreferenceKey.openWindowAtLaunch)
    private var openWindowAtLaunch = false

    @AppStorage(PreferenceKey.hasCompletedFirstRun)
    private var hasCompletedFirstRun = false

    private var metric: MenuBarMetric {
        MenuBarMetric(rawValue: metricRaw) ?? .todayTokens
    }

    var body: some View {
        // The status item is width-constrained, so the readout is a short
        // string beside the glyph rather than a full label.
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.needle")
            if let text = readout {
                Text(text)
                    .monospacedDigit()
            }
        }
        .task {
            guard !RuntimeEnvironment.isRunningTests else { return }
            guard !model.didAutoOpenMainWindow else { return }
            model.didAutoOpenMainWindow = true

            // First run opens the window once so the app introduces itself and
            // the permissions flow is discoverable. After that it only opens if
            // the user asked for it — a login item that seizes the foreground
            // at every login is the fastest way to get uninstalled.
            if !hasCompletedFirstRun {
                hasCompletedFirstRun = true
                surfaceMainWindow()
            } else if openWindowAtLaunch {
                surfaceMainWindow()
            }
        }
        .onReceive(
            DistributedNotificationCenter.default().publisher(for: .reopenMainWindow)
        ) { _ in
            surfaceMainWindow()
        }
    }

    /// The live value shown in the menu bar, or `nil` for icon-only (and for
    /// metrics whose prerequisite isn't configured — a dash would be noise).
    private var readout: String? {
        switch metric {
        case .iconOnly:
            return nil

        case .todayTokens:
            let total = model.todaySummary.tokens.total
            guard total > 0 else { return nil }
            return total.formatted(.number.notation(.compactName))

        case .todayCost:
            guard let cost = model.todaySummary.estimatedCostUSD else { return nil }
            return cost.formatted(
                .currency(code: "USD").precision(.fractionLength(cost < 10 ? 2 : 0))
            )

        case .blockProgress:
            guard
                let block = model.currentBlock,
                let reference = BlockReference.tokens(
                    mode: BlockReferenceMode(rawValue: blockReferenceModeRaw) ?? .off,
                    custom: blockReferenceCustomTokens,
                    peak: model.peakBlockTokens
                )
            else { return nil }
            let fraction = BlockReference.fraction(
                tokens: block.tokens.total, reference: reference
            )
            return fraction.formatted(.percent.precision(.fractionLength(0)))

        case .planMultiple:
            guard let multiple = model.planValue.valueMultiple else { return nil }
            return PlanValueFormat.multiple(multiple)
        }
    }

    /// Bring the desktop window forward (opening it if it was closed) and focus
    /// the app — reused by the launch auto-open and every reopen.
    private func surfaceMainWindow() {
        model.mainSelection = .overview
        openWindow(id: WindowID.main)
        NSApp.activate()
    }
}

/// Enforces single-instance behaviour and reopen handling — the parts of a
/// "regular app" that SwiftUI's `App` doesn't cover on its own.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// If another copy of TokenMeter is already running, hand off to it and
    /// quit — so launching the app twice never yields two menu-bar icons.
    /// (`LSMultipleInstancesProhibited` blocks the common Finder/Dock relaunch;
    /// this covers launches from a different path or `open -n`.)
    func applicationWillFinishLaunching(_ notification: Notification) {
        // Never hand off + terminate while hosting tests: the "already running"
        // instance would be the user's installed app, and terminating would
        // kill the test run itself.
        guard !RuntimeEnvironment.isRunningTests else { return }
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let current = NSRunningApplication.current
        let alreadyRunning = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .contains { $0.processIdentifier != current.processIdentifier && !$0.isTerminated }
        guard alreadyRunning else { return }
        // Ask the existing instance to surface its window, then bow out.
        DistributedNotificationCenter.default().postNotificationName(
            .reopenMainWindow, object: nil, userInfo: nil, deliverImmediately: true)
        NSApp.terminate(nil)
    }

    /// Clicking the Dock icon or reopening from Finder while we're already
    /// running: show the existing window instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        NSApp.activate()
        if !hasVisibleWindows {
            DistributedNotificationCenter.default().postNotificationName(
                .reopenMainWindow, object: nil, userInfo: nil, deliverImmediately: true)
        }
        return true
    }
}
