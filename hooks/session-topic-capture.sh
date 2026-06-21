#!/usr/bin/env bash
# Session topic capture hook for Claude Code statusline v2
# Fires on UserPromptSubmit - calls Claude Haiku to generate a "Project: Focus" label
# Writes to ~/.claude/session-topics/{session_id}.txt
set -uo pipefail  # no -e: jq/security failures shouldn't crash silently

# Per-user runtime dir (mode 700) for the lock/counter files. Replaces the
# predictable, world-writable /tmp paths the hook used before (symlink /
# state-poison risk on multi-user hosts).
_state_dir() {
    local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    local uid d
    uid=$(id -u 2>/dev/null || echo 0)
    d="${base%/}/cc-statusline-${uid}"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    printf '%s' "$d"
}
# Single-sourced version for the User-Agent (cc-statusline/X.Y.Z). Reads the
# tracked VERSION file shipped next to the install; "dev" if absent.
_cc_version() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    { cat "$d/VERSION" "$d/../VERSION"; } 2>/dev/null | head -1
}
VERSION="$(_cc_version)"; VERSION="${VERSION:-dev}"

HOOK_DATA=$(cat)

SESSION_ID=$(echo "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0
# Validate to a safe charset before using it in any file path (path traversal).
case "$SESSION_ID" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

TOPIC_DIR="$HOME/.claude/session-topics"
TOPIC_FILE="${TOPIC_DIR}/${SESSION_ID}.txt"
STATE_DIR="$(_state_dir)"
LOCK_FILE="${STATE_DIR}/topic-${SESSION_ID}.lock"

# Get transcript path from hook data
TRANSCRIPT_PATH=$(echo "$HOOK_DATA" | jq -r '.transcript_path // empty' 2>/dev/null)

# Rate limit: only regenerate every 10 prompts or if no topic exists yet
COUNTER_FILE="${STATE_DIR}/topic-counter-${SESSION_ID}"
COUNT=0
if [ -f "$COUNTER_FILE" ]; then
    _raw=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)
    # Validate numeric to avoid arithmetic crash on corrupted file
    [[ "$_raw" =~ ^[0-9]+$ ]] && COUNT=$_raw || COUNT=0
fi
COUNT=$((COUNT + 1))
echo "$COUNT" > "$COUNTER_FILE"

# Generate on prompt 1, every 10 prompts, or if no topic file exists
if [ -f "$TOPIC_FILE" ] && [ "$COUNT" -ne 1 ] && [ $((COUNT % 10)) -ne 0 ]; then
    exit 0
fi

# Prevent concurrent generation
if [ -f "$LOCK_FILE" ]; then
    # Portable mtime: `date -r FILE +%s` works on both BSD and GNU.
    lock_mtime=$(date -r "$LOCK_FILE" +%s 2>/dev/null || echo 0)
    lock_age=$(($(date +%s) - lock_mtime))
    [ "$lock_age" -lt 30 ] && exit 0
fi
touch "$LOCK_FILE"

# Run in background so we don't block the prompt
(
    # Get OAuth token
    token=""
    creds=$(security find-generic-password -s "Claude Code-credentials" -w 2>/dev/null) && \
        token=$(echo "$creds" | jq -r '.claudeAiOauth.accessToken // empty' 2>/dev/null)
    if [ -z "$token" ]; then
        token=$(jq -r '.claudeAiOauth.accessToken // empty' "$HOME/.claude/.credentials.json" 2>/dev/null)
    fi
    [ -z "${token:-}" ] && { rm -f "$LOCK_FILE"; exit 0; }

    # Read transcript JSONL for context
    EXCERPT=""
    if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
        EXCERPT=$(tail -40 "$TRANSCRIPT_PATH" 2>/dev/null | \
            jq -r 'select(.type == "human" or .type == "assistant") |
                   if .type == "human" then "User: " + (.message // .content // "[prompt]" | tostring | .[0:200])
                   else "Assistant: " + (.message // .content // "[response]" | tostring | .[0:200])
                   end' 2>/dev/null | tail -20 | head -c 3000)
    fi

    # Fallback: use the prompt from hook data if transcript didn't yield anything
    if [ -z "$EXCERPT" ]; then
        PROMPT_TEXT=$(echo "$HOOK_DATA" | jq -r '.prompt // empty' 2>/dev/null)
        [ -n "$PROMPT_TEXT" ] && EXCERPT="User: ${PROMPT_TEXT:0:1000}"
    fi

    [ -z "$EXCERPT" ] && { rm -f "$LOCK_FILE"; exit 0; }

    # Get CWD for project context
    CWD=$(echo "$HOOK_DATA" | jq -r '.cwd // empty' 2>/dev/null)
    PROJECT_DIR=$(basename "${CWD:-unknown}")

    # Call Haiku for topic generation
    # Note: this endpoint accepts the user's Claude Code OAuth token via the
    # oauth-2025-04-20 beta header. We identify ourselves with our own UA.
    RESPONSE=$(curl -s --max-time 8 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "User-Agent: cc-statusline/${VERSION}" \
        https://api.anthropic.com/v1/messages \
        -d "$(jq -n --arg excerpt "$EXCERPT" --arg project "$PROJECT_DIR" '{
            model: "claude-haiku-4-5-20251001",
            max_tokens: 30,
            messages: [{
                role: "user",
                content: ("Summarize this coding session in exactly the format \"Project: Focus\" where Project is the project/repo name (use \"" + $project + "\" if unclear) and Focus is a 1-3 word description of what is being worked on. Reply with ONLY the label, nothing else.\n\nConversation:\n" + $excerpt)
            }]
        }')" 2>/dev/null)

    # Strip newlines AND any control bytes (ESC/BEL/...) so the on-disk topic
    # can never carry terminal escapes (defense in depth; the statusline also
    # sanitizes on read). Multibyte UTF-8 (bytes >= 0x80) is preserved.
    TOPIC=$(echo "$RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null | tr -d '\000-\037\177' | cut -c1-40)

    # Reject topics that look like JSON (Haiku sometimes mimics JSON from transcript)
    if [[ "$TOPIC" =~ ^\{ ]] || [[ "$TOPIC" =~ ^\[ ]]; then
        rm -f "$LOCK_FILE"
        exit 0
    fi

    if [ -n "$TOPIC" ]; then
        mkdir -p "$TOPIC_DIR"
        echo "$TOPIC" > "$TOPIC_FILE"
    fi

    rm -f "$LOCK_FILE"
) &
disown 2>/dev/null

exit 0
