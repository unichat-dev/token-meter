// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Resolves where the Codex CLI (OpenAI's CLI) keeps its JSONL session logs
/// and enumerates them.
///
/// Default root is `~/.codex/sessions` (Codex writes per-session rollout files
/// like `sessions/2026/07/17/rollout-…​.jsonl`). A user override
/// (Settings → Data Sources) takes precedence. Tilde is expanded.
///
/// `jsonlFiles(under:)` and access classification come from ``JSONLLogLocating``
/// and ``LogAccessStatus`` — shared with the Claude Code locator.
struct CodexLogLocator: JSONLLogLocating, Sendable {
    /// Raw override string from preferences; `nil`/empty means default.
    let pathOverride: String?

    init(pathOverride: String? = nil) {
        self.pathOverride = pathOverride
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".codex/sessions", directoryHint: .isDirectory)
    }

    var rootURL: URL {
        guard let pathOverride, !pathOverride.isEmpty else {
            return Self.defaultRoot
        }
        let expanded = NSString(string: pathOverride).expandingTildeInPath
        return URL(filePath: expanded, directoryHint: .isDirectory)
    }
}
