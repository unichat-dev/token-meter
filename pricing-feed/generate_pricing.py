#!/usr/bin/env python3
# Copyright 2026 UniChat Dev - Ilhan Akbudak
# SPDX-License-Identifier: Apache-2.0
"""Generates TokenMeter's pricing feed.

Upstream: LiteLLM's community-maintained pricing table (MIT licensed) —
the de-facto machine-readable source for OpenAI/Anthropic/etc. prices,
used by ccusage and most usage tools. We deliberately do NOT scrape the
vendors' pricing pages: there is no official pricing API, and the pages
are JS-rendered marketing layouts that break scrapers on every redesign.

This script normalizes the upstream data (~2 MB, hundreds of providers)
into TokenMeter's own compact, stable schema (a few KB, chat models from
providers we track). The app depends only on OUR schema, so upstream can
be swapped or extended (more vendors, a cross-check source) without an
app update.

Outputs:
  pricing-feed/pricing.json      — served raw from GitHub (the "API")
  Resources/default-pricing.json — bundled into the app as offline fallback

Run: python3 pricing-feed/generate_pricing.py [upstream.json]
     (stdlib only, no deps; optional arg reads a pre-downloaded upstream
     file instead of fetching — handy for testing and machines whose
     Python lacks CA certificates)
CI:  .github/workflows/update-pricing.yml runs this daily and commits
     only when prices actually changed.
"""

import datetime
import json
import pathlib
import re
import sys
import urllib.request

LITELLM_URL = (
    "https://raw.githubusercontent.com/BerriAI/litellm/main/"
    "model_prices_and_context_window.json"
)

# Plain model keys we track (no provider-prefixed duplicates like
# "azure/gpt-4o" or "us.anthropic.claude-..." — the CLI logs use plain ids).
INCLUDE_KEY = re.compile(r"^(claude-|gpt-|chatgpt-|o[134](-mini|-pro)?(-|$))")

SCHEMA_VERSION = 1


def per_mtok(cost_per_token):
    """USD per token → USD per million tokens, trimmed of float noise."""
    if cost_per_token is None:
        return None
    return round(cost_per_token * 1_000_000, 6)


def build_models(upstream):
    models = {}
    for key, info in upstream.items():
        if "/" in key or not INCLUDE_KEY.match(key):
            continue
        if not isinstance(info, dict):
            continue
        if info.get("mode") not in (None, "chat", "responses"):
            continue
        input_cost = per_mtok(info.get("input_cost_per_token"))
        output_cost = per_mtok(info.get("output_cost_per_token"))
        if input_cost is None or output_cost is None:
            continue

        entry = {"inputPerMTok": input_cost, "outputPerMTok": output_cost}
        cache_read = per_mtok(info.get("cache_read_input_token_cost"))
        cache_write = per_mtok(info.get("cache_creation_input_token_cost"))
        if cache_read is not None:
            entry["cacheReadPerMTok"] = cache_read
        if cache_write is not None:
            entry["cacheWritePerMTok"] = cache_write
        models[key] = entry
    return dict(sorted(models.items()))


def main():
    root = pathlib.Path(__file__).resolve().parent
    feed_path = root / "pricing.json"
    bundled_path = root.parent / "Resources" / "default-pricing.json"

    if len(sys.argv) > 1:
        upstream = json.loads(pathlib.Path(sys.argv[1]).read_text())
    else:
        with urllib.request.urlopen(LITELLM_URL, timeout=60) as response:
            upstream = json.load(response)

    models = build_models(upstream)
    if len(models) < 20:  # sanity guard: upstream format probably changed
        sys.exit(f"refusing to write suspicious feed: only {len(models)} models parsed")

    # Keep generatedAt stable when nothing changed, so the daily CI run
    # doesn't create a no-op commit every day.
    generated_at = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )
    if feed_path.exists():
        previous = json.loads(feed_path.read_text())
        if previous.get("models") == models:
            generated_at = previous.get("generatedAt", generated_at)

    feed = {
        "schemaVersion": SCHEMA_VERSION,
        "generatedAt": generated_at,
        "source": "litellm/model_prices_and_context_window.json (MIT)",
        "note": "Community-maintained estimates, not vendor invoices.",
        "models": models,
    }
    output = json.dumps(feed, indent=1) + "\n"
    feed_path.write_text(output)
    bundled_path.parent.mkdir(parents=True, exist_ok=True)
    bundled_path.write_text(output)
    print(f"wrote {len(models)} models to {feed_path} and {bundled_path}")


if __name__ == "__main__":
    main()
