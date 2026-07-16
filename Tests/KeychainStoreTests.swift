// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

/// Exercises the real keychain, isolated under a unique per-run service name
/// so tests never touch (or leave behind) the app's actual items.
@Suite("KeychainStore", .serialized)
struct KeychainStoreTests {
    private let store = KeychainStore(
        service: "com.unichatdigital.tokenmeter.tests.\(UUID().uuidString)"
    )

    private func withCleanStore(_ body: (KeychainStore) throws -> Void) throws {
        defer { try? store.removeAllSecrets() }
        try body(store)
    }

    @Test("round-trips a secret")
    func roundTrip() throws {
        try withCleanStore { store in
            try store.setSecret("test-secret-value", for: "anthropic")
            let value = try store.secret(for: "anthropic")
            #expect(value == "test-secret-value")
        }
    }

    @Test("upsert replaces an existing secret")
    func upsert() throws {
        try withCleanStore { store in
            try store.setSecret("first", for: "openai")
            try store.setSecret("second", for: "openai")
            let value = try store.secret(for: "openai")
            #expect(value == "second")
        }
    }

    @Test("missing account throws itemNotFound")
    func missing() throws {
        try withCleanStore { store in
            #expect(throws: KeychainError.itemNotFound) {
                try store.secret(for: "nonexistent")
            }
            let value = try store.secretIfPresent(for: "nonexistent")
            #expect(value == nil)
        }
    }

    @Test("remove deletes and is idempotent")
    func remove() throws {
        try withCleanStore { store in
            try store.setSecret("value", for: "anthropic")
            try store.removeSecret(for: "anthropic")
            let value = try store.secretIfPresent(for: "anthropic")
            #expect(value == nil)
            // Second delete of the same account must not throw.
            try store.removeSecret(for: "anthropic")
        }
    }

    @Test("lists exactly the accounts stored under this service")
    func listAccounts() throws {
        try withCleanStore { store in
            let empty = try store.allAccounts()
            #expect(empty == [])
            try store.setSecret("a", for: "anthropic")
            try store.setSecret("b", for: "openai")
            let accounts = try store.allAccounts().sorted()
            #expect(accounts == ["anthropic", "openai"])
        }
    }

    @Test("secrets in different services are isolated")
    func serviceIsolation() throws {
        let other = KeychainStore(
            service: "com.unichatdigital.tokenmeter.tests.\(UUID().uuidString)"
        )
        defer {
            try? store.removeAllSecrets()
            try? other.removeAllSecrets()
        }
        try store.setSecret("mine", for: "shared-account")
        let leaked = try other.secretIfPresent(for: "shared-account")
        #expect(leaked == nil)
        let accounts = try other.allAccounts()
        #expect(accounts == [])
    }
}
