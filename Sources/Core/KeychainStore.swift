// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Security

/// Errors surfaced by ``KeychainStore``.
///
/// Deliberately carries only OSStatus codes — never item data — so errors are
/// always safe to log.
enum KeychainError: Error, Equatable {
    /// No item exists for the requested account.
    case itemNotFound
    /// The stored payload could not be decoded as UTF-8.
    case invalidData
    /// Any other Security framework failure, with the raw status code.
    case unexpectedStatus(OSStatus)
}

/// Minimal, dependency-free wrapper around the macOS keychain for API keys.
///
/// This is the **only** sanctioned storage for secrets in TokenMeter — API
/// keys must never touch UserDefaults, SwiftData, plists, files, or logs
/// (see SECURITY.md).
///
/// Security posture:
/// - Secrets are stored as generic-password items in the user's login
///   keychain (encrypted at rest, unlocked with the user session).
/// - `kSecAttrSynchronizable` is pinned to `false` on every query: keys never
///   sync to iCloud Keychain.
/// - Reads/writes are scoped to our service string, so we never touch other
///   apps' items (and never trigger "wants to access your keychain" prompts
///   for foreign items).
/// - Values are never logged; ``KeychainError`` carries status codes only.
struct KeychainStore: Sendable {
    /// Groups this app's items in the keychain; also the default namespace
    /// used by connectors (e.g. account "anthropic-admin", "openai").
    let service: String

    static let defaultService = "com.unichatdigital.tokenmeter"

    init(service: String = KeychainStore.defaultService) {
        self.service = service
    }

    // MARK: - API

    /// Stores or replaces the secret for `account` (upsert).
    func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)

        var addQuery = baseQuery(for: account)
        addQuery[kSecValueData as String] = data

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        switch addStatus {
        case errSecSuccess:
            return
        case errSecDuplicateItem:
            let update = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(
                baseQuery(for: account) as CFDictionary,
                update as CFDictionary
            )
            guard updateStatus == errSecSuccess else {
                throw KeychainError.unexpectedStatus(updateStatus)
            }
        default:
            throw KeychainError.unexpectedStatus(addStatus)
        }
    }

    /// Returns the secret for `account`, or throws ``KeychainError/itemNotFound``.
    func secret(for account: String) throws -> String {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let value = String(data: data, encoding: .utf8)
            else { throw KeychainError.invalidData }
            return value
        case errSecItemNotFound:
            throw KeychainError.itemNotFound
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Returns the secret for `account`, or `nil` if none is stored.
    func secretIfPresent(for account: String) throws -> String? {
        do {
            return try secret(for: account)
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    /// Removes the secret for `account`. Idempotent: succeeds if absent.
    func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// All account names that currently have a secret under this service.
    func allAccounts() throws -> [String] {
        var query = serviceQuery()
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            let items = result as? [[String: Any]] ?? []
            return items.compactMap { $0[kSecAttrAccount as String] as? String }
        case errSecItemNotFound:
            return []
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Removes every item under this service. Used by tests and "reset all".
    func removeAllSecrets() throws {
        let status = SecItemDelete(serviceQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    // MARK: - Queries

    private func serviceQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            // Pinned on every query so items are neither written to nor
            // matched from iCloud Keychain.
            kSecAttrSynchronizable as String: false,
        ]
    }

    private func baseQuery(for account: String) -> [String: Any] {
        var query = serviceQuery()
        query[kSecAttrAccount as String] = account
        return query
    }
}
