#!/usr/bin/env bash
# Session topic capture hook for Claude Code statusline v2
# Fires on UserPromptSubmit - calls Claude Haiku to generate a "Project: Focus" label
# Writes to ~/.claude/session-topics/{session_id}.txt
set -uo pipefail  # no -e: jq/security failures shouldn't crash silently

HOOK_DATA=$(cat)

SESSION_ID=$(echo "$HOOK_DATA" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

TOPIC_DIR="$HOME/.claude/session-topics"
TOPIC_FILE="${TOPIC_DIR}/${SESSION_ID}.txt"
LOCK_FILE="/tmp/session-topic-${SESSION_ID}.lock"

# Get transcript path from hook data
TRANSCRIPT_PATH=$(echo "$HOOK_DATA" | jq -r '.transcript_path // empty' 2>/dev/null)

# Rate limit: only regenerate every 10 prompts or if no topic exists yet
COUNTER_FILE="/tmp/session-topic-counter-${SESSION_ID}"
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
    lock_age=$(($(date +%s) - $(stat -f %m "$LOCK_FILE" 2>/dev/null || echo 0)))
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
    RESPONSE=$(curl -s --max-time 8 \
        -H "Authorization: Bearer $token" \
        -H "anthropic-beta: oauth-2025-04-20" \
        -H "Content-Type: application/json" \
        -H "anthropic-version: 2023-06-01" \
        -H "User-Agent: claude-code/2.1.4" \
        https://api.anthropic.com/v1/messages \
        -d "$(jq -n --arg excerpt "$EXCERPT" --arg project "$PROJECT_DIR" '{
            model: "claude-haiku-4-5-20251001",
            max_tokens: 30,
            messages: [{
                role: "user",
                content: ("Summarize this coding session in exactly the format \"Project: Focus\" where Project is the project/repo name (use \"" + $project + "\" if unclear) and Focus is a 1-3 word description of what is being worked on. Reply with ONLY the label, nothing else.\n\nConversation:\n" + $excerpt)
            }]
        }')" 2>/dev/null)

    TOPIC=$(echo "$RESPONSE" | jq -r '.content[0].text // empty' 2>/dev/null | tr -d '\n' | cut -c1-40)

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
