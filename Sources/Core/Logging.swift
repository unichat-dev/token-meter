// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import os

/// Central logger categories.
///
/// Logging rules (SECURITY.md):
/// - Never log secrets or raw log-line contents — log lines embed user
///   prompts. Log counts, status codes, and paths only.
/// - Paths are `.private` by default; os_log redacts them off-device.
extension Logger {
    private static let subsystem = "com.unichatdigital.tokenmeter"

    static let dataSources = Logger(subsystem: subsystem, category: "datasources")
    static let app = Logger(subsystem: subsystem, category: "app")
}
