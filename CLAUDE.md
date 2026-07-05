# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

KDE Plasma 6 panel widget (plasmoid) that shows Claude Code usage limits — session % and weekly % with a reset countdown. Two parts: a Python data collector and a QML UI. No build step; QML/JSON are read at runtime by plasmashell.

## Commands

```bash
make install   # copy contents/ + metadata.json -> ~/.local/share/plasma/plasmoids/<id>/
make restart   # killall plasmashell && kstart plasmashell (picks up changes)
make remove    # uninstall
make test      # run collector standalone, prints JSON (the integration test)
```

There is no unit-test harness or linter. `make test` runs the collector (a sub-second HTTPS call); it prints JSON with `session`/`weekly`, or an `error` field naming the cause.

Collector self-test (parses a canned usage-API JSON payload from stdin, no network):

```bash
echo '{"five_hour":{"utilization":98,"resets_at":"2026-06-10T22:10:00+00:00"},"seven_day":{"utilization":20,"resets_at":"2026-06-12T22:00:00+00:00"}}' | python3 contents/code/collect.py --selftest
```

After editing QML/Python you must `make install` then `make restart` (or `make update`) — the installed copy under `~/.local/share/...` is what runs, not this working tree.

## Architecture

Data flows one way: `collect.py` → JSON on stdout → `main.qml` parses and renders.

**`contents/code/collect.py`** — reads the OAuth access token from `~/.claude/.credentials.json` and makes one HTTPS `GET https://api.anthropic.com/api/oauth/usage` (the same endpoint the TUI `/usage` panel calls internally — `fetchUtilization`). No `claude` process is spawned; a fetch is sub-second.

Key facts about this approach:
- **Endpoint contract** (reverse-engineered from the CLI binary): `GET /api/oauth/usage` with headers `Authorization: Bearer <accessToken>` and `anthropic-beta: oauth-2025-04-20`. Response: `{five_hour:{utilization, resets_at}, seven_day:{...}, seven_day_opus, ...}` where `utilization` is **already a percentage (0–100)** and `resets_at` is an ISO timestamp. `five_hour` → session, `seven_day` → weekly. Opus/Sonnet sub-windows are null on Pro.
- **Token refresh.** The access token is short-lived (hours) and Claude Code refreshes it during normal use. On HTTP 401 the collector POSTs the `refresh_token` grant to `https://platform.claude.com/v1/oauth/token` (public client_id `9d1c250a-…`), then rewrites `~/.claude/.credentials.json` **atomically** (temp + `os.replace`, preserving `mcpOAuth`/`organizationUuid`). It normally refreshes **only when no claude session is live** — `claude_is_running()` checks `~/.claude/sessions/<pid>.json` and `os.kill(pid,0)` — to avoid racing the CLI's own refresh-token rotation (which would force a re-login). **Exception:** if the token is expired more than `REFRESH_GRACE_S` (60 s) past its own `expiresAt` (`token_expired_beyond_grace`), it refreshes even with a session live — a live CLI refreshes proactively around expiry, so a token still expired that long means the session is idle and won't rotate the token itself. Without this, an idle-but-open session blocked every refresh indefinitely and the panel froze on stale numbers (e.g. a reset window stuck at 100%).
- **Rate-limit handling.** The endpoint returns HTTP 429 if hit too often. `fetch()` wraps `live_fetch()` with a cache at `~/.cache/claude-usage-plasmoid.json`: it serves the cache (no API call) when it's younger than `MIN_FETCH_INTERVAL_S` (45 s), and on any failed live fetch falls back to the cached last-good result if it's younger than `CACHE_MAX_AGE_S` (1 h). So the widget poll interval is decoupled from actual API hits, and a transient 429 never blanks the panel. Cache served **after a failed live fetch** is flagged `stale:true` so the UI dims it and keeps retrying, rather than presenting a frozen last-good value as current. There is intentionally **no** retry loop — retrying immediately on a 429 makes it worse.
- **Fails soft, never crashes the widget** — every failure path returns a well-formed `error_result(...)` JSON with exit 0. The output JSON shape is the contract with the UI and is unchanged from the old PTY implementation: `{version, provider, session, weekly, tier, fetchedAt, error, stale}` where each of `session`/`weekly` is `{pct, resetAt, secondsToReset}` or null.

**`contents/ui/main.qml`** — the plasmoid. `PlasmoidItem` forced to `compactRepresentation` (panel icon). A `Plasma5Support.DataSource` (engine `executable`) runs `collect.py` via `python3`; `refreshTimer` re-fetches on the configured interval; a separate 30 s `displayTimer` toggles `root.tick` so the countdown text re-evaluates locally between fetches (countdown is recomputed from `resetAt`, not the stale `secondsToReset`).
- UI state machine: `loading → ok / stale / error`. A single failed fetch is tolerated (stays `ok`); two consecutive failures with prior data → `stale`; failure with no data ever → `error`. A successful parse carrying `stale:true` (collector served last-good cache after a failed live fetch) → `stale` directly. See `handleOutput`.
- Click toggles session ↔ weekly (`toggleMode`); `block()` falls back to whichever block has data (Pro accounts have no weekly).
- `statusColor(pct)` thresholds (green <50 / yellow 50–80 / red 81–99 / dark-red+pulse ≥100) come from spec §6 and have light/dark theme variants keyed off panel luminance.

**Config** — `contents/config/main.xml` (KConfig schema: `refreshIntervalSeconds`, default 300, 60–3600), `config.qml` (category), `configGeneral.qml` (the spinbox). Read in QML as `plasmoid.configuration.refreshIntervalSeconds`.

## Reference

`spec.md` is the original design spec — consult it for intended behavior, color rules, and UI-state definitions before changing UI semantics. `metadata.json` holds the plasmoid id (`com.github.chrisotm.claude-usage-plasmoid`) and config-location name, which must stay in sync with `main.xml`'s `kcfgfile` and the Makefile's `PLASMOID_ID`.

Requirements: KDE Plasma 6.6+ / Qt 6.10+, Claude Code authenticated on the machine (OAuth token in `~/.claude/.credentials.json`), `python3` 3.10+ (stdlib only — `urllib` for HTTP, no external packages).
