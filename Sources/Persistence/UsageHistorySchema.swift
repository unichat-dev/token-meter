// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftData

/// Persisted usage event (SwiftData).
///
/// `eventID` is unique — inserting an event with an existing id **upserts**
/// instead of duplicating, which is what makes ingestion idempotent across
/// re-scans and relaunches.
///
/// Never store secrets here (SECURITY.md): API keys live in `KeychainStore`.
@Model
final class StoredUsageEvent {
    @Attribute(.unique) var eventID: String
    var provider: String
    var accuracy: String
    var timestamp: Date
    var modelName: String
    var project: String?
    var inputTokens: Int
    var outputTokens: Int
    var cacheReadTokens: Int
    var cacheCreationTokens: Int

    init(
        eventID: String,
        provider: String,
        accuracy: String,
        timestamp: Date,
        modelName: String,
        project: String?,
        inputTokens: Int,
        outputTokens: Int,
        cacheReadTokens: Int,
        cacheCreationTokens: Int
    ) {
        self.eventID = eventID
        self.provider = provider
        self.accuracy = accuracy
        self.timestamp = timestamp
        self.modelName = modelName
        self.project = project
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreationTokens = cacheCreationTokens
    }

    convenience init(_ event: UsageEvent) {
        self.init(
            eventID: event.id,
            provider: event.provider.rawValue,
            accuracy: event.accuracy.rawValue,
            timestamp: event.timestamp,
            modelName: event.model,
            project: event.project,
            inputTokens: event.tokens.input,
            outputTokens: event.tokens.output,
            cacheReadTokens: event.tokens.cacheRead,
            cacheCreationTokens: event.tokens.cacheCreation
        )
    }

    /// Back to the domain type. `nil` if raw values are from a future schema
    /// this build doesn't know (forward-compat: skip, don't crash).
    var usageEvent: UsageEvent? {
        guard
            let provider = UsageProvider(rawValue: provider),
            let accuracy = UsageAccuracy(rawValue: accuracy)
        else { return nil }
        return UsageEvent(
            id: eventID,
            provider: provider,
            accuracy: accuracy,
            timestamp: timestamp,
            model: modelName,
            project: project,
            tokens: TokenCounts(
                input: inputTokens,
                output: outputTokens,
                cacheRead: cacheReadTokens,
                cacheCreation: cacheCreationTokens
            )
        )
    }
}

// MARK: - Versioned schema + migration plan
//
// Migrations strategy: every schema change gets a new
// `VersionedSchema` enum and a `MigrationStage` in the plan below —
// lightweight where possible, custom otherwise. V1 is the baseline.

enum UsageHistorySchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoredUsageEvent.self] }
}

enum UsageHistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [UsageHistorySchemaV1.self] }
    static var stages: [MigrationStage] { [] }
}
