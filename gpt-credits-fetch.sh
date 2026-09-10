#!/usr/bin/env bash
# Estimates GPT-5.6 Sol usage in published ChatGPT credits by streaming the
# current session transcript and its subagent transcripts. This is not billed
# dollars and does not imply credits were deducted while plan usage is included.
#
# Rates verified 2026-09-10 at https://learn.chatgpt.com/docs/pricing:
#   100 credits / 1M input tokens
#    10 credits / 1M cached input tokens
#   500 credits / 1M output tokens
# The published ChatGPT table does not define cache-write pricing. If any
# recognized row reports nonzero cache_creation_input_tokens, the whole session
# estimate fails closed instead of importing unrelated API pricing or guessing.
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
    | select($model == "gpt-5.6-sol")
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
       ($usage.output_tokens | token_count)]
    | @tsv
' "${files[@]}" 2>/dev/null | awk -F '\t' '
    NF != 5 { bad=1; exit }
    $3 != 0 { bad=1; exit }
    {
        value=($2+$3)*100+$4*10+$5*500
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
