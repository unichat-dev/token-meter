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
        model.startIfNeeded() // begin log ingestion at launch, not first click
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

    var body: some View {
        Image(systemName: "gauge.with.needle")
            .task {
                guard !model.didAutoOpenMainWindow else { return }
                model.didAutoOpenMainWindow = true
                surfaceMainWindow()
            }
            .onReceive(
                DistributedNotificationCenter.default().publisher(for: .reopenMainWindow)
            ) { _ in
                surfaceMainWindow()
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
