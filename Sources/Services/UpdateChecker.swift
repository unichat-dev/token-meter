// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// Result of asking GitHub whether there's a newer release.
enum UpdateStatus: Sendable, Equatable {
    case unknown
    case checking
    case upToDate(current: String)
    case updateAvailable(current: String, latest: String, url: URL)
    case failed
}

/// Compares the running version against the newest GitHub release.
///
/// Deliberately not Sparkle: the project ships with zero third-party
/// dependencies, and a self-updating framework is a large amount of privileged
/// machinery for an app that installs by dragging a DMG. This just *tells* the
/// user a release exists and links to it — the download stays a deliberate act.
///
/// Only the release tag and URL are read. Nothing about usage is transmitted,
/// and the request carries no identifying information.
struct UpdateChecker: Sendable {
    static let releasesAPI = URL(
        string: "https://api.github.com/repos/unichat-dev/token-meter/releases/latest"
    )!
    static let releasesPage = URL(
        string: "https://github.com/unichat-dev/token-meter/releases/latest"
    )!

    private struct Release: Decodable {
        var tagName: String
        var htmlURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }
    }

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    func check() async -> UpdateStatus {
        let current = currentVersion
        var request = URLRequest(url: Self.releasesAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                // 404 simply means no release has been published yet.
                Logger.app.info("update check HTTP \(http.statusCode)")
                return http.statusCode == 404 ? .upToDate(current: current) : .failed
            }
            let release = try JSONDecoder().decode(Release.self, from: data)
            let latest = Self.normalize(release.tagName)
            guard Self.isNewer(latest, than: current) else {
                return .upToDate(current: current)
            }
            let url = URL(string: release.htmlURL) ?? Self.releasesPage
            return .updateAvailable(current: current, latest: latest, url: url)
        } catch {
            Logger.app.info("update check failed: \(error, privacy: .public)")
            return .failed
        }
    }

    /// Strips a leading `v` so `v2.0.0` and `2.0.0` compare equal.
    static func normalize(_ tag: String) -> String {
        var tag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if tag.hasPrefix("v") || tag.hasPrefix("V") { tag.removeFirst() }
        return tag
    }

    /// Numeric component-wise comparison, so `1.10.0` correctly beats `1.9.0`
    /// where a string compare would not. Missing components count as zero, and
    /// any non-numeric component makes the comparison bail out rather than
    /// guess — better to miss an update than to nag about a phantom one.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = candidate.split(separator: ".").map { Int($0) }
        let right = current.split(separator: ".").map { Int($0) }
        guard !left.contains(where: { $0 == nil }), !right.contains(where: { $0 == nil }) else {
            return false
        }
        for index in 0..<max(left.count, right.count) {
            let lhs = index < left.count ? (left[index] ?? 0) : 0
            let rhs = index < right.count ? (right[index] ?? 0) : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }
}
