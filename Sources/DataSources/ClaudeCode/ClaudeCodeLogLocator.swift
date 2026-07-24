// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Readability of the logs root — drives the permission-guidance UI.
enum LogAccessStatus: Equatable, Sendable {
    case checking
    /// Root exists and is enumerable.
    case accessible
    /// Root doesn't exist (Claude Code not installed / no sessions yet).
    case notFound
    /// Root exists but reading fails (permissions) — guide the user to
    /// System Settings → Privacy & Security → Full Disk Access.
    case denied
}

/// Resolves where Claude Code's JSONL logs live and enumerates them.
///
/// Default root is `~/.claude/projects`; a user override
/// (Settings → Data Sources) takes precedence. Tilde is expanded.
struct ClaudeCodeLogLocator: JSONLLogLocating, Sendable {
    /// Raw override string from preferences; `nil`/empty means default.
    let pathOverride: String?

    init(pathOverride: String? = nil) {
        self.pathOverride = pathOverride
    }

    static var defaultRoot: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude/projects", directoryHint: .isDirectory)
    }

    var rootURL: URL {
        guard let pathOverride, !pathOverride.isEmpty else {
            return Self.defaultRoot
        }
        let expanded = NSString(string: pathOverride).expandingTildeInPath
        return URL(filePath: expanded, directoryHint: .isDirectory)
    }

    /// All `*.jsonl` files under `root`, sorted for deterministic ingestion.
    func jsonlFiles(under root: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { return [] }

        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let isRegular = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
            if isRegular == true {
                files.append(url)
            }
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Classifies why the root can or can't be read. Non-throwing on purpose:
    /// this runs from UI refresh paths.
    static func checkAccess(at root: URL) -> LogAccessStatus {
        do {
            _ = try FileManager.default.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: nil
            )
            return .accessible
        } catch let error as NSError {
            switch error.code {
            case NSFileReadNoSuchFileError, NSFileNoSuchFileError:
                return .notFound
            case NSFileReadNoPermissionError:
                return .denied
            default:
                // Unknown failure: treat as denied so the UI offers the
                // permission guidance rather than silently showing zeros.
                return .denied
            }
        }
    }
}
