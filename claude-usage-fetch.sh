#!/usr/bin/env bash
# Fetches the ACCOUNT's true rate-limit usage from the Anthropic OAuth usage
# endpoint and writes it into the per-account rate-limits cache the statusline
# reads. Called by the statusline in the background when the cache holds no
# fresh authoritative snapshot (see the RL block in statusline.sh).
#
# Why this exists: Claude Code caches account usage in the SHARED ~/.claude.json
# (.cachedUsageUtilization) without honoring which account a session actually
# bills, so on multi-account machines (keychain login + CLAUDE_CODE_OAUTH_TOKEN
# sessions) every session's stdin rate_limits shows whichever account fetched
# last. Asking the API directly with the SESSION'S OWN credential makes the
# bars authoritative per account.
#
# Credential: read from STDIN (never argv or env, so it cannot leak through
# ps/procargs). Empty stdin falls back to the stored login, exactly like
# hooks/session-topic-capture.sh: macOS Keychain first, then
# ~/.claude/.credentials.json. The credential is only ever sent to
# api.anthropic.com over HTTPS (via a curl config on stdin, keeping it out of
# curl's argv) and is never logged or written to disk.
#
# Cache line format (a superset of the statusline's 4-field format):
#   FIVE_PCT|FIVE_RESET|SEVEN_PCT|SEVEN_RESET|FETCHED_EPOCH
# The 5th field marks the line AUTHORITATIVE: while it is fresh the statusline
# displays it unconditionally instead of comparing against the stdin snapshot.
# On any failure (no credential, network, HTTP error, parse) the cache is left
# untouched, so a transient error never erases the last known-good data.
#
# Env seams (mirror claude-status-fetch.sh):
#   CC_STATUSLINE_RL_CACHE    destination cache file (passed by the spawner)
#   CC_STATUSLINE_USAGE_DATA  JSON fixture instead of the network (tests)
#   CC_STATUSLINE_NOW         pinned clock for the FETCHED_EPOCH stamp (tests)

set -uo pipefail

_state_dir() {
    local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    local uid d
    uid=$(id -u 2>/dev/null || echo 0)
    d="${base%/}/cc-statusline-${uid}"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    printf '%s' "$d"
}
# Single-sourced version for the User-Agent. Reads the tracked VERSION file
# shipped next to the install; "dev" if absent.
_cc_version() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    { cat "$d/VERSION" "$d/../VERSION"; } 2>/dev/null | head -1
}
VERSION="$(_cc_version)"; VERSION="${VERSION:-dev}"

CACHE_FILE="${CC_STATUSLINE_RL_CACHE:-$(_state_dir)/rate-limits}"
TMP_FILE="${CACHE_FILE}.fetch.$$"
BODY_FILE="${CACHE_FILE}.body.$$"
# An HTTP error (notably 429: the endpoint rate-limits usage lookups
# independently of the account's own quota) drops this marker; the statusline
# stops spawning fetches while it is fresh, so a rejected credential or a
# throttled endpoint is never hammered. Cleared on the next success.
BACKOFF_FILE="${CACHE_FILE}.backoff"
trap 'rm -f "$TMP_FILE" "$BODY_FILE"' EXIT

# Token from stdin (the spawner pipes it; token sessions). Size-capped and
# whitespace-stripped; `timeout` so a ttyless manual invocation cannot hang.
TOKEN=$(timeout 2 head -c 4096 2>/dev/null | tr -d '[:space:]') || TOKEN=""
if [ -z "$TOKEN" ]; then
    # Stored-login fallback (keychain sessions), matching the topic hook.
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) \
        && TOKEN=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -z "$TOKEN" ]; then
        TOKEN=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
    fi
fi
[ -z "$TOKEN" ] && exit 0

if [ -n "${CC_STATUSLINE_USAGE_DATA:-}" ]; then
    # Test seam: fixture body, with the HTTP status the transport "returned".
    data=$(cat "$CC_STATUSLINE_USAGE_DATA" 2>/dev/null) || exit 0
    http="${CC_STATUSLINE_USAGE_HTTP:-200}"
else
    # The Authorization header travels via `--config -` on stdin, NOT argv, so
    # the token is never visible in the process list even transiently.
    http=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
        | curl -s --max-time 8 --config - \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "Accept: application/json" \
            -H "User-Agent: cc-statusline/${VERSION}" \
            -o "$BODY_FILE" -w '%{http_code}' \
            "https://api.anthropic.com/api/oauth/usage" 2>/dev/null) || http=""
    data=$(cat "$BODY_FILE" 2>/dev/null)
fi
# The usage endpoint refuses some credentials (observed: HTTP 429 for a
# CLAUDE_CODE_OAUTH_TOKEN that the Messages API happily accepts). The same
# numbers ride on every Messages API response as anthropic-ratelimit-unified-*
# headers, so fall back to a minimal request (haiku, max_tokens 1) and read the
# limits off its headers. Utilization there is a 0-1 fraction (verified against
# the usage endpoint: 0.55 <-> 55%); resets are already epoch seconds.
#
# The probe costs a token or two of the account's quota, so it only runs when
# the usage endpoint failed, and STATUSLINE_RL_PROBE=0 turns it off entirely
# (the account then just backs off and keeps Claude Code's numbers).
if [ "${http:-}" != "200" ] && [ -n "${http:-}" ] && [ "${STATUSLINE_RL_PROBE:-1}" != "0" ] \
    && { [ -z "${CC_STATUSLINE_USAGE_DATA:-}" ] || [ -n "${CC_STATUSLINE_USAGE_HDRS:-}" ]; }; then
    HDR_FILE="${CACHE_FILE}.hdr.$$"
    trap 'rm -f "$TMP_FILE" "$BODY_FILE" "$HDR_FILE"' EXIT
    if [ -n "${CC_STATUSLINE_USAGE_HDRS:-}" ]; then
        # Test seam: a header dump fixture stands in for the probe response.
        cp "$CC_STATUSLINE_USAGE_HDRS" "$HDR_FILE" 2>/dev/null && phttp=200 || phttp=""
    else
    phttp=$(printf 'header = "Authorization: Bearer %s"\n' "$TOKEN" \
        | curl -s --max-time 8 --config - \
            -H "anthropic-beta: oauth-2025-04-20" \
            -H "anthropic-version: 2023-06-01" \
            -H "content-type: application/json" \
            -H "User-Agent: cc-statusline/${VERSION}" \
            -d '{"model":"claude-haiku-4-5-20251001","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}' \
            -D "$HDR_FILE" -o /dev/null -w '%{http_code}' \
            "https://api.anthropic.com/v1/messages" 2>/dev/null) || phttp=""
    fi
    if [ "$phttp" = "200" ]; then
        _hdr() { sed -n "s/^[Aa]nthropic-ratelimit-unified-$1: *//p" "$HDR_FILE" 2>/dev/null \
                 | tr -d '\r' | head -1; }
        # Fraction -> clamped integer percent; awk fails (exit 1) on anything
        # non-numeric, which drops us into the backoff path below.
        _pct() { awk -v v="$1" 'BEGIN { if (v == "" || v + 0 != v) exit 1
                                        p = int(v * 100); if (p < 0) p = 0; if (p > 100) p = 100
                                        printf "%d", p }'; }
        h_fp=$(_pct "$(_hdr 5h-utilization)") && h_sp=$(_pct "$(_hdr 7d-utilization)") \
            && h_fr=$(_hdr 5h-reset) && h_sr=$(_hdr 7d-reset) || true
        cand="${h_fp:-}|${h_fr:-}|${h_sp:-}|${h_sr:-}"
        if [[ "$cand" =~ ^[0-9]{1,3}\|[0-9]{1,12}\|[0-9]{1,3}\|[0-9]{1,12}$ ]]; then
            NOW="${CC_STATUSLINE_NOW:-$(date +%s)}"
            [[ "$NOW" =~ ^[0-9]{1,12}$ ]] || exit 0
            if printf '%s|%s\n' "$cand" "$NOW" > "$TMP_FILE" 2>/dev/null; then
                chmod 600 "$TMP_FILE" 2>/dev/null || true
                if mv -f "$TMP_FILE" "$CACHE_FILE" 2>/dev/null; then
                    rm -f "$BACKOFF_FILE" 2>/dev/null || true
                fi
            fi
            rm -f "$BODY_FILE" "$HDR_FILE" 2>/dev/null || true
            trap - EXIT
            exit 0
        fi
    fi
    rm -f "$HDR_FILE" 2>/dev/null || true
fi
# An HTTP error with no usable fallback means the credential or the endpoint is
# refusing us: back off (the statusline then stops spawning fetches for a
# while) and leave the cache. A transport failure (empty status) is transient:
# no backoff, the spawner's own 60s gate is enough.
case "${http:-}" in
    200|"") : ;;
    *) touch "$BACKOFF_FILE" 2>/dev/null || true; exit 0 ;;
esac
[ -z "$data" ] && exit 0

# Parse + validate in one jq pass. Percentages are floored to ints and clamped
# to [0,100]; ISO resets_at convert to epoch (UTC forms only: fractional
# seconds stripped, +00:00 normalized to Z). Any missing/mistyped field or a
# non-UTC offset makes jq fail or emit nothing, and the cache stays untouched
# (fail closed, like the network path). An HTTP error body ({"error": ...})
# fails the same way since the fields are absent.
parsed=$(echo "$data" | jq -r '
    def iso2epoch: tostring | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601;
    def pct: numbers | floor | [., 0] | max | [., 100] | min;
    (.five_hour.utilization | pct) as $fp
  | (.seven_day.utilization | pct) as $sp
  | (.five_hour.resets_at | iso2epoch) as $fr
  | (.seven_day.resets_at | iso2epoch) as $sr
  | "\($fp)|\($fr)|\($sp)|\($sr)"
' 2>/dev/null) || exit 0
# Belt-and-braces shape check: exactly the 4-field format the statusline
# validates on read (3-digit pct cap, 12-digit epoch cap).
[[ "$parsed" =~ ^[0-9]{1,3}\|[0-9]{1,12}\|[0-9]{1,3}\|[0-9]{1,12}$ ]] || exit 0

NOW="${CC_STATUSLINE_NOW:-$(date +%s)}"
[[ "$NOW" =~ ^[0-9]{1,12}$ ]] || exit 0

if printf '%s|%s\n' "$parsed" "$NOW" > "$TMP_FILE" 2>/dev/null; then
    chmod 600 "$TMP_FILE" 2>/dev/null || true
    if mv -f "$TMP_FILE" "$CACHE_FILE" 2>/dev/null; then
        rm -f "$BACKOFF_FILE" 2>/dev/null || true  # recovered
    else
        rm -f "$TMP_FILE" 2>/dev/null || true
    fi
fi
rm -f "$BODY_FILE" 2>/dev/null || true
trap - EXIT
