# Claude Usage Plasmoid

KDE Plasma 6 panel widget showing Claude Code usage limits at a glance.

```
▓57%  ⏱ 3h        ← Session mode (click to toggle)
📅16% ⏱ 2d        ← Weekly mode
```

- **Session %** / **Weekly %** with a reset countdown
- **Click** the widget to toggle Session ↔ Weekly
- Status colors: green <50%, yellow 50–80%, red 81–99%, dark red + pulse ≥100%
- Auto-refresh (default 300s, configurable 60s–3600s; countdown ticks locally between fetches)

## Requirements

- KDE Plasma 6.6+ / Qt 6.10+
- Claude Code already authenticated on this machine (an OAuth token in `~/.claude/.credentials.json`)
- `python3` 3.10+ in `PATH` (stdlib only — no extra packages)

## Install

```bash
make install      # copies into ~/.local/share/plasma/plasmoids/
make restart      # or just log out / back in
```

Then **Add Widgets… → "Claude Usage"** and drop it on a panel.

```bash
make remove       # uninstall
make test         # run the data collector standalone (prints JSON)
```

## How it works

A Python collector (`contents/code/collect.py`) reads the OAuth access token
Claude Code stores in `~/.claude/.credentials.json` and makes a single HTTPS
`GET https://api.anthropic.com/api/oauth/usage` — the same endpoint the TUI
`/usage` panel hits internally. It maps the response to JSON for the QML widget:

```json
{"five_hour": {"utilization": 13.0, "resets_at": "...Z"},
 "seven_day": {"utilization": 22.0, "resets_at": "...Z"}}
```

Notes on the approach:

- **No `claude` process is spawned.** A fetch is a sub-second HTTPS call — the
  widget does **not** open a Claude Code session to read usage. (Earlier
  versions drove the TUI through a PTY, which took 15–25 s per fetch.)
- `five_hour` → **Session**, `seven_day` → **Weekly**. `utilization` is already
  a percentage; `resets_at` is an ISO timestamp.
- **Token refresh:** the access token is short-lived and Claude Code refreshes
  it during normal use. If it's expired (HTTP 401) the collector refreshes it
  via the OAuth `refresh_token` grant and rewrites the credentials file
  atomically — but **only when no `claude` session is live** (it checks
  `~/.claude/sessions/`), to avoid racing the CLI's own token rotation.
- **Rate-limit safe.** The endpoint is rate-limited (HTTP 429). The collector
  never calls it more than once per ~45 s (serving a recent cached result in
  `~/.cache/claude-usage-plasmoid.json` otherwise), and on any failed fetch it
  falls back to the last good numbers (≤1 h old) instead of blanking the panel.
- **Fails soft** — on any hiccup the widget shows a stale/error state, never
  crashes.

## Config

Right-click the widget → **Configure…** → set the refresh interval (seconds).

## UI states

| State   | Panel               | When                                    |
|---------|---------------------|-----------------------------------------|
| Loading | `⏳ --%  ⏱ --` (dim) | first fetch in progress                 |
| Ok      | `▓57% ⏱ 3h`         | data fetched                            |
| Stale   | `⚠️57% ⏱ 3h?`       | 2 consecutive failed fetches            |
| Error   | `⚠️ N/A ⏱ --`       | no credentials / request failed         |

## Troubleshooting

- **`⚠️ N/A` / stuck stale** → run `make test` and check it prints JSON with
  `session`/`weekly`. The `error` field names the cause (no credentials,
  expired token, HTTP status).
- **`token expired`** → the access token is refreshed automatically when you
  next use `claude`; the collector also self-refreshes when no claude session
  is running. If you've been logged out, run `claude` once to re-authenticate.
- **`no credentials`** → Claude Code isn't authenticated on this machine
  (`~/.claude/.credentials.json` missing). Log in with `claude` first.
- **Tier (Pro/Max)** comes from `subscriptionType` in the credentials and is
  not shown in the panel.
- Weekly is absent on plans without a weekly window; the widget falls back to
  the session figure.

## License

MIT
