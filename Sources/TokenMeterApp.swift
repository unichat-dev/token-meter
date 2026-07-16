// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// TokenMeter — a menu-bar-only app (`LSUIElement = YES`, set in Info.plist).
///
/// Scenes:
/// - `MenuBarExtra` (`.window` style): the popover dashboard.
/// - `Window` "details": usage history and charts.
/// - `Settings`: data-source paths, pricing, permissions entry points.
@main
struct TokenMeterApp: App {
    @State private var model: AppModel

    init() {
        let model = AppModel()
        model.startIfNeeded() // begin log ingestion at launch, not first click
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra("TokenMeter", systemImage: "gauge.with.needle") {
            MenuBarDashboardView()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("TokenMeter", id: WindowID.details) {
            DetailsWindowView()
                .environment(model)
        }
        .defaultSize(width: 720, height: 480)

        Settings {
            SettingsView()
                .environment(model)
        }
    }
}
