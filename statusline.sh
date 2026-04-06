#!/usr/bin/env bash
set -uo pipefail  # no -e: external commands (git, kubectl, jq) can fail; silent crash = no statusline
trap 'printf "\n"' EXIT  # ensure at least empty output on crash
[ "${STATUSLINE_DEBUG:-}" = "1" ] && exec 2>/tmp/statusline-debug.log

# ── Portable helpers (BSD/macOS vs GNU/Linux) ───────────────────────────────
# File mtime as Unix epoch. `date -r FILE +%s` works on both BSD and GNU.
# Returns 0 on missing file or error.
_file_mtime() {
    date -r "$1" +%s 2>/dev/null || echo 0
}
# Reverse a file's lines: BSD has `tail -r`, GNU has `tac`. Fall back to cat.
_reverse_file() {
    tac "$1" 2>/dev/null \
        || tail -r "$1" 2>/dev/null \
        || cat "$1" 2>/dev/null
}

DATA=$(timeout 2 cat 2>/dev/null) || DATA=""
[ -z "$DATA" ] && exit 0

# ── Extract ALL fields in a single jq call ──────────────────────────────────
# Uses jq @sh to produce shell-safe quoted assignments. No IFS tricks needed;
# empty fields become VAR='' instead of being silently swallowed.
eval "$(echo "$DATA" | jq -r '
    @sh "MODEL=\(.model.display_name // "Claude" | gsub(" \\(.*\\)"; ""))",
    @sh "MODEL_ID=\(try (.model.id // "unknown") catch "unknown")",
    @sh "DIR=\(.cwd // "~" | split("/") | .[-2:] | join("/"))",
    @sh "PCT=\(try (
        if (.context_window.remaining_percentage // null) != null then
            100 - (.context_window.remaining_percentage | floor)
        elif (.context_window.context_window_size // 0) > 0 then
            (((.context_window.current_usage.input_tokens // 0) +
              (.context_window.current_usage.cache_creation_input_tokens // 0) +
              (.context_window.current_usage.cache_read_input_tokens // 0)) * 100 /
             .context_window.context_window_size) | floor
        else 0 end
    ) catch 0)",
    @sh "CTX_SIZE=\(.context_window.context_window_size // 200000)",
    @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
    @sh "AGENT=\(.agent.name // "")",
    @sh "MODE=\(.mode // "")",
    @sh "TRANSCRIPT_PATH=\(.transcript_path // "")",
    @sh "CWD_FULL=\(.cwd // "~")",
    @sh "SESSION_ID=\(.session_id // "")",
    @sh "FIVE_PCT=\(.rate_limits.five_hour.used_percentage // "")",
    @sh "SEVEN_PCT=\(.rate_limits.seven_day.used_percentage // "")",
    @sh "FIVE_RESET_TS=\(.rate_limits.five_hour.resets_at // "")",
    @sh "SEVEN_RESET_TS=\(.rate_limits.seven_day.resets_at // "")"
' 2>/dev/null)" 2>/dev/null

# Guard: if jq failed completely, use safe defaults
MODEL=${MODEL:-Claude}; MODEL_ID=${MODEL_ID:-unknown}; DIR=${DIR:-~}
PCT=${PCT:-0}; CTX_SIZE=${CTX_SIZE:-200000}; DURATION_MS=${DURATION_MS:-0}
AGENT=${AGENT:-}; MODE=${MODE:-}; TRANSCRIPT_PATH=${TRANSCRIPT_PATH:-}
CWD_FULL=${CWD_FULL:-~}; SESSION_ID=${SESSION_ID:-}
FIVE_PCT=${FIVE_PCT:-}; SEVEN_PCT=${SEVEN_PCT:-}
FIVE_RESET_TS=${FIVE_RESET_TS:-}; SEVEN_RESET_TS=${SEVEN_RESET_TS:-}

PCT=${PCT%%.*}  # truncate jq float rounding (e.g. 14.000000000000002 -> 14)
FIVE_PCT=${FIVE_PCT%%.*}   # also truncate rate limit floats
SEVEN_PCT=${SEVEN_PCT%%.*}
CTX_SIZE_K=$((CTX_SIZE / 1000))
# Max line width before Claude Code's cli-truncate drops line 2
SAFE_WIDTH=${STATUSLINE_WIDTH:-110}

TOPIC=""  # populated after SESSION_ID is extracted below

# ── Effort level detection (transcript -> settings -> default) ──────────────
EFFORT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Read from end of file for speed on large transcripts
    EFFORT=$(_reverse_file "$TRANSCRIPT_PATH" \
        | grep -m1 -E '"content":"<local-command-stdout>(Set model to.*effort|Set effort level to)' \
        | grep -oE '\b(low|medium|high|max)\b' | tail -1 || true)
fi
if [ -z "$EFFORT" ]; then
    EFFORT=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
fi
EFFORT=${EFFORT:-medium}

# ── Nerd Font icons ───────────────────────────────────────────────────────
NF_GIT=$'\xee\x82\xa0'       # U+E0A0 powerline branch
NF_FOLDER="󰉋"               # nf-md-folder (kept from v1)
NF_MODEL="󰚩"                # nf-md-robot (kept from v1)
NF_K8S="󱃾"                  # nf-md-kubernetes (kept from v1)
NF_CLOCK=$'\xef\x80\x97'     # U+F017 clock
NF_CORNER_TL=$'\xee\x82\xba'    # U+E0BA lower-right fill (top-left corner)
NF_CORNER_BL=$'\xee\x82\xbe'    # U+E0BE upper-right fill (bottom-left corner)
NF_CORNER_TR=$'\xee\x82\xb8'    # U+E0B8 lower-left fill -> top-right corner cut
NF_CORNER_BR=$'\xee\x82\xbc'    # U+E0BC upper-left fill -> bottom-right corner cut

# ── Project-colored background (hash session ID -> unique hue) ────────────
RST="\033[0m"
PROJECT_ROOT=$(git -C "$CWD_FULL" rev-parse --show-toplevel 2>/dev/null || echo "$CWD_FULL")
PHASH=$(printf '%s' "${SESSION_ID:-$CWD_FULL}" | cksum | cut -d' ' -f1 || echo "0")

# ── Session topic ─────────────────────────────────────────────────────────
if [ -n "${SESSION_ID:-}" ]; then
    TOPIC_FILE="$HOME/.claude/session-topics/${SESSION_ID}.txt"
    if [ -f "$TOPIC_FILE" ]; then
        # Strip ANSI escape sequences and limit to 40 chars
        TOPIC=$(cat "$TOPIC_FILE" 2>/dev/null | tr -d '\n' | gsed 's/\x1b\[[0-9;]*m//g' 2>/dev/null | cut -c1-40)
    fi
fi

# Check for manual color override
COLOR_OVERRIDES="$HOME/.claude/statusline-color-overrides.json"
if [ -f "$COLOR_OVERRIDES" ]; then
    COLOR_IDX=$(jq -r --arg p "$PROJECT_ROOT" '.[$p] // empty' "$COLOR_OVERRIDES" 2>/dev/null || true)
fi
COLOR_IDX=${COLOR_IDX:-$((PHASH % 12))}

case $COLOR_IDX in
    0)  BG_R=105; BG_G=145; BG_B=225 ;;  # blue
    1)  BG_R=130; BG_G=190; BG_B=130 ;;  # green
    2)  BG_R=190; BG_G=130; BG_B=175 ;;  # pink
    3)  BG_R=200; BG_G=170; BG_B=100 ;;  # amber
    4)  BG_R=100; BG_G=185; BG_B=185 ;;  # teal
    5)  BG_R=175; BG_G=130; BG_B=190 ;;  # purple
    6)  BG_R=110; BG_G=170; BG_B=210 ;;  # sky
    7)  BG_R=180; BG_G=190; BG_B=110 ;;  # olive
    8)  BG_R=200; BG_G=140; BG_B=130 ;;  # coral
    9)  BG_R=130; BG_G=170; BG_B=180 ;;  # steel
    10) BG_R=190; BG_G=175; BG_B=120 ;;  # khaki
    11) BG_R=160; BG_G=130; BG_B=190 ;;  # violet
    *)  BG_R=105; BG_G=145; BG_B=225 ;;  # fallback: blue
esac

# Line 1 colors (derived from project palette)
SEP_R=$((BG_R * 40 / 100)); SEP_G=$((BG_G * 40 / 100)); SEP_B=$((BG_B * 40 / 100))
TXT_R=$((BG_R * 15 / 100)); TXT_G=$((BG_G * 15 / 100)); TXT_B=$((BG_B * 15 / 100))

BG1="\033[48;2;${BG_R};${BG_G};${BG_B}m"
B="${RST}${BG1}"
SEP="\033[38;2;${SEP_R};${SEP_G};${SEP_B}m│"
TXT_FG="\033[38;2;${TXT_R};${TXT_G};${TXT_B}m"
TXT_BOLD="\033[38;2;${TXT_R};${TXT_G};${TXT_B};1m"
PROJ_FG="\033[38;2;${BG_R};${BG_G};${BG_B}m"

# ── Line 2 colors (black fill, light gray text, colored % numbers) ──────────
BG2="\033[48;2;0;0;0m"
B2="${RST}${BG2}"
L2_TXT="\033[38;2;170;170;170m"   # light gray
L2_DIM="\033[38;2;80;80;80m"      # dim gray for separators + resets

pct_txt_color() {
    local p=${1:-0}
    p=${p%%.*}  # safety: strip decimal if any
    if   [ "${p:-0}" -gt 80 ] 2>/dev/null; then printf "\033[38;2;225;150;150m"   # coral
    elif [ "${p:-0}" -gt 50 ] 2>/dev/null; then printf "\033[38;2;215;195;125m"   # gold
    else                                         printf "\033[38;2;150;210;150m"   # sage
    fi
}

# ── Git info ────────────────────────────────────────────────────────────────
BRANCH=$(git -c core.useBuiltinFSMonitor=false branch --show-current 2>/dev/null || echo "")
GIT_STATUS=""
if [ -n "$BRANCH" ]; then
  STAGED=$(git diff --cached --numstat 2>/dev/null | wc -l | tr -d " ")
  MODIFIED=$(git diff --numstat 2>/dev/null | wc -l | tr -d " ")
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d " ")
  [ "${STAGED:-0}" -gt 0 ]    && GIT_STATUS="+${STAGED}"
  [ "${MODIFIED:-0}" -gt 0 ]  && GIT_STATUS="${GIT_STATUS:+$GIT_STATUS }!${MODIFIED}"
  [ "${UNTRACKED:-0}" -gt 0 ] && GIT_STATUS="${GIT_STATUS:+$GIT_STATUS }?${UNTRACKED}"
fi

# ── Kubernetes context (with timeout to avoid exec-auth hangs) ──────────────
K8S_CTX=$(timeout 2 kubectl config current-context 2>/dev/null || echo "")

# ── Session duration ────────────────────────────────────────────────────────
TOTAL_SEC=$((DURATION_MS / 1000))
H=$((TOTAL_SEC / 3600))
M=$(((TOTAL_SEC % 3600) / 60))
S=$((TOTAL_SEC % 60))
if   [ "$H" -gt 0 ]; then TIME="${H}h${M}m"
elif [ "$M" -gt 0 ]; then TIME="${M}m${S}s"
else TIME="${S}s"
fi

# Color-code elapsed time
if   [ "$H" -gt 2 ]; then TIME_CLR="\033[38;2;225;150;150m"   # coral: 3h+
elif [ "$H" -gt 0 ]; then TIME_CLR="\033[38;2;215;195;125m"   # gold: 1-3h
else                      TIME_CLR="\033[38;2;150;210;150m"   # sage: <1h
fi

# ── Bar builder ─────────────────────────────────────────────────────────────
make_bar() {
    local pct=${1:-0} width=${2:-5} fill_clr="$3" empty_clr="$4" bar=""
    pct=${pct%%.*}  # safety: strip decimal
    [ -z "$pct" ] && pct=0
    local filled=$((pct * width / 100))
    [ "$pct" -gt 0 ] 2>/dev/null && [ "$filled" -eq 0 ] && filled=1
    [ "$filled" -gt "$width" ] && filled=$width
    [ "$filled" -lt 0 ] && filled=0
    local empty=$((width - filled))
    for ((i=0; i<filled; i++)); do bar+="${fill_clr}▰"; done
    for ((i=0; i<empty; i++));  do bar+="${empty_clr}▱"; done
    printf "%b" "$bar"
}

# ── Rate limit reset formatter (takes Unix epoch) ─────────────────────────
# Output is capped to keep line 2 width predictable: anything more than 99
# days into the future is clamped to "99d+" so a malformed/test epoch can't
# blow up the layout.
format_reset() {
    local epoch="$1"
    [ -z "$epoch" ] || [ "$epoch" = "null" ] || [ "$epoch" = "0" ] && return
    local now diff
    now=$(date +%s)
    diff=$((epoch - now))
    [ "$diff" -le 0 ] && { printf "now"; return; }
    [ "$diff" -lt 60 ] && { printf "<1m"; return; }
    local d=$((diff / 86400)) h=$(((diff % 86400) / 3600)) m=$(((diff % 3600) / 60))
    if   [ "$d" -gt 99 ]; then printf "99d+"
    elif [ "$d" -gt 0 ];  then printf "%dd%dh" "$d" "$h"
    elif [ "$h" -gt 0 ];  then printf "%dh%dm" "$h" "$m"
    else printf "%dm" "$m"
    fi
}

# ── Count visible columns (ANSI-aware, multi-string in one perl call) ──────
# Usage: measure_cols "str1" "str2" ... -> outputs one number per line
measure_cols() {
    local args=()
    for s in "$@"; do args+=("$(printf '%b' "$s")"); done
    printf '%s\n' "${args[@]}" | perl -ne '
        s/\e\[[0-9;]*m//g;
        chomp;
        use Encode qw(decode);
        my $decoded = decode("UTF-8", $_, Encode::FB_DEFAULT);
        print length($decoded), "\n";
    ' 2>/dev/null
}

# ── Line 1: build with bash-based width tracking (no perl) ─────────────────
# Estimate visible width per component from known text lengths.
# Each component's ANSI overhead cancels out; we just count visible chars.
# Corner char = 1, each separator "│" = 1, icon = 1-2, spaces counted explicitly.
# Add 3-char safety margin for Nerd Font icons that render wider than 1 codepoint.
L1_EST=5  # corner char(1) + trailing space(1) + icon safety margin(3)

[ -n "$TOPIC" ] && L1_EST=$((L1_EST + 1 + ${#TOPIC} + 3))   # " TOPIC │"
L1_EST=$((L1_EST + 1 + 2 + ${#DIR} + 1))                     # " icon DIR "
if [ -n "$BRANCH" ]; then
    L1_EST=$((L1_EST + 1 + 1 + 2 + ${#BRANCH}))              # "│ icon BRANCH"
    [ -n "$GIT_STATUS" ] && L1_EST=$((L1_EST + 1 + ${#GIT_STATUS}))
fi
[ -n "$AGENT" ] && L1_EST=$((L1_EST + 1 + ${#AGENT}))
[ -n "$MODE" ]  && L1_EST=$((L1_EST + 3 + ${#MODE}))         # " │ MODE"
[ -n "$K8S_CTX" ] && L1_EST=$((L1_EST + 1 + 1 + 2 + ${#K8S_CTX}))  # " │ icon K8S"

# Truncate if over SAFE_WIDTH (order: K8S > BRANCH > TOPIC)
if [ "$L1_EST" -gt "$SAFE_WIDTH" ] && [ -n "$K8S_CTX" ]; then
    OVER=$((L1_EST - SAFE_WIDTH))
    K8S_MAX=$((${#K8S_CTX} - OVER - 2))
    if [ "$K8S_MAX" -gt 5 ]; then
        K8S_CTX="${K8S_CTX:0:$K8S_MAX}.."
    else
        K8S_CTX=""
    fi
    # Recalculate
    L1_EST=2; [ -n "$TOPIC" ] && L1_EST=$((L1_EST + 1 + ${#TOPIC} + 3))
    L1_EST=$((L1_EST + 1 + 2 + ${#DIR} + 1))
    [ -n "$BRANCH" ] && { L1_EST=$((L1_EST + 1 + 1 + 2 + ${#BRANCH})); [ -n "$GIT_STATUS" ] && L1_EST=$((L1_EST + 1 + ${#GIT_STATUS})); }
    [ -n "$AGENT" ] && L1_EST=$((L1_EST + 1 + ${#AGENT}))
    [ -n "$MODE" ]  && L1_EST=$((L1_EST + 3 + ${#MODE}))
    [ -n "$K8S_CTX" ] && L1_EST=$((L1_EST + 1 + 1 + 2 + ${#K8S_CTX}))
fi

if [ "$L1_EST" -gt "$SAFE_WIDTH" ] && [ -n "$BRANCH" ]; then
    OVER=$((L1_EST - SAFE_WIDTH))
    BR_MAX=$((${#BRANCH} - OVER - 2))
    if [ "$BR_MAX" -gt 5 ]; then
        BRANCH="${BRANCH:0:$BR_MAX}.."
    else
        BRANCH="${BRANCH:0:8}.."
    fi
    # No need to recalculate again; next truncation target (TOPIC) is rare
fi

if [ "$L1_EST" -gt "$SAFE_WIDTH" ] && [ -n "$TOPIC" ]; then
    # Recalculate after branch truncation
    L1_EST=2; [ -n "$TOPIC" ] && L1_EST=$((L1_EST + 1 + ${#TOPIC} + 3))
    L1_EST=$((L1_EST + 1 + 2 + ${#DIR} + 1))
    [ -n "$BRANCH" ] && { L1_EST=$((L1_EST + 1 + 1 + 2 + ${#BRANCH})); [ -n "$GIT_STATUS" ] && L1_EST=$((L1_EST + 1 + ${#GIT_STATUS})); }
    [ -n "$AGENT" ] && L1_EST=$((L1_EST + 1 + ${#AGENT}))
    [ -n "$MODE" ]  && L1_EST=$((L1_EST + 3 + ${#MODE}))
    [ -n "$K8S_CTX" ] && L1_EST=$((L1_EST + 1 + 1 + 2 + ${#K8S_CTX}))
    if [ "$L1_EST" -gt "$SAFE_WIDTH" ]; then
        OVER=$((L1_EST - SAFE_WIDTH))
        T_MAX=$((${#TOPIC} - OVER - 2))
        if [ "$T_MAX" -gt 5 ]; then
            TOPIC="${TOPIC:0:$T_MAX}.."
        else
            TOPIC=""
        fi
    fi
fi

# Assemble Line 1 from (possibly truncated) components
L1_PREFIX="${RST}${PROJ_FG}${NF_CORNER_TL}${BG1}"
L1C="${L1_PREFIX}"
[ -n "$TOPIC" ] && L1C+=" ${TXT_BOLD}${TOPIC}${B} ${SEP}${B}"
L1C+=" ${TXT_FG}${NF_FOLDER} ${DIR} ${B}"
if [ -n "$BRANCH" ]; then
    L1C+="${SEP}${B} ${TXT_FG}${NF_GIT} ${BRANCH}${B}"
    [ -n "$GIT_STATUS" ] && L1C+=" ${TXT_FG}${GIT_STATUS}${B}"
fi
[ -n "$AGENT" ] && L1C+=" ${TXT_FG}${AGENT}${B}"
[ -n "$MODE" ]  && L1C+=" ${SEP}${B} \033[1;38;2;150;100;0m${MODE}${B}"
[ -n "$K8S_CTX" ] && L1C+=" ${SEP}${B} ${TXT_FG}${NF_K8S} ${K8S_CTX}${B}"
L1C+=" "

# ── Line 2 content ──────────────────────────────────────────────────────────
CTX_CLR=$(pct_txt_color "$PCT")
CTX_BAR=$(make_bar "$PCT" 7 "$CTX_CLR" "$L2_DIM")
# Effort level color
case $EFFORT in
    max)    EFFORT_CLR="\033[38;2;150;210;150m" ;;  # sage
    high)   EFFORT_CLR="\033[38;2;150;210;150m" ;;  # sage
    medium) EFFORT_CLR="\033[38;2;170;170;170m" ;;  # gray (blends in)
    low)    EFFORT_CLR="\033[38;2;225;150;150m" ;;  # coral (warning)
    *)      EFFORT_CLR="\033[38;2;170;170;170m" ;;  # fallback: gray
esac

L2C="${RST}\033[38;2;0;0;0m${NF_CORNER_BL}${BG2} ${L2_TXT}${NF_MODEL} ${MODEL} ${L2_DIM}·${B2} ${EFFORT_CLR}${EFFORT}${B2} ${L2_DIM}│${B2} ${L2_TXT}${NF_CLOCK} ${TIME_CLR}${TIME}${B2} ${L2_DIM}│${B2} ${CTX_BAR} ${CTX_CLR}${PCT}%${B2} ${L2_TXT}of ${CTX_SIZE_K}k"

# Estimate L2 base width with bash (same approach as L1: count visible chars)
# Model + effort + separator + clock + time + separator + bar(7) + pct + "of Xk"
L2_BASE_W=$((2 + 2 + ${#MODEL} + 1 + ${#EFFORT} + 3 + 2 + ${#TIME} + 3 + 7 + 1 + ${#PCT} + 1 + 4 + ${#CTX_SIZE_K} + 1))
L2_BASE_W=${L2_BASE_W:-50}
RATE_AVAIL=$((SAFE_WIDTH - L2_BASE_W - 5))   # reserve 5 for incident icon

if [ -n "${FIVE_PCT:-}" ] && [ -n "${SEVEN_PCT:-}" ]; then
    FIVE_CLR=$(pct_txt_color "$FIVE_PCT")
    SEVEN_CLR=$(pct_txt_color "$SEVEN_PCT")

    if [ "$RATE_AVAIL" -gt 40 ] 2>/dev/null; then
        # Full: bars + pct + reset times
        FIVE_BAR=$(make_bar "$FIVE_PCT" 5 "$FIVE_CLR" "$L2_DIM")
        FIVE_TIME=$(format_reset "$FIVE_RESET_TS")
        L2C+=" ${L2_DIM}│${B2} ${L2_TXT}5h ${FIVE_BAR} ${FIVE_CLR}${FIVE_PCT}%${B2}"
        [ -n "${FIVE_TIME:-}" ] && L2C+=" ${L2_DIM}${FIVE_TIME}${B2}"
        SEVEN_BAR=$(make_bar "$SEVEN_PCT" 5 "$SEVEN_CLR" "$L2_DIM")
        SEVEN_TIME=$(format_reset "$SEVEN_RESET_TS")
        L2C+=" ${L2_DIM}│${B2} ${L2_TXT}7d ${SEVEN_BAR} ${SEVEN_CLR}${SEVEN_PCT}%${B2}"
        [ -n "${SEVEN_TIME:-}" ] && L2C+=" ${L2_DIM}${SEVEN_TIME}${B2}"
    elif [ "$RATE_AVAIL" -gt 25 ] 2>/dev/null; then
        # Compact: bars + pct, no reset times
        FIVE_BAR=$(make_bar "$FIVE_PCT" 5 "$FIVE_CLR" "$L2_DIM")
        L2C+=" ${L2_DIM}│${B2} ${L2_TXT}5h ${FIVE_BAR} ${FIVE_CLR}${FIVE_PCT}%${B2}"
        SEVEN_BAR=$(make_bar "$SEVEN_PCT" 5 "$SEVEN_CLR" "$L2_DIM")
        L2C+=" ${L2_DIM}│${B2} ${L2_TXT}7d ${SEVEN_BAR} ${SEVEN_CLR}${SEVEN_PCT}%${B2}"
    elif [ "$RATE_AVAIL" -gt 15 ] 2>/dev/null; then
        # Minimal: just percentages
        L2C+=" ${L2_DIM}│${B2} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${B2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${B2}"
    fi
fi

# ── Claude service status (auto-refresh every 60s in background) ────────────
# Both paths are env-overridable so tests can isolate themselves from a
# real cache file or disable the background fetcher entirely.
SVC_CACHE="${CC_STATUSLINE_SVC_CACHE:-/tmp/claude-service-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SVC_FETCH="${CC_STATUSLINE_SVC_FETCH:-${SCRIPT_DIR:-$HOME/.local/share/cc-statusline}/claude-status-fetch.sh}"
if [ -x "$SVC_FETCH" ]; then
    SVC_AGE=9999
    [ -f "$SVC_CACHE" ] && SVC_AGE=$(($(date +%s) - $(_file_mtime "$SVC_CACHE")))
    if [ "$SVC_AGE" -ge 60 ]; then
        ("$SVC_FETCH" >/dev/null 2>/dev/null &)
    fi
fi
if [ -f "$SVC_CACHE" ]; then
    SVC_RAW=$(head -1 "$SVC_CACHE" 2>/dev/null)
    case "${SVC_RAW:-}" in
        operational)
            L2C+=" ${L2_DIM}│${B2} \033[38;2;100;200;120m✓${B2}"
            ;;
        incident:*)
            L2C+=" ${L2_DIM}│${B2} \033[38;2;225;150;100m⚠${B2}"
            ;;
        degraded_performance:*)
            L2C+=" ${L2_DIM}│${B2} \033[38;2;215;195;125m~${B2}"
            ;;
        partial_outage:*|major_outage:*)
            L2C+=" ${L2_DIM}│${B2} \033[38;2;225;100;100m✗${B2}"
            ;;
    esac
fi

L2C+=" "

# ── Set terminal tab title ───────────────────────────────────────────────────
# Wrap in a brace block so 2>/dev/null catches the redirection-setup error
# (e.g. "/dev/tty: Device not configured" in non-tty contexts), not just
# printf's own stderr.
_TAB_TITLE="${TOPIC:-${DIR:-Claude}}"
{ printf '\033]1;%s\007' "$_TAB_TITLE" > /dev/tty; } 2>/dev/null || true

# ── Pad shorter line to match longer ────────────────────────────────────────
{
    # Single perl invocation for both line measurements
    read -r L1_COLS L2_COLS < <(
        measure_cols "$L1C" "$L2C" | tr '\n' ' '
    )
    L1_COLS=${L1_COLS:-0}; L2_COLS=${L2_COLS:-0}
    SYNC_W=$L2_COLS
    [ "$L1_COLS" -gt "$SYNC_W" ] 2>/dev/null && SYNC_W=$L1_COLS
    if [ "$L1_COLS" -gt 10 ] 2>/dev/null && [ "$L1_COLS" -lt "$SYNC_W" ] 2>/dev/null; then
        L1C+="${BG1}$(printf '%*s' "$((SYNC_W - L1_COLS))" '')"
    fi
    if [ "$L2_COLS" -gt 10 ] 2>/dev/null && [ "$L2_COLS" -lt "$SYNC_W" ] 2>/dev/null; then
        L2C+="${BG2}$(printf '%*s' "$((SYNC_W - L2_COLS))" '')"
    fi
} 2>/dev/null || true

# ── Output ───────────────────────────────────────────────────────────────────
L2_END_FG="\033[38;2;0;0;0m"
trap - EXIT  # disarm crash trap before normal output
printf '\033[0m%b\n' "${L1C}${RST}${PROJ_FG}${NF_CORNER_TR}${RST}"
printf '\033[0m%b\n' "${L2C}${RST}${L2_END_FG}${NF_CORNER_BR}${RST}"
