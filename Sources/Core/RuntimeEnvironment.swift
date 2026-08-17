// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Facts about how this process was launched.
enum RuntimeEnvironment {
    /// True when the process is hosting an XCTest bundle.
    ///
    /// The unit tests are **app-hosted** (`TEST_HOST` points at TokenMeter.app),
    /// so a test run boots the real app inside the test process. Without a
    /// guard that means each run opens the user's live history database, walks
    /// their real `~/.claude` tree, and fires the pricing fetch — and if the
    /// installed app is already running, the single-instance check terminates
    /// the test host mid-run.
    ///
    /// Detected from the environment variable XCTest sets before any of our
    /// code runs, so it's reliable inside `App.init`.
    static let isRunningTests: Bool = {
        let environment = ProcessInfo.processInfo.environment
        return environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
    }()
}
