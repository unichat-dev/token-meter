// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftData
import os

/// Durable usage history, off the main thread (`@ModelActor` gives this actor
/// its own `ModelContext` on a background executor).
///
/// Idempotency: `ingest` inserts by unique `eventID`, so replaying the same
/// log backfill after a relaunch updates rather than duplicates.
@ModelActor
actor UsageHistoryStore {
    /// On-disk container in Application Support (created if needed).
    static func makeContainer() throws -> ModelContainer {
        let directory = try Persistence.storeDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "UsageHistory.store")
        return try ModelContainer(
            for: Schema(versionedSchema: UsageHistorySchemaV1.self),
            migrationPlan: UsageHistoryMigrationPlan.self,
            configurations: ModelConfiguration(url: url)
        )
    }

    /// Ephemeral container for unit tests.
    static func makeInMemoryContainer() throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: UsageHistorySchemaV1.self),
            migrationPlan: UsageHistoryMigrationPlan.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
    }

    /// Upserts a batch and saves once. Safe to call with events the store
    /// has already seen.
    func ingest(_ events: [UsageEvent]) throws {
        guard !events.isEmpty else { return }
        for event in events {
            modelContext.insert(StoredUsageEvent(event))
        }
        try modelContext.save()
    }

    /// Every stored event, oldest first. Rows with unknown provider/accuracy
    /// raw values (written by a newer build) are skipped, not fatal.
    func loadAll() throws -> [UsageEvent] {
        let descriptor = FetchDescriptor<StoredUsageEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )
        return try modelContext.fetch(descriptor).compactMap(\.usageEvent)
    }

    func storedEventCount() throws -> Int {
        try modelContext.fetchCount(FetchDescriptor<StoredUsageEvent>())
    }
}
