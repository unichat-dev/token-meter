// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import ServiceManagement
import os

/// Registers Token Meter as a login item.
///
/// A menu-bar meter that has to be launched by hand is a meter you forget to
/// look at — and worse, one that misses usage, because nothing is recorded
/// while the app isn't running.
///
/// `SMAppService` puts the toggle under the user's control in System Settings →
/// General → Login Items, so they can always override us there. That means the
/// real state can drift from our switch, and the UI has to read it back rather
/// than assume.
enum LaunchAtLogin {
    /// Whether macOS currently launches the app at login.
    static var isEnabled: Bool {
        guard !RuntimeEnvironment.isRunningTests else { return false }
        return SMAppService.mainApp.status == .enabled
    }

    /// True when the user has switched the login item off in System Settings —
    /// we can't re-enable it from here, so the UI has to say so.
    static var isBlockedBySystemSettings: Bool {
        guard !RuntimeEnvironment.isRunningTests else { return false }
        return SMAppService.mainApp.status == .requiresApproval
    }

    /// - Returns: the resulting state, which may differ from `enabled` when the
    ///   system refuses (for example while awaiting approval).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        guard !RuntimeEnvironment.isRunningTests else { return false }
        do {
            if enabled {
                // Registering while already registered throws, and that's not
                // an error worth surfacing.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Logger.app.error("login item update failed: \(error, privacy: .public)")
        }
        return isEnabled
    }

    /// Opens the system pane where the user can approve or remove the item.
    static func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
