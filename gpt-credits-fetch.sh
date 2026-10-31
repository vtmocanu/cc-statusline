#!/usr/bin/env bash
# Estimates GPT-5.6/6.1 Sol usage in published ChatGPT credits by streaming the
# current session transcript and its subagent transcripts. This is not billed
# dollars and does not imply credits were deducted while plan usage is included.
#
# Standard rates at https://learn.chatgpt.com/docs/pricing:
#   GPT-5.6 Sol: 100 input, 10 cached input, 500 output credits / 1M tokens.
#   GPT-6.1 Sol: 50 input, 2.5 cached input, 250 output credits / 1M tokens.
# Codex has no separate cache-write charge. Nonzero proxy cache-creation counts
# remain unsupported because their relationship to input tokens is unverified.
# GPT-6.1 speed modes apply 1x/2x/6x purchased-credit rates. Unknown speeds fail
# closed rather than substituting included-subscription usage multipliers.
#
# Cache line format:
#   ok|TOKEN_RATE_UNITS|FETCHED_EPOCH
#   unavailable||FETCHED_EPOCH
# TOKEN_RATE_UNITS is the integer numerator before division by 1,000,000.
#
# Test/runtime seams:
#   CC_STATUSLINE_GPT_TRANSCRIPT     main session transcript path
#   CC_STATUSLINE_GPT_CREDITS_CACHE destination cache file
#   CC_STATUSLINE_NOW                pinned fetch timestamp

set -uo pipefail

_state_dir() {
    local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    local uid d
    uid=$(id -u 2>/dev/null || echo 0)
    d="${base%/}/cc-statusline-${uid}"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    printf '%s' "$d"
}

TRANSCRIPT="${CC_STATUSLINE_GPT_TRANSCRIPT:-}"
[ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ] || exit 0
if [ -n "${CC_STATUSLINE_GPT_CREDITS_CACHE:-}" ]; then
    CACHE_FILE="$CC_STATUSLINE_GPT_CREDITS_CACHE"
else
    CACHE_KEY=$(printf '%s' "$TRANSCRIPT" | cksum | cut -d' ' -f1) || exit 0
    CACHE_FILE="$(_state_dir)/gpt-credits-$CACHE_KEY"
fi
TMP_FILE="${CACHE_FILE}.tmp.$$"
trap 'rm -f "$TMP_FILE" 2>/dev/null' EXIT

NOW="${CC_STATUSLINE_NOW:-$(date +%s)}"
[[ "$NOW" =~ ^[0-9]{1,12}$ ]] || exit 0

_publish() {
    local state="$1" units="$2"
    if printf '%s|%s|%s\n' "$state" "$units" "$NOW" >"$TMP_FILE" 2>/dev/null; then
        chmod 600 "$TMP_FILE" 2>/dev/null || true
        mv -f "$TMP_FILE" "$CACHE_FILE" 2>/dev/null || rm -f "$TMP_FILE" 2>/dev/null || true
    fi
}

files=("$TRANSCRIPT")
SUBAGENTS="${TRANSCRIPT%.jsonl}/subagents"
if [ -d "$SUBAGENTS" ]; then
    shopt -s nullglob
    for f in "$SUBAGENTS"/*.jsonl; do
        [ -f "$f" ] && files+=("$f")
    done
    shopt -u nullglob
fi

# jq parses the JSONL values one at a time, never as a slurped array. awk keeps
# one numeric total per response id, enough to replace an early zero/partial
# usage record with its larger final snapshot without double-counting it.
units=$(jq -r '
    def normalized_model:
        sub("\\[1m\\]$"; "")
        | sub("^claude-ocx-native--"; "")
        | sub("^clodex:openai-oauth:"; "")
        | sub("^anthropic-openai-oauth__"; "");
    def token_count:
        if type != "number" or . < 0 or floor != . or . > 1000000000000
        then error("invalid token count") else . end;

    select(.type == "assistant" and (.message | type) == "object")
    | .message as $message
    | ($message.model // "") as $raw_model
    | select(($raw_model | type) == "string")
    | ($raw_model | normalized_model) as $model
    | select($model == "gpt-5.6-sol" or $model == "gpt-6.1-sol")
    | (if $model == "gpt-6.1-sol" then [50, 2.5, 250] else [100, 10, 500] end) as $rates
    | (if $model != "gpt-6.1-sol" then 1
       elif ($message.usage.speed // "standard") == "standard" then 1
       elif $message.usage.speed == "fast" then 2
       elif $message.usage.speed == "ultrafast" then 6
       else error("unsupported speed") end) as $speed
    | if (($message.id | type) != "string"
          or ($message.id | test("^[A-Za-z0-9._:-]+$") | not))
      then error("invalid message id") else . end
    | if (($message.usage | type) != "object")
      then error("missing usage") else . end
    | $message.usage as $usage
    | [$message.id,
       ($usage.input_tokens | token_count),
       ($usage.cache_creation_input_tokens | token_count),
       ($usage.cache_read_input_tokens | token_count),
       ($usage.output_tokens | token_count),
       ($rates[0] * $speed), ($rates[1] * $speed), ($rates[2] * $speed)]
    | @tsv
' "${files[@]}" 2>/dev/null | awk -F '\t' '
    NF != 8 { bad=1; exit }
    $3 != 0 { bad=1; exit }
    {
        value=($2+$3)*$6+$4*$7+$5*$8
        if (!($1 in seen) || value > seen[$1]) {
            total += value - (($1 in seen) ? seen[$1] : 0)
            seen[$1]=value
        }
    }
    END {
        if (bad) exit 1
        printf "%.0f", total
    }
') || {
    _publish unavailable ""
    exit 0
}
[[ "$units" =~ ^[0-9]{1,18}$ ]] || {
    _publish unavailable ""
    exit 0
}
_publish ok "$units"
