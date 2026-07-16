# TokenMeter

A native macOS menu-bar app that tracks your AI token usage and estimated cost across **Claude Code**, **developer APIs** (Anthropic, OpenAI), and **local models via Ollama** — with usage history, charts, and a desktop widget.

> **Status: pre-alpha.** The project is under active development; nothing is buildable yet. This README describes the intended MVP scope.

## ⚠️ The honesty guardrail — read this first

**TokenMeter cannot show your real Claude Pro/Max (or ChatGPT Plus) subscription quota.** Anthropic and OpenAI do not expose the 5-hour / weekly subscription limits through any public API.

What TokenMeter actually does:

| Data source | Accuracy | How |
|---|---|---|
| Claude Code local logs (`~/.claude/projects/**/*.jsonl`) | **Estimated** — logs are known to under-report token counts, sometimes significantly | Local file parsing, no network |
| Anthropic Usage & Cost API | Accurate (billing-grade) | Requires an **Admin** API key (`sk-ant-admin…`) |
| OpenAI Usage API + Costs endpoint | Accurate (billing-grade) | Requires an API key |
| Ollama (local models) | Accurate token counts, no cost (it's local) | Local REST API |

Every number derived from local logs is labeled **"estimated"** in the UI — including the reconstructed 5-hour-block and weekly views. They approximate your subscription usage from log timestamps; they are **not** your real remaining quota. Usage from the Claude/ChatGPT web or desktop chat apps leaves no local trace and is invisible to this tool.

## Features (MVP)

- 🖥️ **Menu-bar dashboard** — today's total tokens + estimated cost at a glance
- 📄 **Claude Code log parsing** with live file-watching (near-real-time updates)
- ⏱️ **Estimated usage windows** — reconstructed 5-hour blocks, daily and weekly rollups
- 📊 **History + charts** — tokens & cost over time, per-model and per-project breakdowns
- 💲 **Editable pricing table** — bundled per-model $/token defaults you can override locally

Planned next: Ollama integration, Anthropic/OpenAI API connectors, Codex CLI log parsing, and a WidgetKit desktop widget.

## Install

Not yet released. Planned distribution:

- **Direct download** — notarized Developer ID build (not sandboxed, so it can read `~/.claude` with your permission)
- **Homebrew** — `brew install --cask tokenmeter` (once published)

Build from source today:

```sh
git clone https://github.com/unichat-dev/token-meter.git
cd token-meter
make bootstrap   # installs xcodegen + gitleaks, generates the Xcode project
make build
```

Requires **macOS 14 (Sonoma)** or later and Xcode 16+.

### Full Disk Access

To read Claude Code's logs under `~/.claude`, TokenMeter needs **Full Disk Access** (System Settings → Privacy & Security → Full Disk Access). The app detects the missing permission and walks you through granting it. Everything stays on your machine — log data is never uploaded anywhere.

## Privacy & security

- **All data stays local.** Log parsing happens on-device; history is stored in a local database in `~/Library/Application Support`.
- **API keys live in the macOS Keychain only** — never in the database, UserDefaults, plists, or logs.
- The only network calls are the ones you opt into: polling the Anthropic/OpenAI usage APIs with your own keys, and the local Ollama endpoint.

Found a vulnerability? See [`SECURITY.md`](./SECURITY.md).

## Contributing

Contributions welcome — see [`CONTRIBUTING.md`](./CONTRIBUTING.md). Note the secret-scanning pre-commit hook setup there before your first commit.

## License

[Apache-2.0](./LICENSE) © UniChat Dev - Ilhan Akbudak
