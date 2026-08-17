// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import UserNotifications
import os

/// Whether the user has let us post notifications.
enum NotificationPermission: Sendable, Equatable {
    case unknown
    case notRequested
    case granted
    case denied

    var canPost: Bool { self == .granted }
}

/// Delivers budget alerts. A protocol so `AppModel` can be exercised without
/// the real notification framework — which needs a signed bundle and a live
/// user session, neither of which a unit test has.
protocol BudgetNotifying: Sendable {
    func currentPermission() async -> NotificationPermission
    /// Returns the permission after the request resolves.
    @discardableResult
    func requestPermission() async -> NotificationPermission
    func post(_ alert: BudgetAlert) async
}

/// `UNUserNotificationCenter`-backed implementation.
struct UserNotificationService: BudgetNotifying {
    func currentPermission() async -> NotificationPermission {
        guard let center = Self.center else { return .unknown }
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return .notRequested
        case .denied: return .denied
        case .authorized, .provisional, .ephemeral: return .granted
        @unknown default: return .unknown
        }
    }

    @discardableResult
    func requestPermission() async -> NotificationPermission {
        guard let center = Self.center else { return .unknown }
        do {
            // No badge: a persistent count on a menu-bar utility's Dock icon is
            // noise the user can't clear from the app.
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            return granted ? .granted : .denied
        } catch {
            Logger.app.error("notification authorization failed: \(error, privacy: .public)")
            return .denied
        }
    }

    func post(_ alert: BudgetAlert) async {
        guard let center = Self.center else { return }
        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        content.sound = .default

        // Identifier is scope + threshold so a repeat of the same crossing
        // replaces the old banner instead of stacking. The ledger should stop
        // repeats anyway; this is belt and braces.
        let request = UNNotificationRequest(
            identifier: "budget.\(alert.scope.rawValue).\(alert.threshold)",
            content: content,
            trigger: nil // deliver immediately
        )
        do {
            try await center.add(request)
        } catch {
            Logger.app.error("posting budget notification failed: \(error, privacy: .public)")
        }
    }

    /// `UNUserNotificationCenter.current()` traps when the process has no
    /// proper application bundle — which is exactly the case for some test and
    /// command-line hosts. Resolving it lazily keeps those environments safe.
    private static var center: UNUserNotificationCenter? {
        guard !RuntimeEnvironment.isRunningTests else { return nil }
        guard Bundle.main.bundleIdentifier != nil else { return nil }
        return UNUserNotificationCenter.current()
    }
}
