// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Shared locations for the persistence layer.
///
/// Rule: this layer never stores secrets — API keys live exclusively in
/// ``KeychainStore``.
enum Persistence {
    /// Directory holding the SwiftData store and the pricing cache/overrides.
    static func storeDirectoryURL() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "TokenMeter", directoryHint: .isDirectory)
    }
}
