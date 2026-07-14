#!/usr/bin/env bash
# cc-statusline service-status fetcher tests
#
# Drives claude-status-fetch.sh with crafted status.claude.com payloads (via the
# CC_STATUSLINE_SVC_DATA seam) and asserts the single cache line it writes. These
# guard the decision logic the statusline turns into an icon:
#   - the mythos/fable suspension filter (and that REAL model incidents survive)
#   - component severity ranking (major > partial > degraded)
#   - fail-closed behaviour on unparseable input / bad regex (no false "operational")
#   - injection safety: an attacker-controlled array field can never reach eval
#
# Run from anywhere; resolves the repo root from this script's location.
# Run under LC_ALL=C too (the harness Taskfile does), matching test-c-locale.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
FETCH="$REPO_DIR/claude-status-fetch.sh"

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-fetch-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0

# run_case NAME JSON EXPECTED
#   Writes JSON to a fixture, runs the fetcher against a fresh scratch cache, and
#   asserts the resulting cache line equals EXPECTED.
run_case() {
    local name="$1" json="$2" expected="$3"
    local data="$SCRATCH/data.json" cache="$SCRATCH/cache"
    printf '%s' "$json" > "$data"
    rm -f "$cache"
    CC_STATUSLINE_SVC_DATA="$data" CC_STATUSLINE_SVC_CACHE="$cache" bash "$FETCH"
    local got=""
    [ -f "$cache" ] && got=$(head -1 "$cache" 2>/dev/null)
    if [ "$got" = "$expected" ]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        want: [%s]\n        got:  [%s]\n' "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}

# run_untouched NAME JSON [ENV...] -- the cache is pre-seeded with a sentinel and
# must be left exactly as-is (network/parse/regex failures never clobber it).
run_untouched() {
    local name="$1" json="$2"; shift 2
    local data="$SCRATCH/data.json" cache="$SCRATCH/cache"
    local sentinel="degraded_performance:seeded:keep-me"
    printf '%s' "$json" > "$data"
    printf '%s\n' "$sentinel" > "$cache"
    env "$@" CC_STATUSLINE_SVC_DATA="$data" CC_STATUSLINE_SVC_CACHE="$cache" bash "$FETCH"
    local got; got=$(head -1 "$cache" 2>/dev/null)
    if [ "$got" = "$sentinel" ]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (cache was clobbered)\n        want: [%s]\n        got:  [%s]\n' "$name" "$sentinel" "$got"
        FAIL=$((FAIL + 1))
    fi
}

# Real live title, with the U+2019 curly apostrophe built from bytes (keeps the
# source ASCII-clean for shellcheck, and exercises a multibyte incident name).
SUSPEND="$(printf 'We\xe2\x80\x99ve suspended access to Claude Mythos 5 and Claude Fable 5')"

# ── Mythos/Fable suspension filter ─────────────────────────────────────────
run_case "mythos-only suspension, components clean -> operational" \
    "{\"status\":{\"indicator\":\"minor\",\"description\":\"Partially Degraded Service\"},\"incidents\":[{\"name\":\"$SUSPEND\"}],\"components\":[{\"name\":\"Claude API\",\"status\":\"operational\"}]}" \
    "operational"

run_case "suspension ignored but API genuinely degraded -> degraded shown" \
    "{\"status\":{\"indicator\":\"minor\",\"description\":\"Partially Degraded Service\"},\"incidents\":[{\"name\":\"$SUSPEND\"}],\"components\":[{\"name\":\"Claude API\",\"status\":\"degraded_performance\"}]}" \
    "degraded_performance:Partially Degraded Service:Claude API"

run_case "REAL fable incident is NOT ignored" \
    '{"status":{"indicator":"minor","description":"x"},"incidents":[{"name":"Elevated error rates on Fable 5"}],"components":[{"name":"Claude API","status":"operational"}]}' \
    "incident:Elevated error rates on Fable 5"

# ── Incident precedence / ordering ─────────────────────────────────────────
run_case "opus + suspension (live shape) -> opus incident" \
    "{\"status\":{\"indicator\":\"minor\",\"description\":\"x\"},\"incidents\":[{\"name\":\"Elevated error rates on Opus 4.8\"},{\"name\":\"$SUSPEND\"}],\"components\":[{\"name\":\"Claude API\",\"status\":\"degraded_performance\"}]}" \
    "incident:Elevated error rates on Opus 4.8"

run_case "suspension FIRST, opus second -> still opus (order-independent)" \
    "{\"status\":{\"indicator\":\"minor\",\"description\":\"x\"},\"incidents\":[{\"name\":\"$SUSPEND\"},{\"name\":\"Elevated error rates on Opus 4.8\"}],\"components\":[]}" \
    "incident:Elevated error rates on Opus 4.8"

# ── Severity ranking (worst non-operational component wins) ────────────────
run_case "all operational, no incidents -> operational" \
    '{"status":{"indicator":"none","description":"All Systems Operational"},"incidents":[],"components":[{"name":"Claude API","status":"operational"}]}' \
    "operational"

run_case "major beats partial beats degraded" \
    '{"status":{"indicator":"major","description":"Major Outage"},"incidents":[],"components":[{"name":"A","status":"degraded_performance"},{"name":"B","status":"major_outage"},{"name":"C","status":"partial_outage"}]}' \
    "major_outage:Major Outage:A, B, C"

# ── Fail-closed: never write a false "operational" ─────────────────────────
run_untouched "non-JSON error page leaves cache intact" \
    '<html><head><title>502 Bad Gateway</title></head></html>'

run_untouched "empty body leaves cache intact" \
    ''

run_untouched "invalid ignore regex leaves cache intact" \
    '{"status":{"description":"x"},"incidents":[{"name":"whatever"}],"components":[]}' \
    "CC_STATUSLINE_IGNORE_INCIDENTS=*nope("

run_untouched "array-typed incident name fails closed (test() throws)" \
    '{"status":{"description":"x"},"incidents":[{"name":["a","b"]}],"components":[]}'

# ── Injection safety: an array field must never execute via eval ───────────
inj_marker="$SCRATCH/PWNED"
rm -f "$inj_marker"
run_case "array description does not execute, written as one quoted token" \
    "{\"status\":{\"description\":[\"x\",\"touch\",\"$inj_marker\"]},\"incidents\":[],\"components\":[{\"name\":\"Claude API\",\"status\":\"degraded_performance\"}]}" \
    "degraded_performance:[\"x\",\"touch\",\"$inj_marker\"]:Claude API"
if [ -e "$inj_marker" ]; then
    printf '  FAIL  array description RCE: marker file was created!\n'; FAIL=$((FAIL + 1))
else
    printf '  PASS  array description did not execute a command\n'; PASS=$((PASS + 1))
fi

# ═══ Per-account usage fetcher (claude-usage-fetch.sh) ═════════════════════
# Drives the /api/oauth/usage fetcher through the CC_STATUSLINE_USAGE_DATA seam
# and asserts the 5-field authoritative cache line it writes. A dummy token is
# always piped on stdin so the fetcher never consults the real keychain, and
# CC_STATUSLINE_NOW pins the fetch stamp.
UFETCH="$REPO_DIR/claude-usage-fetch.sh"
UNOW=1700000000

# run_ucase NAME JSON EXPECTED
run_ucase() {
    local name="$1" json="$2" expected="$3"
    local data="$SCRATCH/udata.json" cache="$SCRATCH/ucache"
    printf '%s' "$json" > "$data"
    rm -f "$cache"
    printf 'dummy-token' | CC_STATUSLINE_USAGE_DATA="$data" \
        CC_STATUSLINE_RL_CACHE="$cache" CC_STATUSLINE_NOW="$UNOW" bash "$UFETCH"
    local got=""
    [ -f "$cache" ] && got=$(head -1 "$cache" 2>/dev/null)
    if [ "$got" = "$expected" ]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s\n        want: [%s]\n        got:  [%s]\n' "$name" "$expected" "$got"
        FAIL=$((FAIL + 1))
    fi
}
# run_uuntouched NAME JSON -- pre-seeded cache must survive a bad payload
run_uuntouched() {
    local name="$1" json="$2"
    local data="$SCRATCH/udata.json" cache="$SCRATCH/ucache"
    local sentinel="1|1700000001|2|1700000002|1699999999"
    printf '%s' "$json" > "$data"
    printf '%s\n' "$sentinel" > "$cache"
    printf 'dummy-token' | CC_STATUSLINE_USAGE_DATA="$data" \
        CC_STATUSLINE_RL_CACHE="$cache" CC_STATUSLINE_NOW="$UNOW" bash "$UFETCH"
    local got; got=$(head -1 "$cache" 2>/dev/null)
    if [ "$got" = "$sentinel" ]; then
        printf '  PASS  %s\n' "$name"; PASS=$((PASS + 1))
    else
        printf '  FAIL  %s (cache was clobbered)\n        want: [%s]\n        got:  [%s]\n' "$name" "$sentinel" "$got"
        FAIL=$((FAIL + 1))
    fi
}

# Live response shape as cached by Claude Code in ~/.claude.json
# .cachedUsageUtilization.utilization (fractional seconds + +00:00 offset).
# 2026-07-14T19:50:00Z = 1784058600, 2026-07-18T20:00:00Z = 1784404800.
run_ucase "live shape -> 5-field authoritative line" \
    '{"five_hour":{"utilization":18,"resets_at":"2026-07-14T19:50:00.280042+00:00"},"seven_day":{"utilization":83,"resets_at":"2026-07-18T20:00:00.280065+00:00"}}' \
    "18|1784058600|83|1784404800|$UNOW"

run_ucase "Z-suffixed resets and float utilization (floored)" \
    '{"five_hour":{"utilization":18.9,"resets_at":"2026-07-14T19:50:00Z"},"seven_day":{"utilization":0,"resets_at":"2026-07-18T20:00:00Z"}}' \
    "18|1784058600|0|1784404800|$UNOW"

run_ucase "out-of-range utilization clamped to 100" \
    '{"five_hour":{"utilization":999,"resets_at":"2026-07-14T19:50:00Z"},"seven_day":{"utilization":83,"resets_at":"2026-07-18T20:00:00Z"}}' \
    "100|1784058600|83|1784404800|$UNOW"

run_uuntouched "usage: non-JSON error page leaves cache intact" \
    '<html>502</html>'

run_uuntouched "usage: HTTP error body (fields absent) leaves cache intact" \
    '{"error":{"type":"authentication_error","message":"invalid bearer token"}}'

run_uuntouched "usage: string utilization fails closed" \
    '{"five_hour":{"utilization":"18","resets_at":"2026-07-14T19:50:00Z"},"seven_day":{"utilization":83,"resets_at":"2026-07-18T20:00:00Z"}}'

run_uuntouched "usage: non-UTC reset offset fails closed" \
    '{"five_hour":{"utilization":18,"resets_at":"2026-07-14T21:50:00+02:00"},"seven_day":{"utilization":83,"resets_at":"2026-07-18T20:00:00Z"}}'

echo "------------------------------------------------------------"
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
