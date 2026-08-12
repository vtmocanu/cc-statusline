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
# Strip ANSI/OSC/control sequences AND bare control bytes from untrusted text
# (the session topic comes from a model response on disk; a crafted value must
# not be able to move the cursor, clear the screen, or spoof the tab title when
# we print it). Byte-oriented: only deletes C0 controls + DEL + ESC-introduced
# sequences, never multibyte UTF-8 (those bytes are all >= 0x80).
_strip_ctl() {
    perl -pe '
        s/\e\][^\a\e]*(?:\a|\e\\)//g;     # OSC ... (BEL or ST)
        s/\eP.*?\e\\//g;                  # DCS ... ST
        s/\e\[[0-9;?]*[ -\/]*[@-~]//g;    # CSI ... final (includes SGR colors)
        s/\e[@-Z\\-_]//g;                 # other 2-byte ESC sequences
        s/[\x00-\x1f\x7f]//g;             # residual C0 controls + DEL (BEL, ESC, ...)
    ' 2>/dev/null
}
# Per-user runtime dir (mode 700) for cache/lock/counter files. Replaces the
# old predictable, world-writable /tmp paths (symlink / cache-poison risk on
# multi-user hosts). XDG_RUNTIME_DIR (Linux) and TMPDIR (macOS) are already
# per-user mode-700; the bare /tmp fallback gets a uid-scoped subdir.
_state_dir() {
    local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    local uid d
    uid=$(id -u 2>/dev/null || echo 0)
    d="${base%/}/cc-statusline-${uid}"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    printf '%s' "$d"
}

# Charset gate for every value that reaches bash arithmetic, wherever it comes
# from. Bash evaluates a variable's VALUE as an arithmetic expression and
# performs command substitution inside array subscripts while doing so, so an
# unvalidated value in $(( )) is arbitrary command execution:
#   STATUSLINE_WIDTH='PCT[$(touch /tmp/PWN)]'  -> touch runs, render looks normal
# A non-numeric value is just as bad the other way: it aborts the arithmetic
# under `set -u` and the statusline vanishes entirely. This lives up here with
# the other helpers because both the stdin JSON (parsed below) and the env
# inputs (read further down) need it.
_gate_int() {   # _gate_int <value> <default> -> a decimal integer, always
    case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$((10#$1))" ;; esac
}

# ── Codepoint-aware length and slicing for the truncation math ─────────────
# Bash's ${#s} and ${s: -n} count BYTES whenever the locale is not UTF-8 (the
# LC_ALL=C the second test-suite run uses, and any user whose environment lands
# there), while measure_cols counts CODEPOINTS. A truncation step that computes
# its budget in bytes and its result in codepoints sheds about a third of what
# it thinks it does on a 3-byte-per-character name, so the ladder terminates
# believing it converged and the line still overflows: measured under LC_ALL=C,
# a Japanese directory name at a 20-column viewport rendered 23 columns. Byte
# slicing also cuts multibyte characters in half, emitting invalid UTF-8.
# ASCII takes the pure-bash fast path, so the perl call only happens on the
# overflow path of a non-ASCII name.
_is_ascii() { case "$1" in *[!$'\x01'-$'\x7f']*) return 1 ;; *) return 0 ;; esac; }
_clen() {     # codepoint length
    if _is_ascii "$1"; then printf '%s' "${#1}"
    else printf '%s' "$1" | perl -CS -ne 'chomp; print length' 2>/dev/null; fi
}
_tail_cp() {  # last N codepoints
    if _is_ascii "$1"; then printf '%s' "${1: -$2}"
    else printf '%s' "$1" | perl -CS -sne 'chomp; print substr($_, -$n) if $n > 0' -- -n="$2" 2>/dev/null; fi
}
_head_cp() {  # first N codepoints
    if _is_ascii "$1"; then printf '%s' "${1:0:$2}"
    else printf '%s' "$1" | perl -CS -sne 'chomp; print substr($_, 0, $n) if $n > 0' -- -n="$2" 2>/dev/null; fi
}

DATA=$(timeout 2 cat 2>/dev/null) || DATA=""
[ -z "$DATA" ] && exit 0

# ── Extract ALL fields in a single jq call ──────────────────────────────────
# Uses jq @sh to produce shell-safe quoted assignments. No IFS tricks needed;
# empty fields become VAR='' instead of being silently swallowed.
eval "$(echo "$DATA" | jq -r '
    @sh "MODEL=\(.model.display_name // "Claude" | gsub(" \\(.*\\)"; ""))",
    @sh "MODEL_ID=\(.model.id // "")",
    @sh "DIR=\(.cwd // "~" | sub("/+$"; "") | split("/") | .[-2:] | join("/"))",
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
    @sh "CACHE_PCT=\(try (
        (.context_window.current_usage) as $u
        | if ($u == null) then ""
          else (($u.input_tokens // 0) + ($u.cache_creation_input_tokens // 0) + ($u.cache_read_input_tokens // 0)) as $tot
            | (if $tot > 0 then (($u.cache_read_input_tokens // 0) * 100 / $tot) | floor else "" end)
          end
    ) catch "")",
    @sh "DURATION_MS=\(.cost.total_duration_ms // 0)",
    @sh "COST_USD=\(.cost.total_cost_usd // 0)",
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
MODEL=${MODEL:-Claude}; DIR=${DIR:-~}
# CTX_SIZE and DURATION_MS reach $(( )) further down, so they get the same gate
# the env inputs get. The stdin JSON is a narrower threat model than the process
# environment (it needs control of what Claude Code sends), but the sink is
# identical and the fix costs one call each.
PCT=${PCT:-0}; COST_USD=${COST_USD:-0}
CTX_SIZE=$(_gate_int "${CTX_SIZE:-200000}" 200000)
DURATION_MS=$(_gate_int "${DURATION_MS:-0}" 0)
AGENT=${AGENT:-}; MODE=${MODE:-}; TRANSCRIPT_PATH=${TRANSCRIPT_PATH:-}
CWD_FULL=${CWD_FULL:-~}; SESSION_ID=${SESSION_ID:-}; MODEL_ID=${MODEL_ID:-}
# Safety: strip control bytes from every JSON-sourced field we print, so a
# crafted value can't inject terminal escapes (defense in depth; topic/profile
# are handled separately). Multibyte UTF-8 (bytes >= 0x80) is preserved.
DIR="${DIR//[$'\001'-$'\037\177']/}"
MODEL="${MODEL//[$'\001'-$'\037\177']/}"
AGENT="${AGENT//[$'\001'-$'\037\177']/}"
MODE="${MODE//[$'\001'-$'\037\177']/}"
FIVE_PCT=${FIVE_PCT:-}; SEVEN_PCT=${SEVEN_PCT:-}
FIVE_RESET_TS=${FIVE_RESET_TS:-}; SEVEN_RESET_TS=${SEVEN_RESET_TS:-}
CACHE_PCT=${CACHE_PCT:-}
# COST_USD is numeric (jq guarantees a number or 0), so no control-byte strip
# is needed; but reset any non-numeric value to 0 defensively (allow digits and
# a dot) before awk formats it, mirroring the format_reset / pace_arrow guards.
case "$COST_USD" in ''|*[!0-9.]*) COST_USD=0 ;; esac

# Truncate jq float rounding (e.g. 14.000000000000002 -> 14) and clamp the
# displayed value to [0,100] so a malformed field can't print "105%"/"-30%".
# Empty stays empty (segment omitted); non-numeric passes through untouched.
_clamp_pct() {
    local v="${1%%.*}"
    # Clamp a well-formed integer (optional single leading minus) to [0,100].
    # Anything else (empty, bare "-", "5-5", "abc") becomes "" so the caller
    # treats it as absent rather than feeding garbage into bar/arrow arithmetic.
    [[ "$v" =~ ^-?[0-9]+$ ]] || { printf ''; return; }
    [ "$v" -lt 0 ]   && v=0
    [ "$v" -gt 100 ] && v=100
    printf '%s' "$v"
}
PCT=$(_clamp_pct "$PCT"); PCT=${PCT:-0}   # context % is mandatory; default 0
FIVE_PCT=$(_clamp_pct "$FIVE_PCT")
SEVEN_PCT=$(_clamp_pct "$SEVEN_PCT")
CACHE_PCT=$(_clamp_pct "$CACHE_PCT")

# ── Shared per-user rate-limits cache ─────────────────────────────────────
# Rate limits are account-wide, but Claude Code freezes the stdin rate_limits
# object at each session's LAST API response. An idle session, re-rendered on
# the refresh timer, therefore shows stale 5h/7d bars even when another active
# session on the same account has already seen fresher numbers. This shares the
# freshest snapshot across all of a user's sessions ON THE SAME ACCOUNT through
# one small cache file per account (keyed by CLAUDE_CODE_OAUTH_TOKEN when set,
# see RL_KEY below), so every render can display (and write back) the freshest
# values without cross-account pollution.
#
# For an account-specific session (RL_KEY set: a scanned token or a manual
# CC_STATUSLINE_RL_KEY label) the stdin rate_limits are NOT trusted at all: they
# come from the account-agnostic shared cache and can be another account's
# numbers. Such a session shows ONLY its per-account fetched line (written by
# claude-usage-fetch.sh), and nothing until that fetch lands. See the display
# chain below.
#
# Freshness comes from the DATA, never file mtime (an idle session has a fresh
# mtime but stale numbers). Usage within a window is monotonic, so the newer
# snapshot is the one whose tuple (5h resets_at, 5h used%, 7d resets_at, 7d
# used%) is larger, compared in that priority order. On a strict win the stdin
# snapshot is written back; on a tie stdin is kept and nothing is written. The
# four chosen values are used together, so bars/percent/reset/pace never mix
# two snapshots. Any cache failure is swallowed: it must never break rendering.
#
# Env knobs (mirror the service-cache seam near SVC_CACHE below):
#   CC_STATUSLINE_RL_CACHE   override the cache path (test isolation)
#   CC_STATUSLINE_RL_KEY     override the account key suffix (test seam /
#                            manual account label; empty = unsuffixed cache)
#   CC_STATUSLINE_RL_FETCH   override the usage-fetcher path (test isolation)
#   STATUSLINE_RL_SHARE=0    disable the feature entirely (no read, no write)
#   STATUSLINE_RL_FETCH=0    disable the background per-account usage fetcher
#   STATUSLINE_RL_AUTH_TTL   seconds a fetched snapshot stays authoritative
#                            (default 300)
# Compare two snapshots; prints 1 (A fresher), 2 (B fresher), 0 (identical).
# All eight args must be integers (callers normalize before calling).
_rl_cmp() {
    local afr=$1 afp=$2 asr=$3 asp=$4 bfr=$5 bfp=$6 bsr=$7 bsp=$8
    if [ "$afr" -gt "$bfr" ]; then printf 1; return; fi
    if [ "$afr" -lt "$bfr" ]; then printf 2; return; fi
    if [ "$afp" -gt "$bfp" ]; then printf 1; return; fi
    if [ "$afp" -lt "$bfp" ]; then printf 2; return; fi
    if [ "$asr" -gt "$bsr" ]; then printf 1; return; fi
    if [ "$asr" -lt "$bsr" ]; then printf 2; return; fi
    if [ "$asp" -gt "$bsp" ]; then printf 1; return; fi
    if [ "$asp" -lt "$bsp" ]; then printf 2; return; fi
    printf 0
}
# Atomic, mode-600 write of a snapshot line (FIVE_PCT|FIVE_RESET|SEVEN_PCT|
# SEVEN_RESET). Args: dest five_pct five_reset seven_pct seven_reset. The live
# tmp path is published in RL_TMP so the EXIT trap below reaps it if a signal
# lands mid-write; the name is pid-scoped so concurrent renders never race on it
# or reap each other's tmp. Every step is guarded: a write failure must never
# break rendering.
_rl_write() {
    local dest="$1"
    RL_TMP="$dest.tmp.$$"
    if printf '%s|%s|%s|%s\n' "$2" "$3" "$4" "$5" > "$RL_TMP" 2>/dev/null; then
        chmod 600 "$RL_TMP" 2>/dev/null || true
        mv -f "$RL_TMP" "$dest" 2>/dev/null || rm -f "$RL_TMP" 2>/dev/null || true
    else
        rm -f "$RL_TMP" 2>/dev/null || true
    fi
    RL_TMP=""
}
if [ "${STATUSLINE_RL_SHARE:-1}" != "0" ]; then
    # Reap a tmp left by an interrupted write, while still emitting the crash
    # newline the top-of-file EXIT trap guarantees. RL_TMP is "" outside a write,
    # so this is a no-op on a clean crash; disarmed at the normal output path.
    RL_TMP=""
    trap 'rm -f "$RL_TMP" 2>/dev/null; printf "\n"' EXIT
    # Rate limits are per ACCOUNT, and a session launched with
    # CLAUDE_CODE_OAUTH_TOKEN=... claude talks to a different account than the
    # default keychain login. Key the cache file by a short hash of that token
    # (never the token itself) so each account only shares snapshots with its
    # own sessions; token-less sessions keep the unsuffixed path.
    #
    # Claude Code CONSUMES the var (its child processes, this script included,
    # never see it), but the kernel keeps every process's EXEC-TIME environment
    # readable by its owner (/proc/PID/environ on Linux, ps eww on macOS/BSD),
    # so _rl_key walks the ancestor chain (statusline -> sh -> claude -> user
    # shell) and reads the token from the first ancestor that has it. A session
    # launched without a token scans a few levels, finds nothing, and keeps the
    # unsuffixed shared cache exactly as before.
    #
    # CC_STATUSLINE_RL_KEY (set, possibly empty) short-circuits everything and
    # is used verbatim after filename sanitizing: the test seam, and a manual
    # per-account label for setups the scan can't see through.
    _rl_token() {
        local tok="${CLAUDE_CODE_OAUTH_TOKEN:-}" pid=$$ i
        if [ -z "$tok" ]; then
            for i in 1 2 3 4 5 6; do
                pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
                [ -n "$pid" ] && [ "$pid" -gt 1 ] 2>/dev/null || break
                if [ -r "/proc/$pid/environ" ]; then
                    tok=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null \
                          | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' 2>/dev/null | head -n 1)
                else
                    # A token never contains spaces, so word-splitting the env
                    # dump cannot corrupt it (other vars' values may split;
                    # they are not what sed matches).
                    tok=$(ps eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' \
                          | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' 2>/dev/null | head -n 1)
                fi
                [ -n "$tok" ] && break
            done
        fi
        printf '%s' "$tok"
    }
    RL_TOK=""
    if [ -n "${CC_STATUSLINE_RL_CACHE:-}" ]; then
        # Explicit path override wins outright; skip the (ps-spawning) key scan.
        RL_CACHE="$CC_STATUSLINE_RL_CACHE"
    elif [ -n "${CC_STATUSLINE_RL_KEY+x}" ]; then
        # Manual account label / test seam, used verbatim after filename
        # sanitizing (empty = the shared unsuffixed cache). Skips the scan.
        RL_KEY="${CC_STATUSLINE_RL_KEY//[^A-Za-z0-9._-]/}"
        RL_CACHE="$(_state_dir)/rate-limits${RL_KEY:+-$RL_KEY}"
    else
        # RL_TOK stays in this process only; the one thing that ever reaches a
        # filename is its short one-way cksum hash.
        RL_TOK="$(_rl_token)"
        RL_KEY=""
        [ -n "$RL_TOK" ] && RL_KEY="$(printf '%s' "$RL_TOK" | cksum | cut -d' ' -f1 || echo 0)"
        RL_CACHE="$(_state_dir)/rate-limits${RL_KEY:+-$RL_KEY}"
    fi
    # Normalize stdin reset timestamps to integers (missing/non-numeric -> 0, a
    # same-window tie that then compares on used%). The same 12-digit cap as the
    # cache guard keeps them inside intmax, so _rl_cmp's arithmetic can never
    # overflow and print "integer expected" to stderr on a pathological payload.
    # Percentages are already clamped to 0-100 integers (or "" when absent).
    if [[ "$FIVE_RESET_TS"  =~ ^[0-9]{1,12}$ ]]; then STDIN_FR=$FIVE_RESET_TS;  else STDIN_FR=0; fi
    if [[ "$SEVEN_RESET_TS" =~ ^[0-9]{1,12}$ ]]; then STDIN_SR=$SEVEN_RESET_TS; else STDIN_SR=0; fi
    STDIN_RL=0
    [ -n "$FIVE_PCT" ] && [ -n "$SEVEN_PCT" ] && STDIN_RL=1

    # Read + validate the cache line; any non-numeric field voids the whole line
    # (treated as absent, overwritten on the next write). A 5th field is the
    # FETCHED_EPOCH stamp written by claude-usage-fetch.sh: while fresh it makes
    # the line AUTHORITATIVE (fetched from the account's own API view), so it is
    # displayed unconditionally instead of freshness-compared against stdin,
    # whose rate_limits can carry ANOTHER account's numbers (Claude Code serves
    # every session the shared ~/.claude.json .cachedUsageUtilization cache,
    # whichever account last refreshed it).
    CACHE_RL=0; C_FP=""; C_FR=""; C_SP=""; C_SR=""; C_AT=""
    if [ -f "$RL_CACHE" ]; then
        IFS='|' read -r C_FP C_FR C_SP C_SR C_AT _ < "$RL_CACHE" 2>/dev/null || true
        # Length caps keep every field well inside intmax (a percentage is <=3
        # digits, an epoch <=12), so the arithmetic compare below can never
        # overflow and spew "integer expected" to stderr on a tampered cache;
        # anything longer voids the whole line (absent, overwritten next write).
        if [[ "$C_FP" =~ ^[0-9]{1,3}$ ]] && [[ "$C_FR" =~ ^[0-9]{1,12}$ ]] \
            && [[ "$C_SP" =~ ^[0-9]{1,3}$ ]] && [[ "$C_SR" =~ ^[0-9]{1,12}$ ]]; then
            CACHE_RL=1
            # Defense in depth: a numerically valid but out-of-range percentage
            # (a tampered "999|...") must not render "999%"/a full bar, so
            # re-clamp the cached percentages to [0,100] exactly like the stdin
            # values above. Resets accept any epoch; format_reset already caps
            # the displayed countdown.
            C_FP=$(_clamp_pct "$C_FP"); C_SP=$(_clamp_pct "$C_SP")
        fi
    fi
    # Authoritative while the fetch stamp is fresh (default 300s; negative ages
    # from a tampered future stamp fail the window, so it cannot pin forever).
    RL_NOW="${CC_STATUSLINE_NOW:-$(date +%s)}"
    [[ "$RL_NOW" =~ ^[0-9]{1,12}$ ]] || RL_NOW=0
    RL_AUTH=0; RL_AGE=9999
    if [ "$CACHE_RL" = "1" ] && [[ "$C_AT" =~ ^[0-9]{1,12}$ ]]; then
        RL_AGE=$((RL_NOW - C_AT))
        [ "$RL_AGE" -ge 0 ] && [ "$RL_AGE" -lt "$(_gate_int "${STATUSLINE_RL_AUTH_TTL:-300}" 300)" ] && RL_AUTH=1
    fi

    # Spawn the background usage fetcher when the authoritative snapshot is
    # missing or aging (>=60s). It asks /api/oauth/usage with THIS session's
    # credential: the scanned token (piped via stdin, never argv/env) for token
    # sessions, or the stored login the fetcher reads itself for keychain
    # sessions. The persistent .fetching marker gates ATTEMPTS to one per
    # minute per account across all sessions, success or failure alike: a
    # failed fetch writes no stamp, so without this gate every render would
    # retry and a 429 from the endpoint would never get room to clear.
    # STATUSLINE_RL_FETCH=0 disables; CC_STATUSLINE_RL_FETCH points the
    # spawner elsewhere (test isolation).
    RL_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    RL_FETCH="${CC_STATUSLINE_RL_FETCH:-${RL_SCRIPT_DIR:-$HOME/.local/share/cc-statusline}/claude-usage-fetch.sh}"
    # A fresh .backoff marker means the last fetch got an HTTP error (e.g. the
    # usage endpoint 429ing this credential): stay off it entirely for a while
    # rather than retrying every minute.
    RL_BACK=0
    if [ -f "$RL_CACHE.backoff" ]; then
        RL_BACK_AGE=$((RL_NOW - $(_file_mtime "$RL_CACHE.backoff")))
        [ "$RL_BACK_AGE" -ge 0 ] && [ "$RL_BACK_AGE" -lt "$(_gate_int "${STATUSLINE_RL_BACKOFF:-300}" 300)" ] && RL_BACK=1
    fi
    if [ "${STATUSLINE_RL_FETCH:-1}" != "0" ] && [ -x "$RL_FETCH" ] \
        && [ "$RL_AGE" -ge 60 ] && [ "$RL_BACK" = "0" ]; then
        RL_MARK="$RL_CACHE.fetching"
        RL_MARK_AGE=9999
        [ -f "$RL_MARK" ] && RL_MARK_AGE=$((RL_NOW - $(_file_mtime "$RL_MARK")))
        if [ "$RL_MARK_AGE" -ge 60 ] || [ "$RL_MARK_AGE" -lt 0 ]; then
            touch "$RL_MARK" 2>/dev/null || true
            ( printf '%s' "$RL_TOK" \
                | CC_STATUSLINE_RL_CACHE="$RL_CACHE" "$RL_FETCH" >/dev/null 2>&1 & )
        fi
    fi

    if [ "$RL_AUTH" = "1" ]; then
        # Fresh authoritative snapshot: this account's own numbers, straight
        # from the API. Display them and never let stdin (possibly another
        # account's data) overwrite the line while it is fresh.
        FIVE_PCT="$C_FP"; FIVE_RESET_TS="$C_FR"
        SEVEN_PCT="$C_SP"; SEVEN_RESET_TS="$C_SR"
    elif [ -n "${RL_KEY:-}" ]; then
        # Account-specific session (a scanned CLAUDE_CODE_OAUTH_TOKEN, or a
        # manual CC_STATUSLINE_RL_KEY label): the stdin rate_limits are NOT
        # reliably THIS account's. Claude Code serves every session the shared
        # ~/.claude.json .cachedUsageUtilization (whichever account refreshed
        # last), so on a multi-account machine stdin can carry the DEFAULT
        # keychain account's numbers. Trust ONLY the per-account fetch: show the
        # fetched line (5-field, C_AT stamped) even once it has aged past the
        # authoritative TTL, since a stale reading of the RIGHT account beats a
        # fresh reading of the wrong one and the background fetcher keeps it
        # current. Never compare against or seed from stdin here: that cross-
        # account compare (different reset windows) is what used to overwrite the
        # token cache with the keychain numbers. With no fetched line yet, show
        # no bars rather than the wrong account's; the fetcher fills them within
        # a cycle. A bare 4-field line (no stamp) is stale pollution from before
        # this rule and is ignored the same way.
        if [ "$CACHE_RL" = "1" ] && [[ "$C_AT" =~ ^[0-9]{1,12}$ ]]; then
            FIVE_PCT="$C_FP"; FIVE_RESET_TS="$C_FR"
            SEVEN_PCT="$C_SP"; SEVEN_RESET_TS="$C_SR"
        else
            FIVE_PCT=""; FIVE_RESET_TS=""
            SEVEN_PCT=""; SEVEN_RESET_TS=""
        fi
    elif [ "$CACHE_RL" = "1" ] && [ "$STDIN_RL" = "1" ]; then
        case "$(_rl_cmp "$STDIN_FR" "$FIVE_PCT" "$STDIN_SR" "$SEVEN_PCT" \
                        "$C_FR" "$C_FP" "$C_SR" "$C_SP")" in
            2)  # cache is fresher: display it (all four values together)
                FIVE_PCT="$C_FP"; FIVE_RESET_TS="$C_FR"
                SEVEN_PCT="$C_SP"; SEVEN_RESET_TS="$C_SR" ;;
            1)  # stdin is fresher: keep it and refresh the cache
                _rl_write "$RL_CACHE" "$FIVE_PCT" "$STDIN_FR" "$SEVEN_PCT" "$STDIN_SR" ;;
            *)  : ;;  # identical: keep stdin, no write
        esac
    elif [ "$CACHE_RL" = "1" ]; then
        # Stdin carries no rate limits but the cache does: fill the gap so idle
        # or limit-less renders still show the account-wide bars.
        FIVE_PCT="$C_FP"; FIVE_RESET_TS="$C_FR"
        SEVEN_PCT="$C_SP"; SEVEN_RESET_TS="$C_SR"
    elif [ "$STDIN_RL" = "1" ]; then
        # No usable cache yet: seed it from stdin.
        _rl_write "$RL_CACHE" "$FIVE_PCT" "$STDIN_FR" "$SEVEN_PCT" "$STDIN_SR"
    fi
fi

CTX_SIZE_K=$((CTX_SIZE / 1000))
# Max line width before Claude Code's cli-truncate drops line 2
SAFE_WIDTH=$(_gate_int "${STATUSLINE_WIDTH:-110}" 110)
# Width is measured in Unicode codepoints (see measure_cols), but Nerd Font
# icons can render 1-2 terminal cells depending on the font/terminal. Reserve a
# few columns so truncation stays conservative on terminals that render the
# folder/git/k8s/model glyphs double-width. Power users on a known mono-width
# font can reclaim them with STATUSLINE_GLYPH_MARGIN=0.
WIDE_GLYPH_MARGIN=$(_gate_int "${STATUSLINE_GLYPH_MARGIN:-3}" 3)

# ── Viewport detection + layout tier ───────────────────────────────────────
# Claude Code exports COLUMNS/LINES to the statusline process (v2.1.153+), so
# the render can follow the real viewport instead of a fixed safe width. tput
# cols still cannot help (stdout is captured, see KNOWN_ISSUES). STATUSLINE_WIDTH
# stays a hard CAP: the detected width only ever lowers it, never raises it, so
# an explicit narrow setting is still honored. One column is held back because
# the container's own truncation is what drops line 2.
# 10# forces base 10 throughout: a zero-padded COLUMNS (060) would otherwise be
# read as octal by $(( )) but as decimal by [, so the range check and the
# assignment would disagree and a 60-column viewport would land at 47.
case "${COLUMNS:-}" in
    ''|*[!0-9]*) : ;;
    *) _COLS=$((10#$COLUMNS))
       # Each test carries its own redirect: a value too large for the shell's
       # integer conversion makes the FIRST one write to stderr, and the
       # statusline's contract is empty stderr on every render.
       if [ "$_COLS" -ge 20 ] 2>/dev/null && [ "$_COLS" -le 500 ] 2>/dev/null; then
           [ "$((_COLS - 1))" -lt "$SAFE_WIDTH" ] 2>/dev/null && SAFE_WIDTH=$((_COLS - 1))
       fi ;;
esac
# Below PHONE_COLS the wide render cannot say anything useful, so line 1 keeps
# folder + branch and line 2 keeps account + 5h/7d. STATUSLINE_LAYOUT forces a
# tier (phone|wide); anything else (or unset) auto-selects from the width.
PHONE_COLS=$(_gate_int "${STATUSLINE_PHONE_COLS:-60}" 60)
LAYOUT="${STATUSLINE_LAYOUT:-}"
# A one-line file flips a RUNNING session on the next render, with no
# settings.json edit and no restart. Auto-detection covers the normal case
# (verified: a session viewed from the Claude mobile app renders with
# COLUMNS=52 while the same session on the desk renders at COLUMNS=324, each
# attached client getting its own render), so this is an escape hatch for
# clients that do not report a viewport. Env var wins over the file; the file
# wins over auto-detection.
if [ -z "$LAYOUT" ]; then
    _LAYOUT_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cc-statusline/layout"
    if [ -f "$_LAYOUT_FILE" ]; then
        # tr's stderr is silenced too: a layout file holding invalid UTF-8 makes
        # BSD tr print "Illegal byte sequence" under a UTF-8 locale (and stays
        # quiet under LC_ALL=C, so the C-locale harness run cannot catch it).
        case "$(head -1 "$_LAYOUT_FILE" 2>/dev/null | tr -d '[:space:]' 2>/dev/null)" in
            phone) LAYOUT=phone ;;
            wide)  LAYOUT=wide ;;
        esac
    fi
fi
# LAYOUT_FORCED records that a human chose the tier, so the measured fallback
# further down does not overrule them: asking for the wide render on a narrow
# viewport is a legitimate choice (you accept the container's truncation), and
# an override that silently does something else is not an override.
LAYOUT_FORCED=0
case "$LAYOUT" in
    phone|wide) LAYOUT_FORCED=1 ;;
    *) if [ "$SAFE_WIDTH" -lt "$PHONE_COLS" ] 2>/dev/null; then LAYOUT=phone; else LAYOUT=wide; fi ;;
esac
# Current epoch, overridable so tests can pin time and get deterministic
# rate-limit reset countdowns and pace arrows (see CC_STATUSLINE_NOW in the
# test harness). Used by format_reset and pace_arrow.
_NOW_REAL=$(date +%s)
NOW=$(_gate_int "${CC_STATUSLINE_NOW:-$_NOW_REAL}" "$_NOW_REAL")

TOPIC=""  # populated after SESSION_ID is extracted below

# ── Effort level detection (transcript -> settings -> default) ──────────────
EFFORT=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    # Read from end of file for speed on large transcripts
    EFFORT=$(_reverse_file "$TRANSCRIPT_PATH" \
        | grep -m1 -E '"content":"<local-command-stdout>(Set model to.*effort|Set effort level to)' \
        | grep -oE '\b(low|medium|high|xhigh|max)\b' | tail -1 || true)
fi
if [ -z "$EFFORT" ]; then
    EFFORT=$(jq -r '.effortLevel // empty' "$HOME/.claude/settings.json" 2>/dev/null || true)
fi
EFFORT=${EFFORT:-medium}

# ── Agent-pane model correction (transcript-derived) ────────────────────────
# Claude Code's stdin JSON carries the PARENT session's .model for agent /
# subagent panes, so an agent served by a different model would otherwise show
# the parent's name. The agent's own transcript records the true serving model
# on every assistant entry: lines with "type":"assistant" contain
# "message":{"model":"<id>",...}. Take the most recent such line (reverse-read,
# grep -m1, the same cheap pattern the effort detection uses above). Other lines
# also carry "model":"..." (e.g. Agent tool-call params), so anchor strictly to
# "type":"assistant" lines; on such a line message.model precedes any tool-input
# model, so the first match is the serving model.
#
# Prettify a validated Claude model ID for display: strip the leading "claude-",
# drop a trailing 8-digit date (e.g. -20251001), join the trailing numeric
# segments with dots and capitalize the leading name words. Examples:
#   claude-sonnet-5           -> Sonnet 5
#   claude-opus-4-8           -> Opus 4.8
#   claude-haiku-4-5-20251001 -> Haiku 4.5
# Falls back to the raw (already-validated) ID for anything that does not fit
# the "<name...>-<number...>" shape.
_prettify_model_id() {
    local id="$1" raw="$1"
    id="${id#claude-}"
    local IFS='-'
    local -a segs=() names=() nums=()
    read -ra segs <<< "$id"
    # Drop a trailing 8-digit date segment.
    local last=$(( ${#segs[@]} - 1 ))
    if [ "$last" -ge 0 ] && [[ "${segs[$last]}" =~ ^[0-9]{8}$ ]]; then
        unset 'segs[last]'
        segs=("${segs[@]}")
    fi
    local seg
    for seg in "${segs[@]}"; do
        if [[ "$seg" =~ ^[0-9]+$ ]]; then
            nums+=("$seg")
        elif [ "${#nums[@]}" -eq 0 ] && [[ "$seg" =~ ^[A-Za-z]+$ ]]; then
            names+=("$seg")
        else
            printf '%s' "$raw"; return   # mixed / out-of-order -> raw ID
        fi
    done
    { [ "${#names[@]}" -eq 0 ] || [ "${#nums[@]}" -eq 0 ]; } && { printf '%s' "$raw"; return; }
    # Capitalize each name word (bash 3.2 safe: no ${x^}); one tr per word, and
    # this path only runs for agent panes, never the main session.
    local out="" w first rest
    for w in "${names[@]}"; do
        first=$(printf '%s' "${w:0:1}" | tr '[:lower:]' '[:upper:]')
        rest="${w:1}"
        out="${out:+$out }${first}${rest}"
    done
    local nums_joined="" n
    for n in "${nums[@]}"; do
        nums_joined="${nums_joined:+$nums_joined.}${n}"
    done
    printf '%s %s' "$out" "$nums_joined"
}

if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    TS_MODEL_ID=$(_reverse_file "$TRANSCRIPT_PATH" \
        | grep -m1 '"type":"assistant"' \
        | grep -oE '"model":"[^"]+"' | head -1 || true)
    TS_MODEL_ID=${TS_MODEL_ID#'"model":"'}
    TS_MODEL_ID=${TS_MODEL_ID%'"'}
    # Only override when stdin actually reported an id to differ from: a missing
    # stdin .model.id (MODEL_ID="") must NOT make the differ-gate always true and
    # replace the display_name on every main-session render. Untrusted transcript
    # content is length-capped (MODEL is not in the line-2 truncation priority
    # list, so an oversized but charset-valid id would overflow the line) and
    # accepted only on a strict model-ID charset (defense in depth, same
    # philosophy as the control-byte strips above).
    if [ -n "$MODEL_ID" ] && [ -n "$TS_MODEL_ID" ] \
        && [ "${#TS_MODEL_ID}" -le 64 ] \
        && [[ "$TS_MODEL_ID" =~ ^[a-zA-Z0-9._-]+$ ]] \
        && [ "$TS_MODEL_ID" != "$MODEL_ID" ]; then
        MODEL=$(_prettify_model_id "$TS_MODEL_ID")
        # Same control-byte strip as the other JSON-sourced fields we print.
        MODEL="${MODEL//[$'\001'-$'\037\177']/}"
    fi
fi

# ── Teammate-model hint (in-process agents) ─────────────────────────────────
# Claude Code sends NO focused-agent info in the statusline payload (verified
# on v2.1.206: no .agent field and the parent transcript_path, even while a
# teammate view is focused), so the focused teammate's true model CANNOT be
# shown from here. Next best: when this session has recently-active in-process
# teammates served by a DIFFERENT model, append a compact "+<family>" hint to
# MODEL ("Fable 5 +opus") so a teammate view is not misread as running on the
# session model. Teammate transcripts live next to the session transcript at
# <projects>/<session_id>/subagents/agent-*.jsonl. Cost-bounded: newest 12
# files, only those active in the last 5 min, last 100KB of each, result
# cached 60s per session.
TH_HINT=""
if [ -n "$TRANSCRIPT_PATH" ] && [[ "$TRANSCRIPT_PATH" != */subagents/* ]] \
    && [ -n "$MODEL_ID" ]; then
    TH_DIR="${TRANSCRIPT_PATH%.jsonl}/subagents"
    if [ -d "$TH_DIR" ]; then
        TH_CACHE="$(_state_dir)/teammate-hint-$(printf '%s' "$TH_DIR" | cksum | cut -d' ' -f1 || echo 0)"
        TH_AGE=9999
        [ -f "$TH_CACHE" ] && TH_AGE=$((NOW - $(_file_mtime "$TH_CACHE")))
        if [ "$TH_AGE" -lt 60 ]; then
            TH_HINT=$(head -1 "$TH_CACHE" 2>/dev/null || true)
        else
            # "claude-opus-4-8[1m]" (stdin id) -> "claude-opus-4-8" for comparison.
            TH_BASE="${MODEL_ID%%\[*}"
            TH_FAMS=" "
            while IFS= read -r _tf; do
                [ -n "$_tf" ] || continue
                [ $((NOW - $(_file_mtime "$_tf"))) -le 300 ] || continue
                _tid=$(tail -c 100000 "$_tf" 2>/dev/null | grep '"type":"assistant"' | tail -1 \
                    | grep -oE '"model":"[^"]+"' | head -1 || true)
                _tid=${_tid#'"model":"'}; _tid=${_tid%'"'}
                { [ -n "$_tid" ] && [ "${#_tid}" -le 64 ] && [[ "$_tid" =~ ^[a-zA-Z0-9._-]+$ ]]; } || continue
                [ "$_tid" != "$TH_BASE" ] || continue
                _tfam=${_tid#claude-}; _tfam=${_tfam%%-*}
                [ -n "$_tfam" ] || continue
                case "$TH_FAMS" in *" $_tfam "*) ;; *)
                    TH_FAMS="${TH_FAMS}${_tfam} "
                    TH_HINT="${TH_HINT}+${_tfam}"
                ;; esac
            done < <(ls -t "$TH_DIR"/agent-*.jsonl 2>/dev/null | head -12)
            printf '%s\n' "$TH_HINT" > "$TH_CACHE" 2>/dev/null || true
        fi
        # Strict shape gate (also covers a tampered cache file), same philosophy
        # as the transcript model override above.
        [[ "$TH_HINT" =~ ^(\+[a-z0-9]+)*$ ]] || TH_HINT=""
        [ -n "$TH_HINT" ] && MODEL="${MODEL} ${TH_HINT}"
    fi
fi

# ── Profile badge (opt-in: requires ~/.claude/profile-labels.json) ────────
# Identifies which Claude Code account is logged in. Reads the active
# account UUID directly from ~/.claude.json's .oauthAccount.accountUuid
# (maintained by Claude Code itself; also swapped by tools like
# claude-account-switcher). No network call, no Keychain access, fully
# portable across macOS/Linux.
#
# Sessions launched with CLAUDE_CODE_OAUTH_TOKEN don't update ~/.claude.json,
# so the UUID there would mislabel them. When the rate-limits account scan
# detected a token (RL_KEY, the cksum hash above), the badge is looked up by
# that hash instead: add a profiles entry keyed by the hash to label a token
# account. Requires STATUSLINE_RL_SHARE enabled (the scan runs there).
#
# Disabled if STATUSLINE_PROFILE=0, the mapping file is absent, or
# `enabled: false` is set in the JSON.
PROFILE_LABEL=""
PROFILE_COLOR=""
PROFILE_FILE="${HOME}/.claude/profile-labels.json"
CLAUDE_STATE="${HOME}/.claude.json"
if [ "${STATUSLINE_PROFILE:-1}" != "0" ] && [ -r "$PROFILE_FILE" ] && [ -r "$CLAUDE_STATE" ]; then
    # Note: use `!= false` not `// true` — jq's `//` treats false as absent,
    # so `.enabled // true` would return true even when enabled is false.
    PROFILE_ENABLED=$(jq -r '.enabled != false' "$PROFILE_FILE" 2>/dev/null)
    if [ "$PROFILE_ENABLED" = "true" ]; then
        UUID=$(jq -r '.oauthAccount.accountUuid // empty' "$CLAUDE_STATE" 2>/dev/null)
        BADGE_ID="${RL_KEY:-$UUID}"
        if [ -n "$BADGE_ID" ]; then
            PROFILE_LABEL=$(jq -r --arg u "$BADGE_ID" '.profiles[$u].label // ""' "$PROFILE_FILE" 2>/dev/null)
            PROFILE_COLOR=$(jq -r --arg u "$BADGE_ID" '.profiles[$u].color // "gray"' "$PROFILE_FILE" 2>/dev/null)
            if [ -z "$PROFILE_LABEL" ]; then
                # Unknown id (account UUID or token hash) — short hint so the
                # user knows to add a profiles entry for it
                PROFILE_LABEL="${BADGE_ID:0:6}?"
                PROFILE_COLOR="gray"
            fi
        fi
    fi
fi
# Safety: strip control bytes from the user-authored label before printing.
PROFILE_LABEL="${PROFILE_LABEL//[$'\001'-$'\037\177']/}"
# Map named color -> ANSI 24-bit (gray fallback)
case "${PROFILE_COLOR:-}" in
    red)        PROFILE_FG="\033[38;2;225;100;100m" ;;
    orange)     PROFILE_FG="\033[38;2;245;165;80m"  ;;
    yellow)     PROFILE_FG="\033[38;2;225;200;100m" ;;
    green)      PROFILE_FG="\033[38;2;150;210;150m" ;;
    blue)       PROFILE_FG="\033[38;2;110;170;230m" ;;
    purple)     PROFILE_FG="\033[38;2;200;140;220m" ;;
    cyan)       PROFILE_FG="\033[38;2;120;200;215m" ;;
    gray|grey|"") PROFILE_FG="\033[38;2;170;170;170m" ;;
    *)          PROFILE_FG="\033[38;2;170;170;170m" ;;
esac

# ── Nerd Font icons ───────────────────────────────────────────────────────
NF_GIT=$'\xee\x82\xa0'       # U+E0A0 powerline branch
NF_FOLDER="󰉋"               # nf-md-folder (kept from v1)
NF_MODEL="󰚩"                # nf-md-robot (kept from v1)
NF_K8S="󱃾"                  # nf-md-kubernetes (kept from v1)
NF_CLOCK=$'\xef\x80\x97'     # U+F017 clock
NF_CACHE=$'\xef\x83\xa7'     # U+F0E7 zap (prompt-cache hit rate)
NF_CORNER_TL=$'\xee\x82\xba'    # U+E0BA lower-right fill (top-left corner)
NF_CORNER_BL=$'\xee\x82\xbe'    # U+E0BE upper-right fill (bottom-left corner)
NF_CORNER_TR=$'\xee\x82\xb8'    # U+E0B8 lower-left fill -> top-right corner cut
NF_CORNER_BR=$'\xee\x82\xbc'    # U+E0BC upper-left fill -> bottom-right corner cut

# ── Project-colored background (hash session ID -> unique hue) ────────────
RST="\033[0m"
PROJECT_ROOT=$(git -C "$CWD_FULL" rev-parse --show-toplevel 2>/dev/null || echo "$CWD_FULL")
PHASH=$(printf '%s' "${SESSION_ID:-$CWD_FULL}" | cksum | cut -d' ' -f1 || echo "0")

# ── Session topic ─────────────────────────────────────────────────────────
# Validate SESSION_ID to a safe charset before building a file path from it
# (defends against path traversal via a crafted session_id).
case "${SESSION_ID:-}" in
    ''|*[!A-Za-z0-9_-]*) : ;;   # empty or out-of-charset -> no topic
    *)
        TOPIC_FILE="$HOME/.claude/session-topics/${SESSION_ID}.txt"
        if [ -f "$TOPIC_FILE" ]; then
            # Strip color/control sequences (portable: perl, already a hard
            # dep, replacing the macOS-only gsed) and limit to 40 chars.
            # _strip_ctl also neutralises any cursor/OSC/BEL bytes a model
            # response on disk might contain before we print the topic.
            TOPIC=$(_strip_ctl < "$TOPIC_FILE" 2>/dev/null | tr -d '\n' | cut -c1-40)
        fi
        ;;
esac

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

CLR_SAGE="\033[38;2;150;210;150m"   # green: good
CLR_GOLD="\033[38;2;215;195;125m"   # amber: caution
CLR_CORAL="\033[38;2;225;150;150m"  # coral: warning
# Threshold color for a percentage. Default scale: low is good (sage), high is
# bad (coral). Pass "invert" as $2 for metrics where high is GOOD, e.g. the
# cache hit rate (green when most of the context is served from cache, coral
# when caching is cold).
pct_color() {
    local p=${1:-0} hi="$CLR_CORAL" lo="$CLR_SAGE"
    p=${p%%.*}
    [ "${2:-}" = "invert" ] && { hi="$CLR_SAGE"; lo="$CLR_CORAL"; }
    if   [ "${p:-0}" -gt 70 ] 2>/dev/null; then printf '%b' "$hi"
    elif [ "${p:-0}" -gt 35 ] 2>/dev/null; then printf '%b' "$CLR_GOLD"
    else                                         printf '%b' "$lo"
    fi
}

# ── Git info ────────────────────────────────────────────────────────────────
BRANCH=$(git -c core.useBuiltinFSMonitor=false branch --show-current 2>/dev/null || echo "")
GIT_STATUS=""
# Skip status counts if not inside a real work tree (e.g. the root of a
# bare-clone-with-child-worktrees layout, where `.git` is a pointer file
# to `.bare/`. There, `git diff --cached` would report every tracked file
# as staged, producing a bogus "+N".)
IN_WORKTREE=$(git rev-parse --is-inside-work-tree 2>/dev/null || echo "false")
if [ -n "$BRANCH" ] && [ "$IN_WORKTREE" = "true" ]; then
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
    case "$pct" in ''|*[!0-9]*) pct=0 ;; esac  # non-numeric -> 0 (set -u arith)
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
    case "$epoch" in *[!0-9]*) return ;; esac  # non-numeric -> no countdown (set -u arith)
    local now diff
    now=${NOW:-$(date +%s)}
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

# ── Rate-limit pace arrow (projects window exhaustion) ─────────────────────
# Extrapolate current usage to the window's reset:
#   projected% = used% * window_duration / elapsed
# where elapsed = now - (resets_at - window_duration) is how far into the
# current window we are. Integer-only (no bc).
# Assumes the 5h/7d limits are fixed/anchored windows (usage resets to zero at a
# boundary), not rolling ones -- confirmed: the unified rate-limit headers expose
# a single reset epoch each (anthropic-ratelimit-unified-5h-reset / -7d-reset),
# which only makes sense for an anchored window. If they ever go rolling, elapsed
# is ill-defined and the projected magnitude (not direction) breaks.
#   ↑ coral  projected > 115 — burning fast, will hit the cap before reset
#   → gold   projected 85-115 — roughly on pace to land at ~100%
#   (empty)  projected < 85  — under-consuming, safe; no arrow is shown so the
#            glyph reads as an alert (silence = fine), and the common case
#            reclaims its 2 columns.
# Also empty during the first 2% of the window (too little signal) or on
# missing/zero input — so test fixtures with resets_at=0 and the
# pre-first-exchange state render no arrow.
pace_arrow() {
    local used="${1%%.*}" resets_at="$2" duration="$3" now="$4"
    { [ -z "$used" ] || [ -z "$resets_at" ] || [ "$resets_at" = "0" ] || [ "$resets_at" = "null" ]; } && return
    # non-numeric used/resets_at -> no arrow (avoid set -u arithmetic error)
    case "$used" in *[!0-9]*) return ;; esac
    case "$resets_at" in *[!0-9]*) return ;; esac
    [ "$used" -le 0 ] 2>/dev/null && return
    local elapsed=$(( now - (resets_at - duration) ))
    # Suppress the arrow early in the window, where little signal projects wildly.
    # Floor is max(duration/50, 900): the 2% ratio suits the 7d window (~3.4h),
    # but on the 5h window it is only 6 min (18000/50=360), too thin -- an 8%
    # burst in the first 8 min would project ~108% ("on pace"). The absolute
    # 15-min minimum gives short windows a real settling period. Integer-only.
    local floor=$(( duration / 50 ))
    [ "$floor" -lt 900 ] && floor=900
    [ "$elapsed" -le "$floor" ] 2>/dev/null && return
    local projected=$(( used * duration / elapsed ))
    if   [ "$projected" -gt 115 ]; then printf '\033[38;2;225;150;150m↑'
    elif [ "$projected" -gt 85  ]; then printf '\033[38;2;215;195;125m→'
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

# ── Line 1 assembly (measured truncation, no bash estimate) ────────────────
# assemble_l1 rebuilds L1C from the current (possibly truncated) component
# vars. All width decisions below are driven by measure_cols (true codepoint
# width) rather than a hand-maintained character-count estimate: that is what
# removes the old off-by-2 between the initial estimate (seed 5) and the
# recalculation paths after each truncation (which re-seeded to 2).
L1_PREFIX="${RST}${PROJ_FG}${NF_CORNER_TL}${BG1}"
assemble_l1() {
    L1C="${L1_PREFIX}"
    # Phone: folder + branch only. Topic, agent, mode and k8s are the first
    # things a narrow viewport cannot afford, and the folder answers "which
    # session am I looking at" more reliably than any of them.
    if [ "$LAYOUT" = "phone" ]; then
        L1C+=" ${TXT_FG}${NF_FOLDER} ${DIR} ${B}"
        if [ -n "$BRANCH" ]; then
            L1C+="${SEP}${B} ${TXT_FG}${NF_GIT} ${BRANCH}${B}"
            [ -n "$GIT_STATUS" ] && L1C+=" ${TXT_FG}${GIT_STATUS}${B}"
        fi
        L1C+=" "
        return
    fi
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
}

# ── Line 2 base content (model / effort / profile / clock / context) ────────
CTX_CLR=$(pct_color "$PCT")
CTX_BAR=$(make_bar "$PCT" 7 "$CTX_CLR" "$L2_DIM")
# Effort level color
case $EFFORT in
    max|xhigh|high) EFFORT_CLR="$CLR_SAGE" ;;            # sage: thinking hard
    low)            EFFORT_CLR="$CLR_CORAL" ;;           # coral: warning
    *)              EFFORT_CLR="\033[38;2;170;170;170m" ;;  # gray: medium/unknown
esac

# ── Session cost segment (native, from cost.total_cost_usd) ────────────────
# Sits next to the clock as "⏱ 5m · $0.01". Empty when disabled
# (STATUSLINE_COST=0) or when there is no cost yet, so fresh sessions and the
# no-cost fixtures show nothing, exactly like CACHE_SEG before the first API
# call. Formatted as USD with 2 decimals; a sub-cent floor renders "<0.01" for
# a real-but-tiny cost instead of a misleading "$0.00". Neutral color; built
# here so it is inlined into the base line below and measure_cols captures its
# width during tier selection.
COST_SEG=""
if [ "${STATUSLINE_COST:-1}" != "0" ] && [ "$(awk -v c="$COST_USD" 'BEGIN{print (c>0)?1:0}' 2>/dev/null)" = "1" ]; then
    COST_FMT=$(awk -v c="$COST_USD" 'BEGIN{ if (c>0 && c<0.005) printf "<0.01"; else printf "%.2f", c }' 2>/dev/null)
    COST_SEG=" ${L2_DIM}·${B2} ${L2_TXT}\$${COST_FMT}${B2}"
fi

L2C="${RST}\033[38;2;0;0;0m${NF_CORNER_BL}${BG2} ${L2_TXT}${NF_MODEL} ${MODEL} ${L2_DIM}·${B2} ${EFFORT_CLR}${EFFORT}${B2}"
[ -n "$PROFILE_LABEL" ] && L2C+=" ${L2_DIM}·${B2} ${PROFILE_FG}${PROFILE_LABEL}${B2}"
L2C+=" ${L2_DIM}│${B2} ${L2_TXT}${NF_CLOCK} ${TIME_CLR}${TIME}${B2}${COST_SEG} ${L2_DIM}│${B2} ${CTX_BAR} ${CTX_CLR}${PCT}%${B2} ${L2_TXT}of ${CTX_SIZE_K}k"

# ── Rate-limit detail candidates (full / compact / minimal) ────────────────
# Build all three tiers up front so the widest one that actually FITS can be
# picked from a real measurement below. The old code chose the tier from a
# fixed reserve that could not see 3-digit percentages, long reset countdowns,
# or the trailing service icon, which let line 2 overflow and get dropped.
PACE_ON=1; [ "${STATUSLINE_PACE:-1}" = "0" ] && PACE_ON=0
RATE_FULL=""; RATE_COMPACT=""; RATE_MINIMAL=""
if [ -n "${FIVE_PCT:-}" ] && [ -n "${SEVEN_PCT:-}" ]; then
    FIVE_CLR=$(pct_color "$FIVE_PCT")
    SEVEN_CLR=$(pct_color "$SEVEN_PCT")

    # Pace arrows: where current usage is heading by reset (empty unless we
    # have a real future resets_at, so test fixtures with resets_at=0 are
    # unaffected). 5h window = 18000s, 7d = 604800s.
    FIVE_ARROW=""; SEVEN_ARROW=""
    if [ "$PACE_ON" = "1" ]; then
        FIVE_ARROW=$(pace_arrow "$FIVE_PCT" "$FIVE_RESET_TS" 18000 "$NOW")
        SEVEN_ARROW=$(pace_arrow "$SEVEN_PCT" "$SEVEN_RESET_TS" 604800 "$NOW")
    fi
    FIVE_BAR=$(make_bar "$FIVE_PCT" 5 "$FIVE_CLR" "$L2_DIM")
    SEVEN_BAR=$(make_bar "$SEVEN_PCT" 5 "$SEVEN_CLR" "$L2_DIM")
    FIVE_TIME=$(format_reset "$FIVE_RESET_TS")
    SEVEN_TIME=$(format_reset "$SEVEN_RESET_TS")

    # Full: bars + pct + pace arrow + reset countdowns
    RATE_FULL=" ${L2_DIM}│${B2} ${L2_TXT}5h ${FIVE_BAR} ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
    [ -n "${FIVE_TIME:-}" ] && RATE_FULL+=" ${L2_TXT}${FIVE_TIME}${B2}"
    RATE_FULL+=" ${L2_DIM}│${B2} ${L2_TXT}7d ${SEVEN_BAR} ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
    [ -n "${SEVEN_TIME:-}" ] && RATE_FULL+=" ${L2_TXT}${SEVEN_TIME}${B2}"
    # Compact: bars + pct + pace arrow, no reset countdowns
    RATE_COMPACT=" ${L2_DIM}│${B2} ${L2_TXT}5h ${FIVE_BAR} ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2} ${L2_DIM}│${B2} ${L2_TXT}7d ${SEVEN_BAR} ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
    # Minimal: percentages + pace arrow only
    RATE_MINIMAL=" ${L2_DIM}│${B2} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
fi

# ── Cache hit-rate candidate (lowest-priority line-2 element) ──────────────
# Tucked right after the context size ("of 1000k ⚡ 92%"); only the percentage
# carries the inverted color (green = mostly cached/good, coral = cold). Empty
# before the first API call and after /compact (current_usage null). Off by
# default; opt IN with STATUSLINE_CACHE=1.
CACHE_SEG=""
if [ "${STATUSLINE_CACHE:-0}" = "1" ] && [ -n "${CACHE_PCT:-}" ]; then
    CACHE_CLR=$(pct_color "$CACHE_PCT" invert)
    CACHE_SEG=" ${L2_TXT}${NF_CACHE} ${CACHE_CLR}${CACHE_PCT}%${B2}"
fi

# ── Claude service status (read now so its exact width can be reserved) ─────
# Both paths are env-overridable so tests can isolate from a real cache file or
# disable the background fetcher. The default cache lives in the per-user state
# dir (mode 700), not a predictable /tmp path; it auto-refreshes every 60s in
# the background. The icon is appended to line 2 below, and SVC_W reserves
# exactly its width during tier selection (0 when no status is shown), so the
# rate detail is only downgraded when the icon genuinely needs the room.
SVC_CACHE="${CC_STATUSLINE_SVC_CACHE:-$(_state_dir)/service-status}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
SVC_FETCH="${CC_STATUSLINE_SVC_FETCH:-${SCRIPT_DIR:-$HOME/.local/share/cc-statusline}/claude-status-fetch.sh}"
if [ -x "$SVC_FETCH" ]; then
    SVC_AGE=9999
    [ -f "$SVC_CACHE" ] && SVC_AGE=$(($(date +%s) - $(_file_mtime "$SVC_CACHE")))
    if [ "$SVC_AGE" -ge 60 ]; then
        # Pass the resolved cache path so the fetcher writes exactly where we read.
        (CC_STATUSLINE_SVC_CACHE="$SVC_CACHE" "$SVC_FETCH" >/dev/null 2>/dev/null &)
    fi
fi
SVC_SEG=""
if [ -f "$SVC_CACHE" ]; then
    case "$(head -1 "$SVC_CACHE" 2>/dev/null)" in
        operational)                     SVC_SEG=" ${L2_DIM}│${B2} \033[38;2;100;200;120m✓${B2}" ;;
        incident:*)                      SVC_SEG=" ${L2_DIM}│${B2} \033[38;2;225;150;100m⚠${B2}" ;;
        degraded_performance:*)          SVC_SEG=" ${L2_DIM}│${B2} \033[38;2;215;195;125m~${B2}" ;;
        partial_outage:*|major_outage:*) SVC_SEG=" ${L2_DIM}│${B2} \033[38;2;225;100;100m✗${B2}" ;;
    esac
fi

# ── Phone layout: line 2 override ──────────────────────────────────────────
# Same palette, corners, bands and tier machinery as the wide render, fewer
# segments: "<account> │ 5h <pct><arrow> ↻<reset> │ 7d <pct><arrow> ↻<reset>".
# The tiers below feed the SAME widest-that-fits selection used for the wide
# render, so the countdowns drop before the percentages and the pace arrows
# survive longest (they are the alert). Model, effort, elapsed, cost, context
# and cache are dropped: on a phone they cost more columns than they earn.
# ↻ costs one column and stops the countdown reading as a second percentage.
_apply_phone_l2() {
    L2C="${RST}\033[38;2;0;0;0m${NF_CORNER_BL}${BG2}"
    local PH_SEP=""
    if [ -n "$PROFILE_LABEL" ]; then
        # The badge sits in the line-2 BASE, which no tier can shed, so a long
        # label (an email, "metaminds-prod-account") would survive while the
        # rate limits it pushed out are the entire reason this line exists.
        # Cap it here: on a phone an 8-character account hint is enough to tell
        # two logins apart, which is all the badge is for.
        # The ellipsis is not decoration: a silent cut renders "work-prod" and
        # "work-proj" identically, so the badge would confidently name the wrong
        # account. Eight columns cannot make two long labels distinct, but they
        # can say "this is truncated, shorten your label".
        local lbl="$PROFILE_LABEL"
        [ "$(_clen "$lbl")" -gt 8 ] && lbl="$(_head_cp "$lbl" 7)…"
        L2C+=" ${PROFILE_FG}${lbl}${B2}"
        PH_SEP=" ${L2_DIM}│${B2}"
    fi
    CACHE_SEG=""
    if [ -n "${FIVE_PCT:-}" ] && [ -n "${SEVEN_PCT:-}" ]; then
        # Full: both reset countdowns.
        RATE_FULL="${PH_SEP} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
        [ -n "${FIVE_TIME:-}" ] && RATE_FULL+=" ${L2_DIM}↻${L2_TXT}${FIVE_TIME}${B2}"
        RATE_FULL+=" ${L2_DIM}│${B2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
        [ -n "${SEVEN_TIME:-}" ] && RATE_FULL+=" ${L2_DIM}↻${L2_TXT}${SEVEN_TIME}${B2}"
        # Compact: 5h countdown only (the one you act on).
        RATE_COMPACT="${PH_SEP} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
        [ -n "${FIVE_TIME:-}" ] && RATE_COMPACT+=" ${L2_DIM}↻${L2_TXT}${FIVE_TIME}${B2}"
        RATE_COMPACT+=" ${L2_DIM}│${B2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
        # Minimal: percentages and arrows.
        RATE_MINIMAL="${PH_SEP} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
    else
        # No rate limits at all (fresh session, limit-less account, or the
        # no-rate-limits fixture): fall back to the context percentage so line 2
        # is not an empty band.
        #
        # It goes in the TIERS, not the base. Appended to the base it could not
        # be shed by anything, so at a viewport narrower than base + ctx both
        # lines overflowed and the padding pass widened line 1 to match: with a
        # badge and no rate limits, COLUMNS 20 through 23 all rendered 23
        # columns. All three tiers carry the same string, so the selector shows
        # it when it fits and drops it when it does not, which is the same rule
        # every other line-2 segment already follows.
        local ctx_seg="${PH_SEP} ${L2_TXT}ctx ${CTX_CLR}${PCT}%${B2}"
        RATE_FULL="$ctx_seg"; RATE_COMPACT="$ctx_seg"; RATE_MINIMAL="$ctx_seg"
    fi
}
[ "$LAYOUT" = "phone" ] && _apply_phone_l2

# ── One batch measurement: full L1 + L2 base + every L2 candidate ──────────
# measure_cols takes N strings and emits N codepoint counts in a single perl
# call, so the common (no-overflow) render costs just this measurement plus
# the trailing line-padding measurement further down.
TARGET=$((SAFE_WIDTH - WIDE_GLYPH_MARGIN))
assemble_l1
read -r L1_COLS BASE_W RFULL_W RCOMPACT_W RMINIMAL_W CACHE_W SVC_W < <(
    measure_cols "$L1C" "$L2C" "$RATE_FULL" "$RATE_COMPACT" "$RATE_MINIMAL" "$CACHE_SEG" "$SVC_SEG" | tr '\n' ' '
)
L1_COLS=${L1_COLS:-0}; BASE_W=${BASE_W:-0}
RFULL_W=${RFULL_W:-0}; RCOMPACT_W=${RCOMPACT_W:-0}; RMINIMAL_W=${RMINIMAL_W:-0}
CACHE_W=${CACHE_W:-0}; SVC_W=${SVC_W:-0}

# ── Wide-base fallback: the tier is chosen from the width, but only a
# MEASUREMENT can say whether the wide render actually fits it. Line 2's wide
# base (model, effort, profile, clock, cost, context) has no truncation step of
# its own, so at a viewport just above PHONE_COLS every rate tier could be
# dropped and the line would still overflow; the padding pass then widened line
# 1 to match, so BOTH lines blew past the viewport. Measured before this guard:
# a 61-column viewport rendered 74 columns. The band moves with the base (a
# longer model name or a 5-figure cost widens it), which is exactly why the
# threshold cannot be a constant and the decision has to be re-taken here.
# The comparison has to include the service icon: it is appended after tier
# selection and is not sheddable, so a base that fits alone can still overflow
# once it is added. Measured with the base-only form: a 72-column viewport had
# BASE_W exactly equal to TARGET, kept the wide render, and emitted 74 columns.
if [ "$LAYOUT" = "wide" ] && [ "$LAYOUT_FORCED" = "0" ] \
   && [ "$((BASE_W + SVC_W))" -gt "$TARGET" ] 2>/dev/null; then
    LAYOUT=phone
    _apply_phone_l2
    assemble_l1
    read -r L1_COLS BASE_W RFULL_W RCOMPACT_W RMINIMAL_W CACHE_W SVC_W < <(
        measure_cols "$L1C" "$L2C" "$RATE_FULL" "$RATE_COMPACT" "$RATE_MINIMAL" "$CACHE_SEG" "$SVC_SEG" | tr '\n' ' '
    )
    L1_COLS=${L1_COLS:-0}; BASE_W=${BASE_W:-0}
    RFULL_W=${RFULL_W:-0}; RCOMPACT_W=${RCOMPACT_W:-0}; RMINIMAL_W=${RMINIMAL_W:-0}
    CACHE_W=${CACHE_W:-0}; SVC_W=${SVC_W:-0}
fi

# ── Line 1 truncation, measured. Priority (least to most essential, so the
# leaf dir is preserved longest): K8S > BRANCH > AGENT > MODE > TOPIC > DIR.
# Each round trims one component by the measured overage (plus 2 for "..") and
# re-measures. The common case takes zero rounds; only an overflowing line
# re-measures, keeping the perl-call budget at ~2 per render.
# Phone renders only DIR + BRANCH, so trimming the others would burn a
# re-measure without shrinking the line: walk just the components in play.
TRUNC_ORDER="K8S BRANCH AGENT MODE TOPIC DIR"
# DIRLEAF drops the parent component ("cc-statusline/phone" -> "phone") before
# anything gets character-mangled: on a phone a whole leaf name reads better
# than two half-words, and it usually buys back more columns than trimming the
# branch would.
# The phone ladder must CONVERGE: every step either sheds columns or defers to
# the next, and the last two steps can always shed. Without them the ladder
# bottomed out with line 1 still over budget, and a NARROWER viewport rendered a
# WIDER line (COLUMNS=30 produced 51 columns against a 29-column budget), which
# is precisely the overflow that makes cli-truncate drop line 2.
[ "$LAYOUT" = "phone" ] && TRUNC_ORDER="DIRLEAF BRANCH GITST DIR BRANCHDROP DIRHARD"
for _t in $TRUNC_ORDER; do
    [ "$L1_COLS" -le "$TARGET" ] 2>/dev/null && break
    OVER=$((L1_COLS - TARGET))
    case $_t in
        DIRLEAF) case "$DIR" in */*) DIR="${DIR##*/}" ;; *) continue ;; esac ;;
        GITST)  [ -n "$GIT_STATUS" ] || continue
                GIT_STATUS="" ;;   # dirty markers go before the leaf dir does
        K8S)    [ -n "$K8S_CTX" ] || continue
                MAX=$(($(_clen "$K8S_CTX") - OVER - 2))
                if [ "$MAX" -gt 5 ]; then K8S_CTX="$(_head_cp "$K8S_CTX" "$MAX").."; else K8S_CTX=""; fi ;;
        BRANCH) [ -n "$BRANCH" ] || continue
                MAX=$(($(_clen "$BRANCH") - OVER - 2))
                # Phone keeps the TAIL: worktree branches share a long prefix
                # ("feat/", "devmetaminds/"), so the leaf is what identifies
                # them. The wide render keeps the head, unchanged.
                # A negative offset larger than the string yields the EMPTY
                # string in bash, so a blind "..${BRANCH: -8}" deleted every
                # branch of 7 characters or fewer (main, develop -> "..") and
                # GREW an 8-character one (release1 -> "..release1"). Trim only
                # while there is something to trim; a branch already at or below
                # the floor is left for BRANCHDROP to remove wholesale.
                if [ "$LAYOUT" = "phone" ]; then
                    if   [ "$MAX" -gt 5 ];              then BRANCH="..$(_tail_cp "$BRANCH" "$MAX")"
                    elif [ "$(_clen "$BRANCH")" -gt 8 ]; then BRANCH="..$(_tail_cp "$BRANCH" 6)"
                    else continue; fi
                elif [ "$MAX" -gt 5 ]; then BRANCH="$(_head_cp "$BRANCH" "$MAX").."
                else BRANCH="$(_head_cp "$BRANCH" 8).."; fi ;;
        AGENT)  [ -n "$AGENT" ] || continue
                MAX=$(($(_clen "$AGENT") - OVER - 2))
                if [ "$MAX" -gt 3 ]; then AGENT="$(_head_cp "$AGENT" "$MAX").."; else AGENT="$(_head_cp "$AGENT" 3).."; fi ;;
        MODE)   [ -n "$MODE" ] || continue
                MAX=$(($(_clen "$MODE") - OVER - 2))
                if [ "$MAX" -gt 3 ]; then MODE="$(_head_cp "$MODE" "$MAX").."; else MODE="$(_head_cp "$MODE" 3).."; fi ;;
        TOPIC)  [ -n "$TOPIC" ] || continue
                MAX=$(($(_clen "$TOPIC") - OVER - 2))
                if [ "$MAX" -gt 5 ]; then TOPIC="$(_head_cp "$TOPIC" "$MAX").."; else TOPIC=""; fi ;;
        DIR)    [ -n "$DIR" ] || continue
                MAX=$(($(_clen "$DIR") - OVER - 2))                 # keep the tail (leaf dir)
                if [ "$MAX" -gt 5 ]; then DIR="..$(_tail_cp "$DIR" "$MAX")"
                # Phone has already collapsed DIR to the leaf; defer to DIRHARD
                # rather than mangling it here, and never take the wide path's
                # `${DIR: -6}`, which EMPTIES a leaf shorter than 6 characters.
                elif [ "$LAYOUT" = "phone" ]; then continue
                else DIR="$(_tail_cp "$DIR" 6)"; fi ;;
        # ── Phone-only last resorts. Reached only when everything above has
        # bottomed out and line 1 is still over budget; between them they can
        # always shed, which is what makes the ladder terminate.
        BRANCHDROP) [ -n "$BRANCH" ] || continue
                    BRANCH=""; GIT_STATUS="" ;;   # identity beats provenance
        DIRHARD)    [ -n "$DIR" ] || continue
                    # No ".." here: at this width the two dots cost more than
                    # they explain. Keep the tail, never fewer than 1 char.
                    MAX=$(($(_clen "$DIR") - OVER))
                    if [ "$MAX" -ge 1 ]; then DIR="$(_tail_cp "$DIR" "$MAX")"; else DIR="$(_tail_cp "$DIR" 1)"; fi ;;
    esac
    assemble_l1
    L1_COLS=$(measure_cols "$L1C"); L1_COLS=${L1_COLS:-0}
done

# ── Line 2: widest rate tier that fits, then cache if room remains ─────────
# Rate detail gets FIRST claim on the leftover width (so reset countdowns are
# not squeezed out by cache); cache takes only what is left after it. Only the
# service icon's actual width is reserved (SVC_W is 0 when no status is shown),
# so the full tier with reset countdowns is kept whenever it genuinely fits.
AVAIL=$((TARGET - BASE_W - SVC_W))
RATE_STR=""; RATE_W=0
if   [ "$RFULL_W"    -gt 0 ] && [ "$RFULL_W"    -le "$AVAIL" ] 2>/dev/null; then RATE_STR="$RATE_FULL";    RATE_W=$RFULL_W
elif [ "$RCOMPACT_W" -gt 0 ] && [ "$RCOMPACT_W" -le "$AVAIL" ] 2>/dev/null; then RATE_STR="$RATE_COMPACT"; RATE_W=$RCOMPACT_W
elif [ "$RMINIMAL_W" -gt 0 ] && [ "$RMINIMAL_W" -le "$AVAIL" ] 2>/dev/null; then RATE_STR="$RATE_MINIMAL"; RATE_W=$RMINIMAL_W
fi
if [ "$CACHE_W" -gt 0 ] && [ "$((BASE_W + CACHE_W + RATE_W + SVC_W))" -le "$TARGET" ] 2>/dev/null; then
    L2C+="$CACHE_SEG"
fi
L2C+="$RATE_STR"
L2C+="$SVC_SEG"

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
