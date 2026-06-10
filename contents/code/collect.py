#!/usr/bin/env python3
"""Claude Usage collector — HTTP, no TUI session.

Reads the OAuth access token Claude Code stores in ~/.claude/.credentials.json
and calls GET https://api.anthropic.com/api/oauth/usage — the same endpoint the
TUI `/usage` panel hits internally (`fetchUtilization`). Prints a single JSON
object on stdout for the Plasma widget.

No `claude` process is spawned: a fetch is one sub-second HTTPS GET, so the
widget no longer opens a Claude Code session every refresh.

Token handling: the access token is short-lived and Claude Code refreshes it
during normal use. If the token is expired (HTTP 401) this collector refreshes
it via the OAuth refresh_token grant and rewrites the credentials file
atomically — but ONLY when no claude process is live (a session file in
~/.claude/sessions whose pid is still alive), to avoid racing the CLI's own
refresh-token rotation (which would otherwise force a re-login).

Never crashes the widget: on any failure it prints a well-formed error JSON
(exit 0) and logs detail to stderr. stdlib only.

Output schema (the contract with main.qml):

    {version, provider, session, weekly, tier, fetchedAt, error}

where session/weekly are {pct, resetAt, secondsToReset} or null. `session` maps
to the API's five_hour window, `weekly` to seven_day.
"""

import json
import os
import sys
import urllib.error
import urllib.request
from datetime import datetime, timezone

USAGE_URL = "https://api.anthropic.com/api/oauth/usage"
TOKEN_URL = "https://platform.claude.com/v1/oauth/token"
CLIENT_ID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"  # public Claude Code OAuth client
OAUTH_BETA = "oauth-2025-04-20"
CREDS_PATH = os.path.expanduser("~/.claude/.credentials.json")
SESSIONS_DIR = os.path.expanduser("~/.claude/sessions")
CACHE_PATH = os.path.join(
    os.environ.get("XDG_CACHE_HOME") or os.path.expanduser("~/.cache"),
    "claude-usage-plasmoid.json")
TIMEOUT_S = 10
# The usage endpoint is rate-limited (HTTP 429). Never hit it more often than
# this regardless of how often the widget polls, and serve a recent cached
# result instead. Usage moves slowly; the countdown ticks locally in the UI.
MIN_FETCH_INTERVAL_S = 45
# On a failed live fetch, fall back to the last good result if it's no older
# than this (so a transient 429 / network blip keeps the numbers on screen
# instead of blanking to N/A).
CACHE_MAX_AGE_S = 3600


def now_utc() -> datetime:
    return datetime.now(timezone.utc)


def base_result() -> dict:
    return {
        "version": 1,
        "provider": "claude",
        "session": None,
        "weekly": None,
        "tier": "unknown",
        "fetchedAt": now_utc().isoformat().replace("+00:00", "Z"),
        "error": None,
    }


def error_result(msg: str) -> dict:
    r = base_result()
    r["error"] = msg
    return r


# ---------------------------------------------------------------------------
# credentials
# ---------------------------------------------------------------------------

def read_oauth() -> dict:
    """Return the claudeAiOauth object from the credentials file (raises on
    missing/unreadable — caller turns that into an error result)."""
    with open(CREDS_PATH) as f:
        return json.load(f)["claudeAiOauth"]


def write_oauth(new_oauth: dict) -> None:
    """Atomically merge a refreshed claudeAiOauth back into the credentials
    file, preserving every other top-level key (mcpOAuth, organizationUuid…)."""
    with open(CREDS_PATH) as f:
        full = json.load(f)
    full["claudeAiOauth"] = new_oauth
    tmp = CREDS_PATH + ".tmp"
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(full, f, indent=2)
    os.replace(tmp, CREDS_PATH)


def claude_is_running() -> bool:
    """True if any Claude Code session is live. Each running session writes
    ~/.claude/sessions/<pid>.json; the pid being alive is the signal. Used to
    skip self-refresh while the CLI may rotate the refresh token concurrently."""
    try:
        names = os.listdir(SESSIONS_DIR)
    except OSError:
        return False
    for name in names:
        if not name.endswith(".json"):
            continue
        try:
            pid = int(name[:-5])
            os.kill(pid, 0)  # raises if no such process
            return True
        except (ValueError, ProcessLookupError):
            continue
        except PermissionError:
            return True  # exists but not ours — treat as live
    return False


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------

def _request(url: str, *, token: str = None, body: bytes = None) -> tuple:
    """Return (status, parsed_json_or_None). Never raises for HTTP errors."""
    headers = {"Content-Type": "application/json", "anthropic-beta": OAUTH_BETA}
    if token:
        headers["Authorization"] = f"Bearer {token}"
    req = urllib.request.Request(url, data=body, headers=headers,
                                 method="POST" if body else "GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_S) as resp:
            return resp.status, json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        return e.code, None
    except (urllib.error.URLError, ValueError, OSError) as e:
        print(f"request failed: {e}", file=sys.stderr)
        return None, None


def get_usage(token: str) -> tuple:
    return _request(USAGE_URL, token=token)


def refresh_oauth(oauth: dict) -> dict:
    """POST the refresh_token grant; return an updated claudeAiOauth dict, or
    None on failure. Preserves fields the token response doesn't carry."""
    body = json.dumps({
        "grant_type": "refresh_token",
        "client_id": CLIENT_ID,
        "refresh_token": oauth.get("refreshToken"),
    }).encode("utf-8")
    status, data = _request(TOKEN_URL, body=body)
    if status != 200 or not data or "access_token" not in data:
        print(f"token refresh failed: HTTP {status}", file=sys.stderr)
        return None
    new = dict(oauth)
    new["accessToken"] = data["access_token"]
    if data.get("refresh_token"):
        new["refreshToken"] = data["refresh_token"]
    if data.get("expires_in"):
        new["expiresAt"] = int(now_utc().timestamp() * 1000) + int(data["expires_in"]) * 1000
    if data.get("scope"):
        new["scopes"] = data["scope"].split()
    return new


# ---------------------------------------------------------------------------
# response -> widget schema
# ---------------------------------------------------------------------------

def parse_block(block) -> dict:
    """Map an API window {utilization, resets_at} to {pct, resetAt,
    secondsToReset}. `utilization` is already a percentage (0-100)."""
    if not isinstance(block, dict) or block.get("utilization") is None:
        return None
    out = {"pct": float(block["utilization"]), "resetAt": None, "secondsToReset": None}
    raw = block.get("resets_at")
    if raw:
        try:
            dt = datetime.fromisoformat(str(raw)).astimezone(timezone.utc)
            out["resetAt"] = dt.isoformat().replace("+00:00", "Z")
            out["secondsToReset"] = max(0, int((dt - now_utc()).total_seconds()))
        except (ValueError, TypeError):
            print(f"could not parse resets_at: {raw!r}", file=sys.stderr)
    return out


def build_result(usage: dict, tier: str) -> dict:
    r = base_result()
    r["tier"] = tier
    r["session"] = parse_block(usage.get("five_hour"))
    r["weekly"] = parse_block(usage.get("seven_day"))
    if r["session"] is None and r["weekly"] is None:
        r["error"] = "usage payload had no windows"
    return r


# ---------------------------------------------------------------------------
# cache (rate-limit throttle + last-good fallback)
# ---------------------------------------------------------------------------

def read_cache() -> dict:
    try:
        with open(CACHE_PATH) as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def write_cache(result: dict) -> None:
    try:
        os.makedirs(os.path.dirname(CACHE_PATH), exist_ok=True)
        tmp = CACHE_PATH + ".tmp"
        with open(tmp, "w") as f:
            json.dump(result, f)
        os.replace(tmp, CACHE_PATH)
    except OSError as e:
        print(f"could not write cache: {e}", file=sys.stderr)


def cache_age(cached: dict) -> float:
    """Seconds since the cached result was fetched (huge number if unknown)."""
    try:
        t = datetime.fromisoformat(cached["fetchedAt"].replace("Z", "+00:00"))
        return (now_utc() - t).total_seconds()
    except (KeyError, ValueError, TypeError, AttributeError):
        return float("inf")


# ---------------------------------------------------------------------------

def live_fetch() -> dict:
    """One real fetch (no caching). Returns a result dict; session/weekly are
    null with an error string on failure."""
    try:
        oauth = read_oauth()
    except (OSError, KeyError, ValueError) as e:
        return error_result(f"no credentials: {e}")

    token = oauth.get("accessToken")
    if not token:
        return error_result("no access token in credentials")

    status, data = get_usage(token)

    # expired token -> refresh + retry, but only when the CLI isn't live
    if status == 401:
        if claude_is_running():
            return error_result("token expired (claude session active; will refresh on use)")
        new = refresh_oauth(oauth)
        if not new:
            return error_result("token expired and refresh failed")
        try:
            write_oauth(new)
        except OSError as e:
            print(f"could not write refreshed credentials: {e}", file=sys.stderr)
        status, data = get_usage(new["accessToken"])

    if status != 200 or data is None:
        return error_result(f"usage request failed: HTTP {status}")

    tier = str(oauth.get("subscriptionType", "unknown")).lower()
    return build_result(data, tier)


def fetch() -> dict:
    cached = read_cache()
    have_cache = bool(cached and (cached.get("session") or cached.get("weekly")))

    # throttle: serve a recent cached result without touching the API
    if have_cache and cache_age(cached) < MIN_FETCH_INTERVAL_S:
        return cached

    result = live_fetch()
    if result.get("session") or result.get("weekly"):
        write_cache(result)
        return result

    # live fetch failed (429, network, expired-while-active): keep showing the
    # last good numbers if they're still reasonably fresh
    if have_cache and cache_age(cached) < CACHE_MAX_AGE_S:
        print(f"serving cached result after live fetch failed: {result['error']}",
              file=sys.stderr)
        return cached
    return result


def main() -> None:
    # hidden self-test: parse a usage-API JSON payload from stdin
    if "--selftest" in sys.argv:
        print(json.dumps(build_result(json.load(sys.stdin), "test")))
        return

    print(json.dumps(fetch()))


if __name__ == "__main__":
    main()
