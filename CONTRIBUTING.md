# Contributing to TokenMeter

Thanks for your interest! TokenMeter is a native Swift/SwiftUI macOS app. This doc covers the ground rules.

## Ground rules (non-negotiable)

1. **No secrets, ever.** No API keys (`sk-ant-…`, `sk-ant-admin…`, `sk-…`), signing certificates, or provisioning profiles in the repo — not in code, not in tests, not in fixtures, not in commit history.
2. **No real log data.** Never commit real `~/.claude` (or Codex) JSONL logs — they contain your prompts and project paths. Test data lives in [`fixtures/`](./fixtures/) and must be **fabricated**. Real logs for local debugging go in `fixtures/real/` or `*.jsonl.local`, both gitignored.
3. **Honesty in UI copy.** Any number derived from local logs must be labeled **estimated**. Never present reconstructed 5-hour/weekly windows as real subscription quota — no public API exposes the real numbers, and the local logs are known to under-report.

## One-time setup

```sh
make bootstrap   # installs xcodegen + gitleaks, wires the pre-commit hook, generates the project
```

Or manually:

```sh
brew install xcodegen gitleaks
git config core.hooksPath .githooks   # secret-scanning pre-commit hook
xcodegen generate                     # creates TokenMeter.xcodeproj (gitignored)
```

The repo ships a [gitleaks](https://github.com/gitleaks/gitleaks) pre-commit hook that blocks commits containing secrets. CI also runs gitleaks on every push/PR, so skipping the hook locally won't get a secret onto `main` — but the hook saves you from ever needing a history rewrite.

## Development

- **Requirements:** Xcode 16+, macOS 14+ (min deployment target: macOS 14).
- **Project generation:** the `.xcodeproj` is **generated, never committed**. Edit `project.yml` (XcodeGen spec) and re-run `xcodegen generate` (or `make generate`) after pulling changes that touch it.
- **Stack:** SwiftUI (`MenuBarExtra`), SwiftData, Swift Charts, FSEvents/DispatchSource for file watching. Swift 6 language mode with strict concurrency; warnings are errors.
- **Structure:** `Sources/{Core, DataSources, Persistence, UI, Widget}` + `Tests/`.
- **Secrets:** `KeychainStore` (in `Sources/Core`) is the only sanctioned storage for API keys — never UserDefaults, SwiftData, plists, or logs.
- **Tests:** `make test` (Swift Testing framework). Parser tests run against the sanitized fixtures in `fixtures/`. New parsing/aggregation code needs tests.

## Pull requests

- Branch from `main`; keep PRs focused on one change.
- Fill in the PR template (it includes the secrets/fixtures checklist).
- Make sure the project builds and tests pass locally before requesting review.
- For larger features, open an issue first so we can align on approach.

## Reporting security issues

Privately, please — see [`SECURITY.md`](./SECURITY.md).
