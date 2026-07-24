// Copyright 2026 UniChat Dev - Ilhan Akbudak
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// What we know about the local Ollama installation right now.
struct OllamaState: Equatable, Sendable {
    enum Server: Equatable, Sendable {
        case unknown
        /// No server responding and no Ollama installation found on disk.
        case notInstalled
        /// Installed (binary or app found) but the server isn't responding.
        case notRunning
        case running(version: String, installedModels: Int, loadedModels: Int)
    }

    var server: Server = .unknown
    /// Port the capture proxy is listening on; `nil` when capture is off.
    var capturePort: UInt16?
    /// Human-readable capture failure (e.g. port already in use).
    var captureError: String?
}

/// Read-only client for Ollama's local REST API. Used for status display and
/// graceful "not installed / not running" handling — usage capture itself
/// happens in ``OllamaProxySource``.
struct OllamaStatusClient: Sendable {
    let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// Filesystem locations that indicate Ollama is installed even when the
    /// server is down.
    private static let installMarkers = [
        "/Applications/Ollama.app",
        "/usr/local/bin/ollama",
        "/opt/homebrew/bin/ollama",
    ]

    func check() async -> OllamaState.Server {
        guard let version = await fetchVersion() else {
            let installed = Self.installMarkers.contains {
                FileManager.default.fileExists(atPath: $0)
            } || FileManager.default.fileExists(
                atPath: NSString(string: "~/.ollama").expandingTildeInPath
            )
            return installed ? .notRunning : .notInstalled
        }
        async let installed = modelCount(path: "/api/tags")
        async let loaded = modelCount(path: "/api/ps")
        return .running(
            version: version,
            installedModels: await installed,
            loadedModels: await loaded
        )
    }

    private func fetchVersion() async -> String? {
        struct VersionResponse: Decodable { let version: String }
        guard let data = await get(path: "/api/version") else { return nil }
        return (try? JSONDecoder().decode(VersionResponse.self, from: data))?.version
    }

    private func modelCount(path: String) async -> Int {
        struct ModelsResponse: Decodable {
            struct Model: Decodable { let name: String? }
            let models: [Model]?
        }
        guard let data = await get(path: path) else { return 0 }
        return (try? JSONDecoder().decode(ModelsResponse.self, from: data))?.models?.count ?? 0
    }

    private func get(path: String) async -> Data? {
        let url = baseURL.appending(path: path)
        var request = URLRequest(url: url, timeoutInterval: 2)
        request.httpMethod = "GET"
        guard
            let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return data
    }
}
