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

    // Added in schema V2. Defaulted so the migration from V1 stays
    // lightweight: existing rows get zeros, which bill exactly as they did
    // before (whole cache-write total at the flat rate, no search charge).
    var cacheCreation5mTokens: Int = 0
    var cacheCreation1hTokens: Int = 0
    var webSearchRequests: Int = 0
    var webFetchRequests: Int = 0

    // Added in schema V3 — session/branch/agent/skill attribution. Also
    // additive with defaults, so V1 and V2 stores migrate lightweight.
    var sessionID: String?
    var gitBranch: String?
    var agentName: String?
    var skillName: String?
    var isSidechain: Bool = false

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
        cacheCreationTokens: Int,
        cacheCreation5mTokens: Int = 0,
        cacheCreation1hTokens: Int = 0,
        webSearchRequests: Int = 0,
        webFetchRequests: Int = 0,
        sessionID: String? = nil,
        gitBranch: String? = nil,
        agentName: String? = nil,
        skillName: String? = nil,
        isSidechain: Bool = false
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
        self.cacheCreation5mTokens = cacheCreation5mTokens
        self.cacheCreation1hTokens = cacheCreation1hTokens
        self.webSearchRequests = webSearchRequests
        self.webFetchRequests = webFetchRequests
        self.sessionID = sessionID
        self.gitBranch = gitBranch
        self.agentName = agentName
        self.skillName = skillName
        self.isSidechain = isSidechain
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
            cacheCreationTokens: event.tokens.cacheCreation,
            cacheCreation5mTokens: event.tokens.cacheCreation5m,
            cacheCreation1hTokens: event.tokens.cacheCreation1h,
            webSearchRequests: event.serverToolUse.webSearchRequests,
            webFetchRequests: event.serverToolUse.webFetchRequests,
            sessionID: event.attribution.sessionID,
            gitBranch: event.attribution.gitBranch,
            agentName: event.attribution.agent,
            skillName: event.attribution.skill,
            isSidechain: event.attribution.isSidechain
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
                cacheCreation: cacheCreationTokens,
                cacheCreation5m: cacheCreation5mTokens,
                cacheCreation1h: cacheCreation1hTokens
            ),
            serverToolUse: ServerToolUse(
                webSearchRequests: webSearchRequests,
                webFetchRequests: webFetchRequests
            ),
            attribution: UsageAttribution(
                sessionID: sessionID,
                gitBranch: gitBranch,
                agent: agentName,
                skill: skillName,
                isSidechain: isSidechain
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

/// V2 adds the cache-write TTL split (`cacheCreation5m/1hTokens`) and
/// server-tool request counts. Every new attribute has a default, so V1 stores
/// migrate **lightweight** — rows written before this build keep zeros and
/// price exactly as they did, with the whole cache-write total billed at the
/// flat 5-minute rate.
enum UsageHistorySchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoredUsageEvent.self] }
}

/// V3 adds session / branch / agent / skill attribution. Additive with
/// defaults again, so V1 and V2 stores both migrate lightweight — existing rows
/// simply have no attribution and group under "Unattributed".
enum UsageHistorySchemaV3: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(3, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoredUsageEvent.self] }
}

/// The schema the app currently opens. Bump this alongside a new stage below.
typealias UsageHistorySchemaCurrent = UsageHistorySchemaV3

enum UsageHistoryMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] {
        [UsageHistorySchemaV1.self, UsageHistorySchemaV2.self, UsageHistorySchemaV3.self]
    }

    /// Deliberately empty.
    ///
    /// A declared `.lightweight` stage requires the two versions to expose
    /// *distinct* model snapshots; ours both point at the same
    /// `StoredUsageEvent` class, and handing SwiftData that pair crashes inside
    /// `NSLightweightMigrationStage`. Because every V2 attribute is additive
    /// with a default, Core Data's automatic lightweight migration already
    /// handles the V1 → V2 store upgrade on open.
    ///
    /// A future change that renames, retypes, or removes a property will need a
    /// real stage — and that means nesting a per-version copy of the model
    /// inside each `VersionedSchema`.
    static var stages: [MigrationStage] { [] }
}
