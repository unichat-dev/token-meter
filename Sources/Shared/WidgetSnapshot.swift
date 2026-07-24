// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The data bridge between the app and the widget.
///
/// The widget runs sandboxed and can't read `~/.claude` or the app's
/// Application Support — the main app writes this summary into the shared
/// App Group container and the widget only ever reads it. Compiled into
/// both targets; keep it Foundation-only.
struct WidgetSnapshot: Codable, Equatable, Sendable {
    static let appGroupID = "group.com.unichatdigital.tokenmeter"
    private static let fileName = "widget-snapshot.json"

    /// When the app last wrote the snapshot (shown as "as of HH:mm").
    var updatedAt: Date
    /// Metered (Claude Code) tokens today — estimated, like everywhere else.
    var todayTokens: Int
    var todayCostUSD: Decimal?
    /// Current 5-hour block, when one is active.
    var blockTokens: Int?
    var blockEndsAt: Date?
    var weekTokens: Int
    /// Local-model (Ollama) tokens today; 0 when tracking is off.
    var localTokens: Int

    /// Field-wise equality minus `updatedAt` — used to skip pointless writes.
    func hasSameContent(as other: WidgetSnapshot?) -> Bool {
        guard let other else { return false }
        return todayTokens == other.todayTokens
            && todayCostUSD == other.todayCostUSD
            && blockTokens == other.blockTokens
            && blockEndsAt == other.blockEndsAt
            && weekTokens == other.weekTokens
            && localTokens == other.localTokens
    }

    // MARK: - Shared container I/O
    //
    // The app writes the snapshot into the **App Group container** — the
    // sanctioned shared location that a properly signed (Developer ID) build's
    // widget reads via its group entitlement.
    //
    // We deliberately do NOT write into the widget's *private* sandbox
    // container (`~/Library/Containers/<widget-bundle>/…`): writing into
    // another app's private container triggers macOS's recurring "wants to
    // access data from other apps" permission prompt on every write. The Group
    // Containers directory is a shared location and does not.

    /// Where the app writes (unsandboxed — constructs the path directly).
    static func writeCandidateURLs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return [
            home.appending(path: "Library/Group Containers/\(appGroupID)/\(fileName)"),
        ]
    }

    /// Where the widget reads (sandboxed — only entitled paths resolve).
    static func readCandidateURLs() -> [URL] {
        var urls: [URL] = []
        if let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            urls.append(group.appending(path: fileName))
        }
        if let support = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            urls.append(support.appending(path: fileName))
        }
        return urls
    }

    static func load() -> WidgetSnapshot? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for url in readCandidateURLs() {
            if let data = try? Data(contentsOf: url),
               let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data) {
                return snapshot
            }
        }
        return nil
    }

    /// Best-effort: a failed write only means a stale widget, never an error
    /// the user has to deal with.
    func save() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(self) else { return }
        for url in Self.writeCandidateURLs() {
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? data.write(to: url, options: .atomic)
        }
    }

    /// Sample values for the widget gallery preview.
    static let placeholder = WidgetSnapshot(
        updatedAt: .now,
        todayTokens: 2_400_000,
        todayCostUSD: Decimal(string: "4.20"),
        blockTokens: 310_000,
        blockEndsAt: Date.now.addingTimeInterval(2 * 3600),
        weekTokens: 14_800_000,
        localTokens: 0
    )
}
