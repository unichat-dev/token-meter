# Pricing feed

TokenMeter's "small pricing API", implemented serverlessly:

```
LiteLLM community pricing data (MIT)
        │  .github/workflows/update-pricing.yml — daily cron
        ▼
pricing-feed/pricing.json        ← OUR schema; served via raw.githubusercontent.com
Resources/default-pricing.json   ← identical copy bundled into the app (offline fallback)
        │  app fetches daily (ETag conditional GET)
        ▼
in-app resolution: user override → remote/cached feed → bundled default
```

## Why this design

- **No scraping of vendor pricing pages.** Neither Anthropic nor OpenAI has an
  official pricing API; their pricing pages are JS-rendered marketing layouts
  that break scrapers on every redesign. [LiteLLM's pricing table]
  (https://github.com/BerriAI/litellm/blob/main/model_prices_and_context_window.json)
  is the community-maintained machine-readable source used by ccusage and most
  usage tools.
- **Indirection through our own schema.** The app depends only on
  `pricing.json`'s shape (`schemaVersion`, `models.{id}.{tier}PerMTok` in USD
  per million tokens). Upstream sources can be swapped, cross-checked, or
  extended (more vendors) without an app update.
- **Serverless.** GitHub Actions is the fetcher, the repo is the host: zero
  hosting cost, and every price change is an auditable commit.
- **Honesty guardrail:** these are community-maintained estimates, not vendor
  invoices — and the app UI says so.

## Operating it

- Regenerate manually: `make update-pricing` (or
  `python3 pricing-feed/generate_pricing.py [pre-downloaded-upstream.json]`).
- CI runs daily (`update-pricing.yml`) and commits **only when prices changed**
  (`generatedAt` is kept stable on no-op runs).
- The app defaults to the official feed:
  `https://raw.githubusercontent.com/unichat-dev/token-meter/main/pricing-feed/pricing.json`
  (override or test alternatives in Settings → Pricing).
- The script refuses to write a feed with < 20 models (upstream format-change guard).
