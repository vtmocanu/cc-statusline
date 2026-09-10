#!/usr/bin/env bash
# Fetches ChatGPT/Codex plan usage through the official Codex app server and
# writes the normalized windows into the separate GPT rate-limit cache read by
# statusline.sh. No inference request is made: account/rateLimits/read is a
# read-only usage snapshot, and Codex owns OAuth storage and token refresh.
#
# Cache line format:
#   FIVE_PCT|FIVE_RESET|FIVE_DURATION_SECONDS|SEVEN_PCT|SEVEN_RESET|
#   SEVEN_DURATION_SECONDS|FETCHED_EPOCH
# Either window triple may be empty. Windows are classified by duration, never
# by primary/secondary position, and retain the exact reported duration for the
# pace projection. A failed read leaves the last good cache intact.
#
# Test seams:
#   CC_STATUSLINE_GPT_CACHE   destination cache file
#   CC_STATUSLINE_CODEX_DATA app-server response fixture (skips launching Codex)
#   CC_STATUSLINE_CODEX_BIN  Codex executable override
#   CC_STATUSLINE_NOW        pinned fetch timestamp

set -uo pipefail

_state_dir() {
    local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    local uid d
    uid=$(id -u 2>/dev/null || echo 0)
    d="${base%/}/cc-statusline-${uid}"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    printf '%s' "$d"
}

CACHE_FILE="${CC_STATUSLINE_GPT_CACHE:-$(_state_dir)/rate-limits-gpt}"
TMP_FILE="${CACHE_FILE}.fetch.$$"
BACKOFF_FILE="${CACHE_FILE}.backoff"
IO_DIR=""
CODEX_PID=""

_cleanup() {
    exec 3>&- 2>/dev/null || true
    exec 4<&- 2>/dev/null || true
    if [ -n "$CODEX_PID" ]; then
        kill "$CODEX_PID" 2>/dev/null || true
        wait "$CODEX_PID" 2>/dev/null || true
    fi
    [ -n "$IO_DIR" ] && rm -rf "$IO_DIR" 2>/dev/null || true
    rm -f "$TMP_FILE" 2>/dev/null || true
}
trap _cleanup EXIT
trap 'exit 0' HUP INT TERM

_fail() {
    touch "$BACKOFF_FILE" 2>/dev/null || true
    exit 0
}

if [ -n "${CC_STATUSLINE_CODEX_DATA:-}" ]; then
    data=$(cat "$CC_STATUSLINE_CODEX_DATA" 2>/dev/null) || _fail
else
    if [ -n "${CC_STATUSLINE_CODEX_BIN:-}" ]; then
        CODEX_BIN="$CC_STATUSLINE_CODEX_BIN"
    else
        CODEX_BIN=$(command -v codex 2>/dev/null || true)
    fi
    [ -n "$CODEX_BIN" ] && [ -x "$CODEX_BIN" ] || _fail

    IO_DIR=$(mktemp -d "$(_state_dir)/codex-usage.XXXXXX" 2>/dev/null) || _fail
    IN_FIFO="$IO_DIR/in"
    OUT_FIFO="$IO_DIR/out"
    mkfifo "$IN_FIFO" "$OUT_FIFO" 2>/dev/null || _fail

    "$CODEX_BIN" app-server <"$IN_FIFO" >"$OUT_FIFO" 2>/dev/null &
    CODEX_PID=$!
    exec 3>"$IN_FIFO" || _fail
    exec 4<"$OUT_FIFO" || _fail

    printf '%s\n' \
        '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"cc-statusline","version":"1"}}}' >&3 \
        || _fail

    data=""
    DEADLINE=$((SECONDS + 10))
    while [ "$SECONDS" -lt "$DEADLINE" ]; do
        REMAIN=$((DEADLINE - SECONDS))
        IFS= read -r -t "$REMAIN" line <&4 || break
        if printf '%s' "$line" | jq -e '.id == 1 and .result != null' >/dev/null 2>&1; then
            printf '%s\n' '{"method":"initialized"}' \
                '{"id":2,"method":"account/rateLimits/read"}' >&3 || _fail
        elif printf '%s' "$line" | jq -e '.id == 2' >/dev/null 2>&1; then
            data="$line"
            break
        fi
    done
    [ -n "$data" ] || _fail
fi

# Codex can return several metered buckets. The unlabelled/default GPT models use
# the `codex` bucket; named model buckets (for example Spark) must not replace it.
# Durations tolerate the same +/-5% range as Codex's own UI classification.
parsed=$(printf '%s' "$data" | jq -r '
    def pct:
        numbers | floor
        | if . < 0 then 0 elif . > 100 then 100 else . end;
    def reset:
        if . == null then ""
        elif type == "number" then (floor | tostring)
        else error("invalid reset") end;
    def by_duration($lo; $hi):
        map(select((.windowDurationMins | type) == "number"
                   and (.windowDurationMins | floor) == .windowDurationMins
                   and .windowDurationMins >= $lo
                   and .windowDurationMins <= $hi))
        | first // null;
    (.result.rateLimitsByLimitId.codex // .result.rateLimits // null) as $snapshot
    | if ($snapshot | type) != "object" then error("missing codex limits") else . end
    | [$snapshot.primary, $snapshot.secondary]
      | map(select(type == "object")) as $windows
    | ($windows | by_duration(285; 315)) as $five
    | ($windows | by_duration(9576; 10584)) as $seven
    | if $five == null and $seven == null then empty
      else
        (if $five == null then "" else ($five.usedPercent | pct | tostring) end) as $fp
      | (if $five == null then "" else ($five.resetsAt | reset) end) as $fr
      | (if $five == null then "" else ($five.windowDurationMins * 60 | tostring) end) as $fd
      | (if $seven == null then "" else ($seven.usedPercent | pct | tostring) end) as $sp
      | (if $seven == null then "" else ($seven.resetsAt | reset) end) as $sr
      | (if $seven == null then "" else ($seven.windowDurationMins * 60 | tostring) end) as $sd
      | "\($fp)|\($fr)|\($fd)|\($sp)|\($sr)|\($sd)"
      end
' 2>/dev/null) || _fail
[ -n "$parsed" ] || _fail

IFS='|' read -r FIVE_PCT FIVE_RESET FIVE_DURATION SEVEN_PCT SEVEN_RESET SEVEN_DURATION extra <<EOF
$parsed
EOF
[ -z "${extra:-}" ] || _fail
VALID=1
if [ -n "$FIVE_PCT" ]; then
    [[ "$FIVE_PCT" =~ ^[0-9]{1,3}$ ]] || VALID=0
    { [ -z "$FIVE_RESET" ] || [[ "$FIVE_RESET" =~ ^[0-9]{1,12}$ ]]; } || VALID=0
    if [[ "$FIVE_DURATION" =~ ^[0-9]{1,9}$ ]]; then
        [ "$FIVE_DURATION" -ge 17100 ] && [ "$FIVE_DURATION" -le 18900 ] 2>/dev/null || VALID=0
    else
        VALID=0
    fi
elif [ -n "$FIVE_RESET" ] || [ -n "$FIVE_DURATION" ]; then
    VALID=0
fi
if [ -n "$SEVEN_PCT" ]; then
    [[ "$SEVEN_PCT" =~ ^[0-9]{1,3}$ ]] || VALID=0
    { [ -z "$SEVEN_RESET" ] || [[ "$SEVEN_RESET" =~ ^[0-9]{1,12}$ ]]; } || VALID=0
    if [[ "$SEVEN_DURATION" =~ ^[0-9]{1,9}$ ]]; then
        [ "$SEVEN_DURATION" -ge 574560 ] && [ "$SEVEN_DURATION" -le 635040 ] 2>/dev/null || VALID=0
    else
        VALID=0
    fi
elif [ -n "$SEVEN_RESET" ] || [ -n "$SEVEN_DURATION" ]; then
    VALID=0
fi
{ [ "$VALID" = "1" ] && { [ -n "$FIVE_PCT" ] || [ -n "$SEVEN_PCT" ]; }; } || _fail

NOW="${CC_STATUSLINE_NOW:-$(date +%s)}"
[[ "$NOW" =~ ^[0-9]{1,12}$ ]] || _fail

if printf '%s|%s\n' "$parsed" "$NOW" >"$TMP_FILE" 2>/dev/null; then
    chmod 600 "$TMP_FILE" 2>/dev/null || true
    if mv -f "$TMP_FILE" "$CACHE_FILE" 2>/dev/null; then
        rm -f "$BACKOFF_FILE" 2>/dev/null || true
    fi
fi
