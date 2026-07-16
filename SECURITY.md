# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security vulnerabilities.

Instead, report privately via one of:

- **GitHub private vulnerability reporting** — use the *Security* tab → *Report a vulnerability* on this repository (preferred).
- **Email** — info@unichat.dev with subject line `[TokenMeter security]`.

Include what you found, steps to reproduce, and the impact you believe it has. You can expect an acknowledgment within a few days. Please give us a reasonable window to ship a fix before public disclosure.

## Scope & design guarantees

TokenMeter is a local-first tool. Reports are especially welcome for anything that violates these guarantees:

- **API keys live in the macOS Keychain only.** They must never appear in the local database, UserDefaults, plists, log output, diagnostics, or crash reports — and never in this repository.
- **Log data stays on-device.** Parsed Claude Code / Codex logs and usage history are stored locally and never transmitted.
- **Network access is opt-in and minimal.** The only remote calls are to the Anthropic/OpenAI usage APIs (with user-supplied keys, over HTTPS) and the local Ollama endpoint.
- **No secrets in the repo.** The repo carries only fabricated fixture data; a gitleaks pre-commit hook and CI scanning guard against accidental leaks. If you find a committed secret anyway, report it privately as above.

## Supported versions

Pre-release: only the latest `main` is supported. Once versioned releases exist, the latest release will receive security fixes.
