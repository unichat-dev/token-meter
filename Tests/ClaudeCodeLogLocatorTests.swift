// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
@testable import TokenMeter

@Suite("ClaudeCodeLogLocator")
struct ClaudeCodeLogLocatorTests {
    @Test("default root is ~/.claude/projects")
    func defaultRoot() {
        let locator = ClaudeCodeLogLocator()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(locator.rootURL.path == home + "/.claude/projects")
    }

    @Test("override expands tilde; empty override falls back to default")
    func overrideResolution() {
        let custom = ClaudeCodeLogLocator(pathOverride: "~/custom/logs")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(custom.rootURL.path == home + "/custom/logs")

        let empty = ClaudeCodeLogLocator(pathOverride: "")
        #expect(empty.rootURL == ClaudeCodeLogLocator.defaultRoot)
    }

    @Test("finds jsonl files recursively, sorted, ignoring other extensions")
    func enumeration() async throws {
        try await withTempDirectory { dir in
            let nested = dir.appending(path: "project-b/sub")
            try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
            try Data("x\n".utf8).write(to: dir.appending(path: "project-a.jsonl"))
            try Data("x\n".utf8).write(to: nested.appending(path: "deep.jsonl"))
            try Data("x\n".utf8).write(to: dir.appending(path: "notes.txt"))

            let files = ClaudeCodeLogLocator().jsonlFiles(under: dir)
            // Sorted by full path: "…/project-a.jsonl" < "…/project-b/sub/deep.jsonl".
            #expect(files.map(\.lastPathComponent) == ["project-a.jsonl", "deep.jsonl"])
        }
    }

    @Test("access status: missing directory is notFound")
    func accessNotFound() {
        let missing = URL(filePath: "/nonexistent/tokenmeter-\(UUID().uuidString)")
        #expect(ClaudeCodeLogLocator.checkAccess(at: missing) == .notFound)
    }

    @Test("access status: readable directory is accessible")
    func accessReadable() async throws {
        try await withTempDirectory { dir in
            #expect(ClaudeCodeLogLocator.checkAccess(at: dir) == .accessible)
        }
    }

    @Test("access status: permission-blocked directory is denied")
    func accessDenied() async throws {
        // Root can read anything; the chmod trick only works as a normal user.
        try #require(geteuid() != 0)
        try await withTempDirectory { dir in
            let blocked = dir.appending(path: "blocked")
            try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: blocked.path)
            defer {
                try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: blocked.path)
            }
            #expect(ClaudeCodeLogLocator.checkAccess(at: blocked) == .denied)
        }
    }
}
