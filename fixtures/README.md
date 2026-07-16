# Test fixtures

**Everything in this directory is fabricated.** These files imitate the *shape* of real data sources (Claude Code JSONL logs, and later Codex/Ollama/API responses) but contain no real prompts, project paths, message IDs, token counts, or credentials.

## Rules

- ✅ Fabricated samples only — invented UUIDs (`00000000-…`), `msg_fixture_…` IDs, `/Users/dev/projects/demo-app` style paths, made-up token counts.
- ❌ Never copy a real log line from `~/.claude` into this directory, even "just one line" — real logs embed your prompts and filesystem paths.
- 🔒 Real logs for local debugging go in `fixtures/real/` or files named `*.jsonl.local` — both are gitignored.

## Layout

- `claude-code/` — fabricated `~/.claude/projects/**/*.jsonl` samples
  - `session-basic.jsonl` — a clean session: user + assistant events with `usage` blocks, spanning a 5-hour-block boundary
  - `session-edge-cases.jsonl` — malformed line, assistant event without `usage`, duplicate message id, and a truncated final line (no trailing newline), for parser robustness tests
