#!/usr/bin/env bash
set -uo pipefail  # no -e: external commands (git, kubectl, jq) can fail; silent crash = no statusline
trap 'printf "\n"' EXIT  # ensure at least empty output on crash
[ "${STATUSLINE_DEBUG:-}" = "1" ] && exec 2>/tmp/statusline-debug.log

# One source of theme names for validation and the packaged chooser.
THEME_NAMES=(classic hue-dark nord phosphor synthwave tokyo-night tokyo-day tokyo-auto gruvbox dracula catppuccin default)
_theme_valid() {
    local name
    for name in "${THEME_NAMES[@]}"; do [ "$1" = "$name" ] && return 0; done
    return 1
}
if [ "${1:-}" = "--list-themes" ]; then
    trap - EXIT
    printf '%s\n' "${THEME_NAMES[@]}"
    exit 0
fi


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

# Appearance cache: our only writer stores the timestamp with the answer.
# Hot reads use builtins and the render's existing clock, with no stat/probe
# process. Missing, malformed, expired or future records refresh at most once
# per 60 seconds, including a failed probe's conservative dark fallback.
_appearance() {
    case "${CC_STATUSLINE_APPEARANCE:-}" in
        dark|light) APPEARANCE="$CC_STATUSLINE_APPEARANCE"; return ;;
    esac
    # Mirror _state_dir with readonly UID to avoid id/mkdir/chmod on hot reads.
    # Keep this default path in sync with _state_dir when changing its layout.
    local cache="${CC_STATUSLINE_APPEARANCE_CACHE:-${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/cc-statusline-${UID}/appearance}"
    local record="" extra="" stamp now="${NOW:-}" os answer rc=0 tmp parent
    if [ -z "$now" ]; then
        now=$(date +%s)
        now=$(_gate_int "${CC_STATUSLINE_NOW:-$now}" "$now")
    fi
    if { IFS= read -r record && { ! IFS= read -r extra && [ -z "$extra" ]; }; } 2>/dev/null <"$cache" \
        && [[ "$record" =~ ^([0-9]{1,12})\|(dark|light)$ ]]; then
        stamp=$((10#${BASH_REMATCH[1]}))
        if [ "$stamp" -le "$now" ] && [ "$((now-stamp))" -lt 60 ]; then
            APPEARANCE="${BASH_REMATCH[2]}"; return
        fi
    fi
    APPEARANCE=dark
    os=$(uname -s 2>/dev/null || true)
    case "$os" in
        Darwin)
            if command -v defaults >/dev/null 2>&1; then
                answer=$(timeout 2 defaults read -g AppleInterfaceStyle 2>/dev/null) || rc=$?
                case "$rc" in
                    0) [ "$answer" = Dark ] || APPEARANCE=light ;;
                    1) APPEARANCE=light ;;
                esac
            fi
            ;;
        Linux)
            if command -v gsettings >/dev/null 2>&1; then
                answer=$(timeout 2 gsettings get org.gnome.desktop.interface color-scheme 2>/dev/null) || rc=$?
                if [ "$rc" = 0 ]; then
                    case "$answer" in
                        "'prefer-dark'"|prefer-dark) APPEARANCE=dark ;;
                        "'prefer-light'"|prefer-light|"'default'"|default) APPEARANCE=light ;;
                    esac
                fi
            fi
            ;;
    esac
    parent="${cache%/*}"; [ "$parent" != "$cache" ] || parent=.
    # Only our default state directory gets chmod; an override may name /tmp.
    if mkdir -p "$parent" 2>/dev/null; then
        if [ -z "${CC_STATUSLINE_APPEARANCE_CACHE:-}" ]; then chmod 700 "$parent" 2>/dev/null || return; fi
        tmp=$(mktemp "${cache}.XXXXXX" 2>/dev/null) || return
        if ! printf '%s|%s\n' "$now" "$APPEARANCE" >"$tmp" || ! mv -f "$tmp" "$cache" 2>/dev/null; then
            rm -f "$tmp" 2>/dev/null
        fi
    fi
}
_theme_resolve() {
    THEME_RESOLVED="$1"
    [ "$THEME_RESOLVED" != default ] || THEME_RESOLVED=tokyo-auto
    _theme_valid "$THEME_RESOLVED" || THEME_RESOLVED=tokyo-auto
    if [ "$THEME_RESOLVED" = tokyo-auto ]; then
        _appearance
        case "$APPEARANCE" in light) THEME_RESOLVED=tokyo-day ;; *) THEME_RESOLVED=tokyo-night ;; esac
    fi
}
# Internal chooser path shares exactly the renderer's resolver, without stdin.
if [ "${1:-}" = --resolve-theme ]; then
    trap - EXIT
    [ "$#" = 2 ] || exit 2
    _theme_resolve "$2"
    printf '%s\n' "$THEME_RESOLVED"
    exit 0
fi

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
    @sh "CTX_SHAPE=\(try (
        .context_window as $c | ($c.current_usage) as $u
        | if $u == null then "null"
          elif ($u | type) != "object" then "other"
          elif ($c.context_window_size | (type != "number") or . <= 0 or . >= 1e9 or . != floor) then "other"
          elif ([$u.input_tokens, $u.output_tokens, $u.cache_creation_input_tokens, $u.cache_read_input_tokens]
                | all(type == "number" and . == 0))
               and $c.total_input_tokens == 0 and $c.total_output_tokens == 0
               and $c.used_percentage == 0 and $c.remaining_percentage == 100 then "zero"
          elif [$u.input_tokens, $u.cache_creation_input_tokens, $u.cache_read_input_tokens]
               | all(type == "number" and . >= 0 and . < 1e15 and . == floor) and add > 0 then "positive"
          else "other" end
    ) catch "other")",
    @sh "CTX_USAGE=\(try ([.context_window.current_usage
        | .input_tokens, .cache_creation_input_tokens, .cache_read_input_tokens
        | if type == "number" and . >= 0 and . < 1e15 and . == floor then tostring else "x" end]
        | join(" ")) catch "")",
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
    @sh "EFFORT_IN=\(.effort.level | if type == "string" then . else "" end)",
    @sh "TRANSCRIPT_PATH=\(.transcript_path // "")",
    @sh "CWD_FULL=\(.cwd // "~")",
    @sh "SESSION_ID=\(.session_id // "")",
    @sh "SESSION_TITLE=\(.session_name // "")",
    @sh "PC_OBS=\(.prompt_cache.caching_observed | if type == "boolean" then tostring else "" end)",
    @sh "PC_WARM=\(.prompt_cache.warm | if type == "boolean" then tostring else "" end)",
    @sh "PC_TTL=\(.prompt_cache.ttl | if . == "5m" or . == "1h" then . else "" end)",
    @sh "PC_EXP=\(.prompt_cache.expires_at | if type == "number" and . > 0 and . < 1e12 then floor | tostring else "" end)",
    @sh "PC_RECACHE=\(.prompt_cache.recache_tokens_if_cold | if type == "number" and . >= 0 and . < 1e15 then floor | tostring else "" end)",
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
PCT=${PCT:-0}; COST_USD=${COST_USD:-0}; CTX_SHAPE=${CTX_SHAPE:-other}; CTX_USAGE=${CTX_USAGE:-}
CTX_SIZE=$(_gate_int "${CTX_SIZE:-200000}" 200000)
DURATION_MS=$(_gate_int "${DURATION_MS:-0}" 0)
AGENT=${AGENT:-}; MODE=${MODE:-}; TRANSCRIPT_PATH=${TRANSCRIPT_PATH:-}; EFFORT_IN=${EFFORT_IN:-}
CWD_FULL=${CWD_FULL:-~}; SESSION_ID=${SESSION_ID:-}; MODEL_ID=${MODEL_ID:-}
EFFECTIVE_MODEL_ID="$MODEL_ID"
SESSION_TITLE=${SESSION_TITLE:-}
PC_OBS=${PC_OBS:-}; PC_WARM=${PC_WARM:-}; PC_TTL=${PC_TTL:-}
PC_EXP=${PC_EXP:-}; PC_RECACHE=${PC_RECACHE:-}
# Safety: strip control bytes from every JSON-sourced field we print, so a
# crafted value can't inject terminal escapes (defense in depth; the session
# title/handle and profile label are stripped the same way at their own sites).
# Multibyte UTF-8 (bytes >= 0x80) is preserved.
DIR="${DIR//[$'\001'-$'\037\177']/}"
MODEL="${MODEL//[$'\001'-$'\037\177']/}"
AGENT="${AGENT//[$'\001'-$'\037\177']/}"
MODE="${MODE//[$'\001'-$'\037\177']/}"
# Session name = the addressable "@handle" other Claude sessions use to reach
# this one (peer messaging: SendMessage({to: "<handle>"})), shown as the first
# segment on line 1 so multi-session setups can tell who is who. On by default;
# STATUSLINE_SESSION_NAME=0 hides it.
#
# Source: Claude Code's live per-session registry, ~/.claude/sessions/<pid>.json,
# whose .name is the true handle (e.g. "uzi-60") keyed by .sessionId. It covers
# BOTH the derived default handle AND a /rename value, which is exactly the
# address peers use. The stdin .session_name does NOT carry this: that field is
# the descriptive session title, shown as the topic instead (see the topic block
# below). The registry is an UNDOCUMENTED internal file (shape may change across
# Claude Code versions); the read is fully guarded and simply yields no handle on
# any miss.
#
# Then strip control bytes (a /rename value is user-controlled) and hard-cap the
# length so a pathological name cannot dominate line 1 at a wide viewport;
# width-driven truncation on the NAME rung shortens it further on real overflow.
SESSION_HANDLE=""
if [ "${STATUSLINE_SESSION_NAME:-1}" != "0" ]; then
    # CC_STATUSLINE_SESSIONS_DIR overrides the registry location (test isolation,
    # mirrors the SVC/RL cache seams), so the suite never reads the real registry.
    _SESS_DIR="${CC_STATUSLINE_SESSIONS_DIR:-$HOME/.claude/sessions}"
    if [ -n "$SESSION_ID" ] && [ -d "$_SESS_DIR" ]; then
        # One jq pass over the (few, tiny) registry files; match on sessionId,
        # take the first .name. Any failure (no files, unreadable, bad JSON) is
        # swallowed and leaves the handle empty. The glob is literal when nothing
        # matches, so jq errors to /dev/null and SESSION_HANDLE stays empty.
        SESSION_HANDLE=$(jq -r --arg sid "$SESSION_ID" \
            'select(.sessionId == $sid) | .name // empty' \
            "$_SESS_DIR"/*.json 2>/dev/null | head -n1 || true)
    fi
    SESSION_HANDLE="${SESSION_HANDLE//[$'\001'-$'\037\177']/}"
    [ "$(_clen "$SESSION_HANDLE")" -gt 40 ] 2>/dev/null && SESSION_HANDLE="$(_head_cp "$SESSION_HANDLE" 40)"
fi
FIVE_PCT=${FIVE_PCT:-}; SEVEN_PCT=${SEVEN_PCT:-}
FIVE_RESET_TS=${FIVE_RESET_TS:-}; SEVEN_RESET_TS=${SEVEN_RESET_TS:-}
# Claude's known fixed windows. GPT overrides these with each Codex snapshot's
# reported duration after classifying it as 5h or weekly.
FIVE_DURATION=18000; SEVEN_DURATION=604800
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

# Extract the effective serving model once, before any provider-specific cache
# work. Agent panes can receive the parent model on stdin while their transcript
# records the actual model. Keep every original correction gate: stdin must have
# an id, the transcript id must differ, and untrusted transcript text is length-
# and charset-bounded. The display correction later reuses this validated value.
TS_MODEL_ID=""
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    TS_MODEL_ID=$(_reverse_file "$TRANSCRIPT_PATH" \
        | grep -m1 '"type":"assistant"' \
        | grep -oE '"model":"[^"]+"' | head -1 || true)
    TS_MODEL_ID=${TS_MODEL_ID#'"model":"'}
    TS_MODEL_ID=${TS_MODEL_ID%'"'}
    if [ -n "$MODEL_ID" ] && [ -n "$TS_MODEL_ID" ] \
        && [ "${#TS_MODEL_ID}" -le 64 ] \
        && [[ "$TS_MODEL_ID" =~ ^[a-zA-Z0-9._:-]+$ ]] \
        && [ "$TS_MODEL_ID" != "$MODEL_ID" ]; then
        EFFECTIVE_MODEL_ID="$TS_MODEL_ID"
    fi
fi

# GPT plan limits are opt-in and come from the official Codex CLI, not from
# Claude Code's Anthropic rate_limits payload. Keep detection ID-based so a
# future transport can replace Clodex without changing the usage source. The
# explicit API-key route is intentionally absent: ChatGPT plan usage does not
# describe an OpenAI API-key account.
_is_gpt_model_id() {
    local id="${1%%\[*}"
    case "$id" in
        gpt-*|claude-ocx-native--gpt-*|clodex:openai-oauth:gpt-*|anthropic-openai-oauth__gpt-*) return 0 ;;
        *) return 1 ;;
    esac
}
GPT_EFFECTIVE_EARLY=0
if [ "${STATUSLINE_GPT_LIMITS:-0}" = "1" ] && _is_gpt_model_id "$EFFECTIVE_MODEL_ID"; then
    GPT_EFFECTIVE_EARLY=1
fi

# ── GPT context hold (transient all-zero usage) ─────────────────────────────
# Observed on a gpt-6.1-sol session: between renders reporting 21% with positive
# input and cache tokens, Claude Code sent a context_window whose four
# current_usage counters, total_input_tokens and total_output_tokens were all 0
# (used 0%, remaining 100%), then 21% again. Where that payload comes from is
# unproven. For a GPT effective model, exactly that shape re-shows the last
# valid native percentage in dim gray (CTX_STALE) instead of a false 0%; every
# other shape renders natively. Claude renders never hold.
#
# One private snapshot per session_id (mode 600, atomic replace) records the
# native percentage with its keys (raw and effective model, window, transcript
# path), the stdin input/cache counters it was proven with, the compact epoch
# (uuid of the transcript's last compact_boundary, or "none") and a light
# transcript identity: dev/inode, size, and an MD5 of only the up-to-4 KB that
# end at that size. Each check reads the whole transcript line by line, but only
# compact-boundary and provenance candidate lines are JSON-parsed:
#   seed  A positive render is stored only when the transcript has an assistant
#         entry (completion fields such as stop_reason are not checked) AFTER
#         the last compact boundary whose input, cache-creation and cache-read
#         counters equal stdin's and whose model is the raw or effective one.
#         That ties the value to the current epoch: a pre-compaction frame read
#         after the boundary was written finds no such entry and is not stored.
#         It is re-proven whenever the percentage, the counters or a key
#         changed, so a post-compaction frame with the same percentage still
#         moves the snapshot to the new epoch. Without that proof (including a
#         transcript that has not caught up yet) the old snapshot is deleted,
#         since it no longer holds the last displayed value.
#   hold  The all-zero shape holds only if every key matches, the file has the
#         same dev/inode, is not shorter, the checked tail bytes still match,
#         and the latest compact epoch is still the recorded one. Edits earlier
#         in the same file are not detected: the transcript is assumed to be
#         append-only.
# A boundary candidate that does not parse, a boundary without a well-formed
# uuid, an unterminated last line, or a read error makes the pass "unknown",
# which never holds or seeds. Any failed hold, a null/absent current_usage, any
# other shape, a key change, and a non-GPT render delete the snapshot rather
# than skip it, so switching away and back cannot resurrect an older value.
#   CC_STATUSLINE_CTX_CACHE   override the snapshot path (test isolation)
CTX_STALE=0
_ctx_transcript() {  # seed <path> <in> <cc> <cr> <model...> | hold <path> <epoch> <dev> <ino> <size> <md5>
    perl -e '
        use strict; use JSON::PP (); use Digest::MD5 qw(md5_hex);
        my ($mode, $p, @a) = @ARGV;
        my $UUID = qr/^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/;
        my $INT = qr/^[0-9]{1,15}$/;
        open(my $fh, "<:raw", $p) or exit 1;
        my @st = stat($fh) or exit 1;
        -f _ or exit 1;
        my $size = $st[7];
        $size > 0 or exit 1;
        sub tail4k {  # the up-to-4096 bytes that end at offset $_[0]
            my $end = shift; my $off = $end > 4096 ? $end - 4096 : 0;
            seek($fh, $off, 0) or exit 1;
            my $got = read($fh, my $buf, $end - $off);
            (defined $got && $got == $end - $off) or exit 1;
            return $buf;
        }
        sub dec { my $o = eval { JSON::PP::decode_json($_[0]) }; ref($o) eq "HASH" ? $o : undef }
        my ($in, $cc, $cr, %models);
        if ($mode eq "seed") {
            ($in, $cc, $cr) = splice(@a, 0, 3); $models{$_} = 1 for @a;
            ("$in$cc$cr" =~ /^[0-9]+$/ && $in =~ $INT && $cc =~ $INT && $cr =~ $INT) or exit 1;
        }
        elsif ($mode eq "hold") {
            my ($ep, $dev, $ino, $was, $md5) = @a;
            ("$st[0]" eq $dev && "$st[1]" eq $ino && $size >= $was) or exit 1;
            md5_hex(tail4k($was)) eq $md5 or exit 1;
        } else { exit 1 }
        seek($fh, 0, 0) or exit 1;
        my ($epoch, $found, $last) = ("none", 0, "");
        while (my $l = <$fh>) {
            $last = $l;
            if (index($l, "compact_boundary") >= 0) {
                my $o = dec($l) or exit 1;
                if (($o->{type} // "") eq "system" && ($o->{subtype} // "") eq "compact_boundary") {
                    my $u = $o->{uuid};
                    (defined $u && !ref $u && $u =~ $UUID) or exit 1;
                    ($epoch, $found) = ($u, 0);
                    next;
                }
            }
            # Cheap exact-text prefilter; only real candidates pay for a decode.
            next unless $mode eq "seed" && index($l, q("type":"assistant")) >= 0
                && $l =~ /"input_tokens":$in(?![0-9])/ && $l =~ /"cache_read_input_tokens":$cr(?![0-9])/
                && $l =~ /"cache_creation_input_tokens":$cc(?![0-9])/;
            my $o = dec($l) or next;
            ($o->{type} // "") eq "assistant" && ref($o->{message}) eq "HASH" or next;
            my $m = $o->{message}; my $u = $m->{usage};
            ref($u) eq "HASH" && defined $m->{model} && !ref $m->{model} && $models{$m->{model}} or next;
            my $ok = 1;
            for ([input_tokens => $in], [cache_creation_input_tokens => $cc], [cache_read_input_tokens => $cr]) {
                my $v = $u->{$_->[0]};
                $ok = 0 unless defined $v && !ref $v && "$v" =~ $INT && $v == $_->[1];
            }
            $found = 1 if $ok;
        }
        (eof($fh) && substr($last, -1) eq "\n") or exit 1;
        if ($mode eq "hold") { exit($epoch eq $a[0] ? 0 : 1) }
        my $buf = tail4k($size);
        substr($buf, -1) eq "\n" or exit 1;
        print "$epoch $st[0] $st[1] $size ", md5_hex($buf), " $found\n";
        exit 0;
    ' "$@" 2>/dev/null
}
CTX_SNAP=""
if [[ "$SESSION_ID" =~ ^[A-Za-z0-9._-]{1,128}$ ]]; then
    CTX_SNAP="${CC_STATUSLINE_CTX_CACHE:-$(_state_dir)/ctx-last-$SESSION_ID}"
fi
_CTX_MODEL_RE='^[][A-Za-z0-9._:/-]{1,128}$'
if [ -n "$CTX_SNAP" ] && _is_gpt_model_id "$EFFECTIVE_MODEL_ID" \
    && [[ "$EFFECTIVE_MODEL_ID" =~ $_CTX_MODEL_RE ]] && [[ "$MODEL_ID" =~ $_CTX_MODEL_RE ]] \
    && [ -n "$TRANSCRIPT_PATH" ] && [[ "$TRANSCRIPT_PATH" != *[$'\001'-$'\037\177']* ]]; then
    S_V=""; S_SID=""; S_RAW=""; S_EFF=""; S_SIZE=""; S_PCT=""; S_USE=""; S_EP=""
    S_DEV=""; S_INO=""; S_LEN=""; S_MD5=""; S_PATH=""
    CTX_SNAP_OK=0
    if [ -f "$CTX_SNAP" ]; then
        IFS='|' read -r S_V S_SID S_RAW S_EFF S_SIZE S_PCT S_USE S_EP S_DEV S_INO S_LEN S_MD5 S_PATH \
            <"$CTX_SNAP" 2>/dev/null || true
        if [ "$S_V" = "v3" ] && [ "$S_SID" = "$SESSION_ID" ] \
            && [ "$S_RAW" = "$MODEL_ID" ] && [ "$S_EFF" = "$EFFECTIVE_MODEL_ID" ] \
            && [ "$S_SIZE" = "$CTX_SIZE" ] && [ "$S_PATH" = "$TRANSCRIPT_PATH" ] \
            && [[ "$S_PCT" =~ ^(0|[1-9][0-9]?|100)$ ]] \
            && [[ "$S_USE" =~ ^[0-9]{1,15}\.[0-9]{1,15}\.[0-9]{1,15}$ ]] \
            && [[ "$S_EP" =~ ^(none|[0-9a-fA-F-]{36})$ ]] \
            && [[ "$S_DEV" =~ ^[0-9]{1,20}$ ]] && [[ "$S_INO" =~ ^[0-9]{1,20}$ ]] \
            && [[ "$S_LEN" =~ ^[0-9]{1,15}$ ]] && [[ "$S_MD5" =~ ^[0-9a-f]{32}$ ]]; then
            CTX_SNAP_OK=1
        fi
    fi
    case "$CTX_SHAPE" in
        zero)
            if [ "$CTX_SNAP_OK" = "1" ] && _ctx_transcript hold "$TRANSCRIPT_PATH" \
                "$S_EP" "$S_DEV" "$S_INO" "$S_LEN" "$S_MD5"; then
                CTX_STALE=1
                PCT="$S_PCT"
            else
                rm -f "$CTX_SNAP" 2>/dev/null || true
            fi ;;
        positive)
            # Re-proven when the value, the counters or a key changed. Identical
            # counters are the same response, so the stored epoch still applies
            # (a pre-compaction frame repeated after a boundary keeps the old
            # epoch, which the hold pass then refuses).
            if [ "$CTX_SNAP_OK" != "1" ] || [ "$S_PCT" != "$PCT" ] \
                || [ "$S_USE" != "${CTX_USAGE// /.}" ]; then
                CTX_ID=""
                if [[ "$CTX_USAGE" =~ ^[0-9]{1,15}\ [0-9]{1,15}\ [0-9]{1,15}$ ]]; then
                    # shellcheck disable=SC2086  # three validated integers
                    CTX_ID=$(_ctx_transcript seed "$TRANSCRIPT_PATH" $CTX_USAGE \
                        "$MODEL_ID" "$EFFECTIVE_MODEL_ID" || true)
                fi
                if [[ "$CTX_ID" =~ ^(none|[0-9a-fA-F-]{36})\ ([0-9]{1,20})\ ([0-9]{1,20})\ ([0-9]{1,15})\ ([0-9a-f]{32})\ ([01])$ ]]; then
                    if [ "${BASH_REMATCH[6]}" = "1" ]; then
                        CTX_TMP="$CTX_SNAP.tmp.$$"
                        trap 'rm -f "${CTX_TMP:-}" 2>/dev/null; printf "\n"' EXIT
                        # Publish only after write, mode and rename all succeed.
                        # Any failure deletes the old snapshot too: it holds an
                        # older value than this render shows, so keeping it would
                        # let a later all-zero frame resurrect a stale reading.
                        if ! { printf 'v3|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$SESSION_ID" "$MODEL_ID" \
                                   "$EFFECTIVE_MODEL_ID" "$CTX_SIZE" "$PCT" "${CTX_USAGE// /.}" "${BASH_REMATCH[1]}" \
                                   "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" \
                                   "${BASH_REMATCH[5]}" "$TRANSCRIPT_PATH" >"$CTX_TMP" \
                               && chmod 600 "$CTX_TMP" && mv -f "$CTX_TMP" "$CTX_SNAP"; } 2>/dev/null; then
                            rm -f "$CTX_TMP" "$CTX_SNAP" 2>/dev/null || true
                        fi
                        CTX_TMP=""
                        trap 'printf "\n"' EXIT
                    else
                        # Not provably post-boundary. The stored value is older
                        # than what this render shows, so it is not the last
                        # value any more either.
                        rm -f "$CTX_SNAP" 2>/dev/null || true
                    fi
                else
                    rm -f "$CTX_SNAP" 2>/dev/null || true
                fi
            fi ;;
        *)  rm -f "$CTX_SNAP" 2>/dev/null || true ;;
    esac
elif [ -n "$CTX_SNAP" ] && [ -e "$CTX_SNAP" ]; then
    rm -f "$CTX_SNAP" 2>/dev/null || true
fi

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
# Resolve the account key independently from Claude rate-limit processing: the
# profile badge still needs the token-derived key in a GPT session, even though
# that session must skip every Anthropic cache/compare/fetch operation below.
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
                # A token never contains spaces, so splitting the process env
                # cannot corrupt it; other variables are ignored by sed.
                tok=$(ps eww -o command= -p "$pid" 2>/dev/null | tr ' ' '\n' \
                      | sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' 2>/dev/null | head -n 1)
            fi
            [ -n "$tok" ] && break
        done
    fi
    printf '%s' "$tok"
}
RL_TOK=""; RL_KEY=""
if [ "${STATUSLINE_RL_SHARE:-1}" != "0" ]; then
    if [ -n "${CC_STATUSLINE_RL_CACHE:-}" ]; then
        # Explicit path override wins outright; skip the key scan.
        RL_CACHE="$CC_STATUSLINE_RL_CACHE"
    elif [ -n "${CC_STATUSLINE_RL_KEY+x}" ]; then
        RL_KEY="${CC_STATUSLINE_RL_KEY//[^A-Za-z0-9._-]/}"
        RL_CACHE="$(_state_dir)/rate-limits${RL_KEY:+-$RL_KEY}"
    else
        RL_TOK="$(_rl_token)"
        [ -n "$RL_TOK" ] && RL_KEY="$(printf '%s' "$RL_TOK" | cksum | cut -d' ' -f1 || echo 0)"
        RL_CACHE="$(_state_dir)/rate-limits${RL_KEY:+-$RL_KEY}"
    fi
fi

if [ "${STATUSLINE_RL_SHARE:-1}" != "0" ] && [ "$GPT_EFFECTIVE_EARLY" != "1" ]; then
    # Reap a tmp left by an interrupted write, while still emitting the crash
    # newline the top-of-file EXIT trap guarantees. RL_TMP is "" outside a write,
    # so this is a no-op on a clean crash; disarmed at the normal output path.
    RL_TMP=""
    trap 'rm -f "$RL_TMP" 2>/dev/null; printf "\n"' EXIT
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

TOPIC=""  # populated from the native session title (SESSION_TITLE) below

# ── Effort level detection (stdin -> env -> transcript -> settings -> default)
# Claude Code sends the live level as stdin .effort.level and exports it as
# CLAUDE_EFFORT (verified on 2.1.278). Both reflect a --effort launch flag or
# env override, which never reaches the transcript or settings.json, so they
# win. Accept only a short lowercase word: an unknown future level still shows,
# but nothing else can reach the terminal. The transcript and settings reads
# remain the fallback for older Claude Code builds that send neither.
_effort_word() { case "$1" in ''|*[!a-z]*) return 1 ;; *) [ "${#1}" -le 12 ] ;; esac; }
EFFORT=""
if _effort_word "$EFFORT_IN"; then
    EFFORT="$EFFORT_IN"
elif _effort_word "${CLAUDE_EFFORT:-}"; then
    EFFORT="$CLAUDE_EFFORT"
fi
if [ -z "$EFFORT" ] && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
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
# "message":{"model":"<id>",...}. EFFECTIVE_MODEL_ID was extracted and
# validated once above, before provider-specific rate-cache work, so this block
# only formats the accepted value for display.
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

if [ "$EFFECTIVE_MODEL_ID" != "$MODEL_ID" ]; then
    MODEL=$(_prettify_model_id "$EFFECTIVE_MODEL_ID")
    # Same control-byte strip as the other JSON-sourced fields we print.
    MODEL="${MODEL//[$'\001'-$'\037\177']/}"
fi

# ── GPT/Codex plan usage (opt-in) ───────────────────────────────────────────
# The official Codex app server owns ChatGPT authentication and refreshes its
# own OAuth token. codex-usage-fetch.sh asks its read-only
# account/rateLimits/read method in the background and writes a separate cache;
# no inference request or Clodex credential access is involved. A GPT session
# never falls back to Claude's stdin/cache percentages: stale or missing Codex
# data means no rate segment until a successful fetch lands.
GPT_ACTIVE=0
if [ "${STATUSLINE_GPT_LIMITS:-0}" = "1" ] && _is_gpt_model_id "$EFFECTIVE_MODEL_ID"; then
    GPT_ACTIVE=1
    FIVE_PCT=""; FIVE_RESET_TS=""
    SEVEN_PCT=""; SEVEN_RESET_TS=""

    GPT_CACHE="${CC_STATUSLINE_GPT_CACHE:-$(_state_dir)/rate-limits-gpt}"
    GPT_FP=""; GPT_FR=""; GPT_FD=""; GPT_SP=""; GPT_SR=""; GPT_SD=""
    GPT_AT=""; GPT_EXTRA=""; GPT_CACHE_OK=0; GPT_HAS_WINDOW=0
    if [ -f "$GPT_CACHE" ]; then
        IFS='|' read -r GPT_FP GPT_FR GPT_FD GPT_SP GPT_SR GPT_SD GPT_AT GPT_EXTRA <"$GPT_CACHE" 2>/dev/null || true
        GPT_FIELDS_OK=1
        if [ -n "$GPT_FP" ]; then
            [[ "$GPT_FP" =~ ^[0-9]{1,3}$ ]] || GPT_FIELDS_OK=0
            { [ -z "$GPT_FR" ] || [[ "$GPT_FR" =~ ^[0-9]{1,12}$ ]]; } || GPT_FIELDS_OK=0
            if [[ "$GPT_FD" =~ ^[0-9]{1,9}$ ]]; then
                [ "$GPT_FD" -ge 17100 ] && [ "$GPT_FD" -le 18900 ] 2>/dev/null || GPT_FIELDS_OK=0
            else
                GPT_FIELDS_OK=0
            fi
            GPT_HAS_WINDOW=1
        elif [ -n "$GPT_FR" ] || [ -n "$GPT_FD" ]; then
            GPT_FIELDS_OK=0
        fi
        if [ -n "$GPT_SP" ]; then
            [[ "$GPT_SP" =~ ^[0-9]{1,3}$ ]] || GPT_FIELDS_OK=0
            { [ -z "$GPT_SR" ] || [[ "$GPT_SR" =~ ^[0-9]{1,12}$ ]]; } || GPT_FIELDS_OK=0
            if [[ "$GPT_SD" =~ ^[0-9]{1,9}$ ]]; then
                [ "$GPT_SD" -ge 574560 ] && [ "$GPT_SD" -le 635040 ] 2>/dev/null || GPT_FIELDS_OK=0
            else
                GPT_FIELDS_OK=0
            fi
            GPT_HAS_WINDOW=1
        elif [ -n "$GPT_SR" ] || [ -n "$GPT_SD" ]; then
            GPT_FIELDS_OK=0
        fi
        [ -z "$GPT_EXTRA" ] || GPT_FIELDS_OK=0
        [[ "$GPT_AT" =~ ^[0-9]{1,12}$ ]] || GPT_FIELDS_OK=0
        [ "$GPT_FIELDS_OK" = "1" ] && [ "$GPT_HAS_WINDOW" = "1" ] && GPT_CACHE_OK=1
    fi

    GPT_AGE=9999
    if [ "$GPT_CACHE_OK" = "1" ]; then
        GPT_AGE=$((NOW - GPT_AT))
        GPT_TTL=$(_gate_int "${STATUSLINE_GPT_AUTH_TTL:-300}" 300)
        if [ "$GPT_AGE" -lt 0 ] 2>/dev/null; then
            GPT_AGE=9999
        elif [ "$GPT_AGE" -lt "$GPT_TTL" ] 2>/dev/null; then
            FIVE_PCT=$(_clamp_pct "$GPT_FP"); FIVE_RESET_TS="$GPT_FR"; FIVE_DURATION="$GPT_FD"
            SEVEN_PCT=$(_clamp_pct "$GPT_SP"); SEVEN_RESET_TS="$GPT_SR"; SEVEN_DURATION="$GPT_SD"
        fi
    fi

    GPT_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    GPT_FETCH="${CC_STATUSLINE_GPT_FETCH:-${GPT_SCRIPT_DIR:-$HOME/.local/share/cc-statusline}/codex-usage-fetch.sh}"
    GPT_BACK=0
    if [ -f "$GPT_CACHE.backoff" ]; then
        GPT_BACK_AGE=$((NOW - $(_file_mtime "$GPT_CACHE.backoff")))
        GPT_BACK_TTL=$(_gate_int "${STATUSLINE_GPT_BACKOFF:-300}" 300)
        [ "$GPT_BACK_AGE" -ge 0 ] && [ "$GPT_BACK_AGE" -lt "$GPT_BACK_TTL" ] 2>/dev/null && GPT_BACK=1
    fi
    if [ "${STATUSLINE_GPT_FETCH:-1}" != "0" ] && [ -x "$GPT_FETCH" ] \
        && [ "$GPT_AGE" -ge 60 ] && [ "$GPT_BACK" = "0" ]; then
        GPT_MARK="$GPT_CACHE.fetching"
        GPT_MARK_AGE=9999
        [ -f "$GPT_MARK" ] && GPT_MARK_AGE=$((NOW - $(_file_mtime "$GPT_MARK")))
        if [ "$GPT_MARK_AGE" -ge 60 ] || [ "$GPT_MARK_AGE" -lt 0 ]; then
            touch "$GPT_MARK" 2>/dev/null || true
            (CC_STATUSLINE_GPT_CACHE="$GPT_CACHE" CC_STATUSLINE_NOW="$NOW" \
             "$GPT_FETCH" >/dev/null 2>&1 &)
        fi
    fi
fi

# ── GPT-5.6 Sol credit-equivalent estimate (opt-in with GPT limits) ─────────
# The helper streams this session's main transcript plus subagent JSONL files,
# deduplicates repeated assistant response ids, and applies only the published
# ChatGPT credit rates for recognized GPT-5.6 Sol identities. It runs in the
# background; a render only reads this session-keyed private cache.
GPT_CREDITS_UNITS=""
if [ "$GPT_ACTIVE" = "1" ] && [ "${STATUSLINE_GPT_CREDITS:-1}" != "0" ] \
    && [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    if [ -n "${CC_STATUSLINE_GPT_CREDITS_CACHE:-}" ]; then
        CREDITS_CACHE="$CC_STATUSLINE_GPT_CREDITS_CACHE"
    else
        CREDITS_KEY=$(printf '%s' "$TRANSCRIPT_PATH" | cksum | cut -d' ' -f1 || echo 0)
        CREDITS_CACHE="$(_state_dir)/gpt-credits-$CREDITS_KEY"
    fi
    CR_STATE=""; CR_UNITS=""; CR_AT=""; CR_EXTRA=""; CR_CACHE_OK=0
    if [ -f "$CREDITS_CACHE" ]; then
        IFS='|' read -r CR_STATE CR_UNITS CR_AT CR_EXTRA <"$CREDITS_CACHE" 2>/dev/null || true
        if [ -z "$CR_EXTRA" ] && [[ "$CR_AT" =~ ^[0-9]{1,12}$ ]]; then
            case "$CR_STATE" in
                ok) [[ "$CR_UNITS" =~ ^[0-9]{1,18}$ ]] && CR_CACHE_OK=1 ;;
                unavailable) [ -z "$CR_UNITS" ] && CR_CACHE_OK=1 ;;
            esac
        fi
    fi
    CR_AGE=9999
    if [ "$CR_CACHE_OK" = "1" ]; then
        CR_AGE=$((NOW - CR_AT))
        [ "$CR_AGE" -lt 0 ] 2>/dev/null && CR_AGE=9999
        CR_TTL=$(_gate_int "${STATUSLINE_GPT_CREDITS_TTL:-300}" 300)
        if [ "$CR_STATE" = "ok" ] && [[ "$CR_UNITS" =~ [1-9] ]] \
            && [ "$CR_AGE" -lt "$CR_TTL" ] 2>/dev/null; then
            GPT_CREDITS_UNITS="$CR_UNITS"
        fi
    fi

    CREDITS_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    CREDITS_FETCH="${CC_STATUSLINE_GPT_CREDITS_FETCH:-${CREDITS_SCRIPT_DIR:-$HOME/.local/share/cc-statusline}/gpt-credits-fetch.sh}"
    if [ -x "$CREDITS_FETCH" ] && [ "$CR_AGE" -ge 60 ]; then
        CREDITS_MARK="$CREDITS_CACHE.fetching"
        CREDITS_MARK_AGE=9999
        [ -f "$CREDITS_MARK" ] && CREDITS_MARK_AGE=$((NOW - $(_file_mtime "$CREDITS_MARK")))
        if [ "$CREDITS_MARK_AGE" -ge 60 ] || [ "$CREDITS_MARK_AGE" -lt 0 ]; then
            touch "$CREDITS_MARK" 2>/dev/null || true
            (CC_STATUSLINE_GPT_TRANSCRIPT="$TRANSCRIPT_PATH" \
             CC_STATUSLINE_GPT_CREDITS_CACHE="$CREDITS_CACHE" \
             CC_STATUSLINE_NOW="$NOW" \
             "$CREDITS_FETCH" >/dev/null 2>&1 &)
        fi
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
NF_CACHE_WARM=$'\xef\x81\xad'       # U+F06D fire (prompt cache warm)
NF_CACHE_EXPIRING=$'\xf3\xb1\x97\x97'  # U+F15D7 md-fire-alert (last 20% of the TTL)
NF_CACHE_COLD=$'\xef\x8b\x9c'       # U+F2DC snowflake (prompt cache cold)
NF_CORNER_TL=$'\xee\x82\xba'    # U+E0BA lower-right fill (top-left corner)
NF_CORNER_BL=$'\xee\x82\xbe'    # U+E0BE upper-right fill (bottom-left corner)
NF_CORNER_TR=$'\xee\x82\xb8'    # U+E0B8 lower-left fill -> top-right corner cut
NF_CORNER_BR=$'\xee\x82\xbc'    # U+E0BC upper-left fill -> bottom-right corner cut

# ── Project-colored background (hash session ID -> unique hue) ────────────
RST="\033[0m"
PROJECT_ROOT=$(git -C "$CWD_FULL" rev-parse --show-toplevel 2>/dev/null || echo "$CWD_FULL")
PHASH=$(printf '%s' "${SESSION_ID:-$CWD_FULL}" | cksum | cut -d' ' -f1 || echo "0")

# ── Session topic (Claude Code's native session title) ─────────────────────
# The descriptive label for line 1, sourced from the stdin .session_name
# (SESSION_TITLE): the /rename value if set, else Claude Code's auto-generated
# session title (e.g. "Add session names to status line"), which Claude Code
# writes to the transcript as .aiTitle and serves here. This replaced an earlier
# opt-in hook that called Claude Haiku to synthesize the same kind of label; the
# native title needs no extra API call, credential, or quota. If you upgraded from
# a version that shipped that hook and still have its UserPromptSubmit entry in
# settings.json, Claude Code prints "session-topic-capture.sh: No such file or
# directory" on every prompt (non-blocking): delete that one UserPromptSubmit entry
# to silence it. The old ~/.claude/session-topics/ cache is dead and safe to remove.
# Shown bold after
# the @handle. On by default; STATUSLINE_TOPIC=0 hides it. Control bytes are
# stripped (same as every other JSON-sourced field: removing the ESC byte
# neutralizes any CSI/OSC a model-authored title might contain) and the length is
# capped so it cannot dominate line 1 at a wide viewport; the TOPIC truncation
# rung shrinks it further on real overflow.
if [ "${STATUSLINE_TOPIC:-1}" != "0" ]; then
    TOPIC="${SESSION_TITLE//[$'\001'-$'\037\177']/}"
    [ "$(_clen "$TOPIC")" -gt 40 ] 2>/dev/null && TOPIC="$(_head_cp "$TOPIC" 40)"
fi

# The old look is Classic; explicit/unknown choices use the OS-auto default.
THEME=tokyo-auto
if [ "${STATUSLINE_THEME+x}" = x ]; then
    THEME="$STATUSLINE_THEME"
else
    _THEME_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/cc-statusline/theme"
    if [ -f "$_THEME_FILE" ]; then
        { IFS= read -r THEME <"$_THEME_FILE"; } 2>/dev/null || true
        THEME="${THEME//[[:space:]]/}"
    elif [ -f "$HOME/.claude/statusline-color-overrides.json" ]; then
        # Existing project palettes keep the old look until explicitly changed.
        THEME=classic
    fi
fi
_theme_resolve "$THEME"
THEME="$THEME_RESOLVED"

# Check for manual color override
COLOR_OVERRIDES="$HOME/.claude/statusline-color-overrides.json"
if { [ "$THEME" = "classic" ] || [ "$THEME" = "hue-dark" ]; } && [ -f "$COLOR_OVERRIDES" ]; then
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

# Rendering tokens. Keep Classic escape spelling/order byte-identical.
SEP_CH="│"; SEP2_CH="│"; DOT2_CH="·"
BG1="\033[48;2;${BG_R};${BG_G};${BG_B}m"
TXT_FG="\033[38;2;${TXT_R};${TXT_G};${TXT_B}m"
TXT_BOLD="\033[38;2;${TXT_R};${TXT_G};${TXT_B};1m"
PROJ_FG="\033[38;2;${BG_R};${BG_G};${BG_B}m"
BG2="\033[48;2;0;0;0m"
L2_TXT="\033[38;2;170;170;170m"
L2_DIM="\033[38;2;80;80;80m"
CLR_SAGE="\033[38;2;150;210;150m"
CLR_GOLD="\033[38;2;215;195;125m"
CLR_CORAL="\033[38;2;225;150;150m"
CLR_ICE="\033[38;2;140;180;225m"
CLR_OK="\033[38;2;100;200;120m"
CLR_INC="\033[38;2;225;150;100m"
CLR_BAD="\033[38;2;225;100;100m"
UPD_CLR="$CLR_GOLD"
MODE_CLR="\033[1;38;2;150;100;0m"
BAR_FILL="▰"; BAR_EMPTY="▱"; BAR_PRE=""; BAR_POST=""
CAP1_L="${PROJ_FG}${NF_CORNER_TL}"; CAP1_R="${PROJ_FG}${NF_CORNER_TR}"
CAP2_L="\033[38;2;0;0;0m${NF_CORNER_BL}"; CAP2_R="\033[38;2;0;0;0m${NF_CORNER_BR}"

THEME_STYLE=flat
SEG_JOIN=$'\xee\x82\xb0'; SEG_OPEN=$'\xee\x82\xb2'
SEG_PILL_L=$'\xee\x82\xb6'; SEG_PILL_R=$'\xee\x82\xb4'

# Hex conversion and token assignment use bash printf -v, with no forks.
# All inputs below are trusted palette constants, never user-controlled text.
_theme_rgb() { printf -v THEME_RGB '%d;%d;%d' "0x${1:0:2}" "0x${1:2:2}" "0x${1:4:2}"; }
_theme_fg() { _theme_rgb "$2"; printf -v "$1" '%s' "\033[38;2;${THEME_RGB}m"; }
_theme_palette() {  # bg1, text, separator, bg2, l2 text/dim, good/caution/bad/cold
    _theme_rgb "$1"; BG1="\033[48;2;${THEME_RGB}m"
    _theme_fg TXT_FG "$2"; TXT_BOLD="${TXT_FG}\033[1m"
    _theme_rgb "$3"; IFS=';' read -r SEP_R SEP_G SEP_B <<< "$THEME_RGB"
    _theme_rgb "$4"; BG2="\033[48;2;${THEME_RGB}m"
    _theme_fg CAP2_FG "$4"
    CAP2_L="${CAP2_FG}${NF_CORNER_BL}"; CAP2_R="${CAP2_FG}${NF_CORNER_BR}"
    _theme_fg L2_TXT "$5"; _theme_fg L2_DIM "$6"
    _theme_fg CLR_SAGE "$7"; _theme_fg CLR_GOLD "$8"
    _theme_fg CLR_CORAL "$9"; _theme_fg CLR_ICE "${10}"
    CLR_OK="$CLR_SAGE"; CLR_INC="$CLR_GOLD"; CLR_BAD="$CLR_CORAL"
    UPD_CLR="$CLR_GOLD"; MODE_CLR="${CLR_GOLD}\033[1m"
}

# Segment roles keep their backgrounds separate from the transparent padding.
_theme_roles() {  # handle, topic, directory, branch, status, tail, right
    _theme_rgb "$1"; SEG_HANDLE_BG="$THEME_RGB"
    _theme_rgb "$2"; SEG_TOPIC_BG="$THEME_RGB"
    _theme_rgb "$3"; SEG_DIR_BG="$THEME_RGB"
    _theme_rgb "$4"; SEG_BRANCH_BG="$THEME_RGB"
    _theme_rgb "$5"; SEG_STATUS_BG="$THEME_RGB"
    _theme_rgb "$6"; SEG_TAIL_BG="$THEME_RGB"
    _theme_rgb "$7"; SEG_RIGHT_BG="$THEME_RGB"
}

# One palette block; derived separators/background resets are built afterward.
case "$THEME" in
    hue-dark)  # Project identity inverted onto an 18% tint.
        BG1="\033[48;2;$((BG_R*18/100));$((BG_G*18/100));$((BG_B*18/100))m"
        TXT_FG="$PROJ_FG"; TXT_BOLD="${PROJ_FG}\033[1m"
        SEP_R=$((BG_R*55/100)); SEP_G=$((BG_G*55/100)); SEP_B=$((BG_B*55/100))
        BG2="\033[48;2;14;14;16m"
        L2_TXT="\033[38;2;176;176;176m"; L2_DIM="\033[38;2;100;100;100m"
        CAP1_L="${PROJ_FG}▌"; CAP1_R="${PROJ_FG}▐"
        CAP2_L="$CAP1_L"; CAP2_R="$CAP1_R"
        BAR_FILL="▮"; BAR_EMPTY="▯"
        ;;
    nord)  # Transparent, restrained Nordic colors.
        _theme_palette 000000 d8dee9 4c566a 000000 d8dee9 606a80 a3be8c ebcb8b bf616a 88c0d0
        BG1="\033[49m"; BG2="\033[49m"
        CAP1_L=""; CAP1_R=""; CAP2_L=""; CAP2_R=""
        SEP_CH=" "; SEP2_CH=" "; BAR_FILL="─"; BAR_EMPTY="─"
        ;;
    phosphor)  # CRT green with amber/red alerts preserved.
        _theme_palette 001a08 33cc66 145c2c 001a08 33cc66 2a743c 5dff8a d7c37d e19696 33cc66
        CAP1_L=""; CAP1_R=""; CAP2_L=""; CAP2_R=""
        SEP_CH=">"; SEP2_CH="|"; BAR_FILL="#"; BAR_EMPTY="."
        BAR_PRE="${L2_TXT}["; BAR_POST="${L2_TXT}]"
        ;;
    synthwave)  # Neon gradient on line 1, dusk on line 2.
        _theme_palette ff2a6d ffffff f0e8ff 1a1033 d1c4e9 6b5b85 05d9e8 f9c80e ff2a6d 05d9e8
        _theme_fg CAP1_FG ff2a6d; CAP1_L="${CAP1_FG}${NF_CORNER_TL}"
        _theme_fg CAP1_FG 05d9e8; CAP1_R="${CAP1_FG}${NF_CORNER_TR}"
        TXT_FG+="\033[1m"; TXT_BOLD="$TXT_FG"
        SEP_CH="▸"; SEP2_CH="//"; BAR_FILL="⣿"; BAR_EMPTY="⣀"
        ;;
    tokyo-night)  # Stepped arrows, neon on navy.
        _theme_palette 1a1b26 c0caf5 3b4261 1a1b26 a9b1d6 606987 9ece6a e0af68 f7768e 7dcfff
        _theme_roles 7aa2f7 bb9af7 3b4261 292e42 292e42 292e42 292e42
        _theme_fg SEG_INK 1a1b26; SEG_DIR_FG="$TXT_FG"; SEG_BRANCH_FG="$CLR_SAGE"
        SEG_RIGHT_FG="$CLR_ICE"; _theme_fg SEG_RIGHT_DIM 7883a3; THEME_STYLE=arrow
        SEP2_CH=$'\xee\x82\xb1'; BAR_FILL="━"; BAR_EMPTY="━"
        CAP2_L=""; CAP2_R="\033[38;2;26;27;38m${SEG_JOIN}"
        ;;
    tokyo-day)  # Official folke/tokyonight.nvim Day colors, cdc07ac.
        _theme_palette e1e2e7 3760bf 68709a e1e2e7 3760bf 68709a 587539 8c6c3e c64343 007197
        _theme_roles 3760bf 7847bd c4c8da d0d5e3 d0d5e3 d0d5e3 d0d5e3
        _theme_fg SEG_INK e1e2e7; _theme_fg SEG_DIR_FG 2e5857; SEG_BRANCH_FG="$CLR_SAGE"
        SEG_RIGHT_FG="$TXT_FG"; _theme_fg SEG_RIGHT_DIM 68709a; THEME_STYLE=arrow
        SEP2_CH=$'\xee\x82\xb1'; BAR_FILL="━"; BAR_EMPTY="━"
        CAP2_L=""; CAP2_R="\033[38;2;225;226;231m${SEG_JOIN}"
        ;;
    gruvbox)  # Earth tones and hard arrows.
        _theme_palette 282828 ebdbb2 665c54 282828 ebdbb2 837567 b8bb26 fabd2f fb4934 83a598
        _theme_roles d65d0e d79921 689d6a 504945 504945 504945 d65d0e
        _theme_fg SEG_INK 282828; SEG_DIR_FG="$SEG_INK"; SEG_BRANCH_FG="$TXT_FG"
        SEG_RIGHT_FG="$SEG_INK"; _theme_fg SEG_RIGHT_DIM 48301b
        UPD_CLR="${SEG_INK}\033[1m"; THEME_STYLE=arrow
        BAR_FILL="█"; BAR_EMPTY="░"; BAR_PRE="${L2_TXT}["; BAR_POST="${L2_TXT}]"
        CAP2_L=""; CAP2_R=""
        ;;
    dracula)  # Purple/pink steps with flame joiners.
        _theme_palette 282a36 f8f8f2 6272a4 282a36 f8f8f2 6272a4 50fa7b ffb86c ff5555 8be9fd
        _theme_roles bd93f9 ff79c6 44475a 44475a 44475a 44475a 44475a
        _theme_fg SEG_INK 282a36; SEG_DIR_FG="$TXT_FG"; SEG_BRANCH_FG="$CLR_SAGE"
        SEG_RIGHT_FG="$CLR_ICE"; _theme_fg SEG_RIGHT_DIM a0a4bc; THEME_STYLE=arrow; SEG_JOIN=$'\xee\x83\x80'
        CAP2_L=""; CAP2_R="\033[38;2;40;42;54m${SEG_JOIN}"
        ;;
    catppuccin)  # Mocha capsules; service alerts use a dark surface.
        _theme_palette 1e1e2e cdd6f4 585b70 313244 cdd6f4 7c8098 a6e3a1 f9e2af f38ba8 89dceb
        _theme_roles f5c2e7 cba6f7 89b4fa a6e3a1 313244 313244 f9e2af
        _theme_fg SEG_INK 1e1e2e; SEG_DIR_FG="$SEG_INK"; SEG_BRANCH_FG="$SEG_INK"
        SEG_RIGHT_FG="$SEG_INK"; _theme_fg SEG_RIGHT_DIM 585b70
        UPD_CLR="${SEG_INK}\033[1m"; THEME_STYLE=pill
        BAR_FILL="●"; BAR_EMPTY="○"
        CAP2_L="${CAP2_FG}${SEG_PILL_L}"; CAP2_R="${CAP2_FG}${SEG_PILL_R}"
        ;;
esac
B="${RST}${BG1}"; B2="${RST}${BG2}"
SEP="\033[38;2;${SEP_R};${SEP_G};${SEP_B}m${SEP_CH}"
SEP2="${L2_DIM}${SEP2_CH}${B2}"; DOT2="${L2_DIM}${DOT2_CH}${B2}"
PEER_DIM="\033[38;2;${SEP_R};${SEP_G};${SEP_B}m"
PEER_FG="$TXT_FG"; PEER_BOLD="$TXT_BOLD"; PEER_B="$B"
if [ "$THEME" = synthwave ]; then
    SEP="\033[38;2;${SEP_R};${SEP_G};${SEP_B};1m${SEP_CH}"
    PEER_DIM="\033[38;2;${SEP_R};${SEP_G};${SEP_B};1m"
fi
if [ "$THEME_STYLE" != "flat" ]; then
    SEG_PEER_BG="$SEG_TAIL_BG"
    PEER_FG="$L2_TXT"; PEER_BOLD="${PEER_FG}\033[1m"
    PEER_B="${RST}\033[48;2;${SEG_PEER_BG}m"
    PEER_DIM="$L2_DIM"
    case "$THEME" in tokyo-night|dracula) PEER_DIM="$SEG_RIGHT_DIM" ;; esac
    BG1="\033[49m"  # Padding between left and right groups is transparent.
    CAP1_L=""
    TXT_FG="$SEG_RIGHT_FG"; TXT_BOLD="${TXT_FG}\033[1m"
    B="${RST}\033[48;2;${SEG_RIGHT_BG}m"
    if [ "$THEME_STYLE" = "pill" ]; then
        SEP="${RST}\033[38;2;${SEG_RIGHT_BG}m${SEG_PILL_L}"
        CAP1_R="\033[38;2;${SEG_RIGHT_BG}m${SEG_PILL_R}"
        SEP2="${RST}${CAP2_FG}${SEG_PILL_R}${RST} ${CAP2_FG}${SEG_PILL_L}${B2}"
    else
        SEP="${RST}\033[38;2;${SEG_RIGHT_BG}m${SEG_OPEN}"
        CAP1_R="\033[38;2;${SEG_RIGHT_BG}m${SEG_JOIN}"
    fi
fi
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
if   [ "$H" -gt 2 ]; then TIME_CLR="$CLR_CORAL"   # coral: 3h+
elif [ "$H" -gt 0 ]; then TIME_CLR="$CLR_GOLD"   # gold: 1-3h
else                      TIME_CLR="$CLR_SAGE"   # sage: <1h
fi

# ── Bar builder ─────────────────────────────────────────────────────────────
make_bar() {
    local pct=${1:-0} width=${2:-5} fill_clr="$3" empty_clr="$4" bar="$BAR_PRE"
    pct=${pct%%.*}  # safety: strip decimal
    case "$pct" in ''|*[!0-9]*) pct=0 ;; esac  # non-numeric -> 0 (set -u arith)
    local filled=$((pct * width / 100))
    [ "$pct" -gt 0 ] 2>/dev/null && [ "$filled" -eq 0 ] && filled=1
    [ "$filled" -gt "$width" ] && filled=$width
    [ "$filled" -lt 0 ] && filled=0
    local empty=$((width - filled))
    for ((i=0; i<filled; i++)); do bar+="${fill_clr}${BAR_FILL}"; done
    for ((i=0; i<empty; i++));  do bar+="${empty_clr}${BAR_EMPTY}"; done
    printf "%b" "${bar}${BAR_POST}"
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
# Uses the fixed/anchored window model: usage accumulates from zero and the whole
# window resets at a boundary. This was the original assumption, was briefly hedged
# toward sliding on the strength of a public thread (claude-code#62223), and is now
# CONFIRMED anchored by direct measurement (2026-08-13). Sampling a live token's 5h
# window across its reset showed: resets_at held at a FIXED wall-clock boundary on
# every poll, used% flat (no decay) approaching it, then a single step 32%->0% at
# the boundary with resets_at jumping forward by exactly the window length (+5h). A
# sliding window would creep its reset forward each poll and shed usage continuously;
# neither happened, so elapsed here is well-defined and the projected magnitude is
# valid. (Measured on one account's anthropic-ratelimit-unified-* headers; to
# re-check, ask whether used% decays between polls with no new usage -- that would
# indicate sliding.)
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
    if   [ "$projected" -gt 115 ]; then printf '%b↑' "$CLR_CORAL"
    elif [ "$projected" -gt 85  ]; then printf '%b→' "$CLR_GOLD"
    fi
}

# ── Count visible columns (ANSI-aware, multi-string in one perl call) ──────
# Usage: measure_cols "str1" "str2" ... -> outputs one number per line
measure_cols() {
    local args=()
    for s in "$@"; do args+=("$(printf '%b' "$s")"); done
    printf '%s\n' "${args[@]}" | perl -ne '
        s/\e\]8;;.*?(?:\a|\e\\)//g;   # OSC 8 hyperlink open/close (zero width)
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
L1_PREFIX="${RST}${CAP1_L}${BG1}"
# GitHub service-status icon (empty unless the repo has a github.com remote and
# STATUSLINE_GITHUB_STATUS is not 0; populated in the GitHub-status block below,
# before assemble_l1 is first called). Declared here so the function never
# references an unset var under set -u regardless of ordering.
GH_SEG=""; GH_GLYPH=""
# The segmented builder receives the same truncated values as the flat path.
# Every cap/joiner is assembled before measure_cols, including the closing cap.
_seg_add() {  # background RGB, foreground SGR, content
    local bg="$1" fg="$2" text="$3"
    [ -n "$text" ] || return 0
    if [ -z "$SEG_PREV_BG" ]; then
        L1C+="${RST}"
        [ "$THEME_STYLE" = "pill" ] && L1C+="\033[38;2;${bg}m${SEG_PILL_L}"
        L1C+="\033[48;2;${bg}m${fg} ${text} "
    elif [ "$bg" = "$SEG_PREV_BG" ]; then
        L1C+="${fg}${text} "
    elif [ "$THEME_STYLE" = "pill" ]; then
        L1C+="${RST}\033[38;2;${SEG_PREV_BG}m${SEG_PILL_R}${RST} \033[38;2;${bg}m${SEG_PILL_L}\033[48;2;${bg}m${fg} ${text} "
    else
        L1C+="${RST}\033[48;2;${bg}m\033[38;2;${SEG_PREV_BG}m${SEG_JOIN}${fg} ${text} "
    fi
    SEG_PREV_BG="$bg"
}
_assemble_l1_seg() {
    L1C="${RST}"; SEG_PREV_BG=""
    if [ "$LAYOUT" != "phone" ]; then
        [ -n "$SESSION_HANDLE" ] && _seg_add "$SEG_HANDLE_BG" "${SEG_INK}\033[1m" "@${SESSION_HANDLE}"
        [ -n "$PEER_SEG" ] && _seg_add "$SEG_PEER_BG" "$PEER_FG" "$PEER_SEG"
        [ -n "$TOPIC" ] && _seg_add "$SEG_TOPIC_BG" "${SEG_INK}\033[1m" "$TOPIC"
    fi
    _seg_add "$SEG_DIR_BG" "$SEG_DIR_FG" "${NF_FOLDER} ${DIR}"
    if [ -n "$BRANCH" ]; then
        local status=""
        [ -n "$GIT_STATUS" ] && status=" ${CLR_GOLD}${GIT_STATUS}"
        # Pastel branch capsules need dark ink for the dirty markers too.
        [ "$THEME_STYLE" = "pill" ] && [ -n "$status" ] && status=" ${SEG_INK}${GIT_STATUS}"
        _seg_add "$SEG_BRANCH_BG" "$SEG_BRANCH_FG" "${NF_GIT} ${BRANCH}${status}"
    fi
    [ "$LAYOUT" = "phone" ] && [ -n "$PEER_SEG" ] && _seg_add "$SEG_PEER_BG" "$PEER_FG" "$PEER_SEG"
    [ -n "$GH_GLYPH" ] && _seg_add "$SEG_STATUS_BG" "$CLR_OK" "$GH_GLYPH"
    if [ "$LAYOUT" != "phone" ]; then
        local tail="$AGENT"
        [ -n "$MODE" ] && tail+="${tail:+ }${MODE_CLR}${MODE}"
        [ -n "$K8S_CTX" ] && tail+="${tail:+ }${L2_TXT}${NF_K8S} ${K8S_CTX}"
        [ -n "$tail" ] && _seg_add "$SEG_TAIL_BG" "$L2_TXT" "$tail"
    fi
    local end="$SEG_JOIN"
    [ "$THEME_STYLE" = "pill" ] && end="$SEG_PILL_R"
    L1C+="${RST}\033[38;2;${SEG_PREV_BG}m${end}${RST}"
}

assemble_l1() {
    if [ "$THEME_STYLE" != "flat" ]; then _assemble_l1_seg; return; fi
    L1C="${L1_PREFIX}"
    # Phone: folder + branch, with peer counts only while they fit.
    # Topic, agent, mode and k8s are the first
    # things a narrow viewport cannot afford, and the folder answers "which
    # session am I looking at" more reliably than any of them.
    if [ "$LAYOUT" = "phone" ]; then
        L1C+=" ${TXT_FG}${NF_FOLDER} ${DIR} ${B}"
        if [ -n "$BRANCH" ]; then
            L1C+="${SEP}${B} ${TXT_FG}${NF_GIT} ${BRANCH}${B}"
            [ -n "$GIT_STATUS" ] && L1C+=" ${TXT_FG}${GIT_STATUS}${B}"
        fi
        [ -n "$PEER_SEG" ] && L1C+=" ${PEER_SEG}${B}"
        L1C+="$GH_SEG"
        L1C+=" "
        return
    fi
    [ -n "$SESSION_HANDLE" ] && L1C+=" ${TXT_BOLD}@${SESSION_HANDLE}${B}"
    [ -n "$PEER_SEG" ] && L1C+=" ${PEER_SEG}${B}"
    if [ -n "$SESSION_HANDLE" ] || [ -n "$PEER_SEG" ]; then L1C+=" ${SEP}${B}"; fi
    [ -n "$TOPIC" ] && L1C+=" ${TXT_BOLD}${TOPIC}${B} ${SEP}${B}"
    L1C+=" ${TXT_FG}${NF_FOLDER} ${DIR} ${B}"
    if [ -n "$BRANCH" ]; then
        L1C+="${SEP}${B} ${TXT_FG}${NF_GIT} ${BRANCH}${B}"
        [ -n "$GIT_STATUS" ] && L1C+=" ${TXT_FG}${GIT_STATUS}${B}"
    fi
    L1C+="$GH_SEG"
    [ -n "$AGENT" ] && L1C+=" ${TXT_FG}${AGENT}${B}"
    [ -n "$MODE" ]  && L1C+=" ${SEP}${B} ${MODE_CLR}${MODE}${B}"
    [ -n "$K8S_CTX" ] && L1C+=" ${SEP}${B} ${TXT_FG}${NF_K8S} ${K8S_CTX}${B}"
    L1C+=" "
}

# ── Line 2 base content (model / effort / profile / clock / context) ────────
CTX_CLR=$(pct_color "$PCT")
# A held GPT value (see the context-hold block) is drawn in the dim separator
# gray, bar and percentage alike, in both layouts: same width, visibly stale.
[ "$CTX_STALE" = "1" ] && CTX_CLR="$L2_DIM"
CTX_BAR=$(make_bar "$PCT" 7 "$CTX_CLR" "$L2_DIM")
# Effort level color
case $EFFORT in
    max|xhigh|high) EFFORT_CLR="$CLR_SAGE" ;;            # sage: thinking hard
    low)            EFFORT_CLR="$CLR_CORAL" ;;           # coral: warning
    *)              EFFORT_CLR="$L2_TXT" ;;  # gray: medium/unknown
esac

# ── Session usage value beside the clock ───────────────────────────────────
# Claude keeps its native cost.total_cost_usd as "$N.NN". GPT never shows that
# field because Claude Code prices GPT tokens with Claude rates; it shows the
# transcript-derived "N.NN cr" estimate when available instead. Both forms are
# built here so measure_cols includes their real width. STATUSLINE_COST controls
# only Claude dollars; STATUSLINE_GPT_CREDITS controls GPT credits.
COST_SEG=""
if [ "$GPT_ACTIVE" != "1" ] && [ "${STATUSLINE_COST:-1}" != "0" ] \
    && [ "$(LC_ALL=C awk -v c="$COST_USD" 'BEGIN{print (c>0)?1:0}' 2>/dev/null)" = "1" ]; then
    COST_FMT=$(LC_ALL=C awk -v c="$COST_USD" 'BEGIN{ if (c>0 && c<0.005) printf "<0.01"; else printf "%.2f", c }' 2>/dev/null)
    COST_SEG=" ${DOT2} ${L2_TXT}\$${COST_FMT}${B2}"
elif [ "$GPT_ACTIVE" = "1" ] && [ -n "$GPT_CREDITS_UNITS" ]; then
    CREDITS_FMT=$(LC_ALL=C awk -v u="$GPT_CREDITS_UNITS" 'BEGIN {
        if      (u >= 999995000000000000) printf "%.2fT", u / 1000000000000000000
        else if (u >= 999995000000000)    printf "%.2fB", u / 1000000000000000
        else if (u >= 999995000000)       printf "%.2fM", u / 1000000000000
        else if (u >= 999995000)          printf "%.2fk", u / 1000000000
        else                              printf "%.2f",  u / 1000000
    }' 2>/dev/null)
    [[ "$CREDITS_FMT" =~ ^[0-9]+\.[0-9]{2}[kMBT]?$ ]] \
        && COST_SEG=" ${DOT2} ${L2_TXT}${CREDITS_FMT} cr${B2}"
fi

L2C="${RST}${CAP2_L}${BG2} ${L2_TXT}${NF_MODEL} ${MODEL} ${DOT2} ${EFFORT_CLR}${EFFORT}${B2}"
[ -n "$PROFILE_LABEL" ] && L2C+=" ${DOT2} ${PROFILE_FG}${PROFILE_LABEL}${B2}"
L2C+=" ${SEP2} ${L2_TXT}${NF_CLOCK} ${TIME_CLR}${TIME}${B2}${COST_SEG} ${SEP2} ${CTX_BAR} ${CTX_CLR}${PCT}%${B2} ${L2_TXT}of ${CTX_SIZE_K}k"

# ── Rate-limit detail candidates (full / compact / minimal) ────────────────
# Build all three tiers up front so the widest one that actually FITS can be
# picked from a real measurement below. The old code chose the tier from a
# fixed reserve that could not see 3-digit percentages, long reset countdowns,
# or the trailing service icon, which let line 2 overflow and get dropped.
PACE_ON=1; [ "${STATUSLINE_PACE:-1}" = "0" ] && PACE_ON=0
# Claude uses its known durations; GPT uses the exact duration carried in the
# Codex snapshot after the window is classified as 5h or weekly.
RATE_FULL=""; RATE_COMPACT=""; RATE_MINIMAL=""
FIVE_CLR=""; FIVE_ARROW=""; FIVE_BAR=""; FIVE_TIME=""
SEVEN_CLR=""; SEVEN_ARROW=""; SEVEN_BAR=""; SEVEN_TIME=""
RATE_READY=0
if [ "$GPT_ACTIVE" = "1" ]; then
    { [ -n "${FIVE_PCT:-}" ] || [ -n "${SEVEN_PCT:-}" ]; } && RATE_READY=1
else
    [ -n "${FIVE_PCT:-}" ] && [ -n "${SEVEN_PCT:-}" ] && RATE_READY=1
fi
if [ "$RATE_READY" = "1" ]; then
    # Each Codex window is optional. Claude's normal two-window path assembles
    # exactly the same strings as before, while a weekly-only GPT snapshot still
    # gets a useful rate segment.
    if [ -n "${FIVE_PCT:-}" ]; then
        FIVE_CLR=$(pct_color "$FIVE_PCT")
        [ "$PACE_ON" = "1" ] && FIVE_ARROW=$(pace_arrow "$FIVE_PCT" "$FIVE_RESET_TS" "$FIVE_DURATION" "$NOW")
        FIVE_BAR=$(make_bar "$FIVE_PCT" 5 "$FIVE_CLR" "$L2_DIM")
        FIVE_TIME=$(format_reset "$FIVE_RESET_TS")
        RATE_FULL=" ${SEP2} ${L2_TXT}5h ${FIVE_BAR} ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
        [ -n "$FIVE_TIME" ] && RATE_FULL+=" ${L2_TXT}${FIVE_TIME}${B2}"
        RATE_COMPACT=" ${SEP2} ${L2_TXT}5h ${FIVE_BAR} ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
        RATE_MINIMAL=" ${SEP2} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
    fi
    if [ -n "${SEVEN_PCT:-}" ]; then
        SEVEN_CLR=$(pct_color "$SEVEN_PCT")
        [ "$PACE_ON" = "1" ] && SEVEN_ARROW=$(pace_arrow "$SEVEN_PCT" "$SEVEN_RESET_TS" "$SEVEN_DURATION" "$NOW")
        SEVEN_BAR=$(make_bar "$SEVEN_PCT" 5 "$SEVEN_CLR" "$L2_DIM")
        SEVEN_TIME=$(format_reset "$SEVEN_RESET_TS")
        RATE_FULL+=" ${SEP2} ${L2_TXT}7d ${SEVEN_BAR} ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
        [ -n "$SEVEN_TIME" ] && RATE_FULL+=" ${L2_TXT}${SEVEN_TIME}${B2}"
        RATE_COMPACT+=" ${SEP2} ${L2_TXT}7d ${SEVEN_BAR} ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
        if [ -n "${FIVE_PCT:-}" ]; then
            RATE_MINIMAL+=" ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
        else
            RATE_MINIMAL=" ${SEP2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
        fi
    fi
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

# ── Prompt-cache cooldown timer (line 2, after the hit rate) ───────────────
# How long until the main conversation's prompt cache goes cold, from Claude
# Code's documented stdin .prompt_cache (v2.1.251+). Claude Code re-renders at
# expires_at, so the flip to cold needs no refreshInterval; the minutes only
# tick while idle with one. Minute granularity on purpose: mm:ss would be
# stale between renders and change width every second.
#   fire 42m       warm; minutes left rounded up ("<1m" in the last minute)
#   fire-alert 5m  warm, last 20% of the TTL (coral)
#   ...·5m         dim tag when the TTL is 5m (API key / usage credits)
#   snowflake 184k cold: the next message re-caches ~184k tokens ("cold" if unknown)
# Cold means warm=false or a valid expires_at already passed. Hidden when the
# object is absent (older Claude Code, before the first API response),
# caching_observed is false ("off" is not "cold"), or warm=true arrives with an
# invalid ttl/expires_at (missing data does not prove the cache is cold).
# Hidden on any OpenAI-backed pane (effective model, so a GPT agent pane that
# reports its Claude parent on stdin is caught too), independent of
# STATUSLINE_GPT_LIMITS: Claude Code stamps its own Anthropic 5m/1h TTL on
# those responses, while OpenAI reports no expiry and the Codex backend's
# lifetime is undocumented. On by default; hide with STATUSLINE_CACHE_TIMER=0.
PC_OPENAI=0
case "${EFFECTIVE_MODEL_ID%%\[*}" in *gpt-*|*openai*) PC_OPENAI=1 ;; esac
TIMER_SEG=""
if [ "${STATUSLINE_CACHE_TIMER:-1}" != "0" ] && [ "$PC_OPENAI" = "0" ] && [ "$PC_OBS" = "true" ]; then
    case "$PC_TTL" in 5m) PC_TTL_S=300 ;; 1h) PC_TTL_S=3600 ;; *) PC_TTL_S=0 ;; esac
    PC_REM=""
    if [ "$PC_WARM" = "false" ]; then
        PC_REM=0
    elif [ "$PC_WARM" = "true" ] && [[ "$PC_EXP" =~ ^[0-9]{1,12}$ ]] && [ "$PC_TTL_S" -gt 0 ]; then
        PC_REM=$((PC_EXP - NOW))
        [ "$PC_REM" -gt "$PC_TTL_S" ] && PC_REM=$PC_TTL_S   # clock-skew cap
    fi
    if [ -z "$PC_REM" ]; then
        :
    elif [ "$PC_REM" -gt 0 ]; then
        PC_FRAC=$((PC_REM * 100 / PC_TTL_S))
        PC_ICON="$NF_CACHE_WARM"
        if   [ "$PC_FRAC" -gt 50 ]; then PC_CLR="$CLR_SAGE"
        elif [ "$PC_FRAC" -gt 20 ]; then PC_CLR="$CLR_GOLD"
        else PC_CLR="$CLR_CORAL"; PC_ICON="$NF_CACHE_EXPIRING"; fi
        if [ "$PC_REM" -lt 60 ]; then PC_TXT="<1m"; else PC_TXT="$(((PC_REM + 59) / 60))m"; fi
        TIMER_SEG=" ${PC_CLR}${PC_ICON} ${PC_TXT}"
        [ "$PC_TTL" = "5m" ] && TIMER_SEG+="${L2_DIM}·5m"
    else
        if ! [[ "$PC_RECACHE" =~ ^[0-9]{1,15}$ ]]; then PC_TXT="cold"
        elif [ "$PC_RECACHE" -ge 1000000 ]; then
            PC_TXT="$((PC_RECACHE / 1000000)).$((PC_RECACHE % 1000000 / 100000))M"
        elif [ "$PC_RECACHE" -ge 1000 ]; then PC_TXT="$((PC_RECACHE / 1000))k"
        else PC_TXT="$PC_RECACHE"; fi
        TIMER_SEG=" ${CLR_ICE}${NF_CACHE_COLD} ${PC_TXT}"
    fi
    [ -n "$TIMER_SEG" ] && TIMER_SEG+="${B2}"
fi

# ── Provider service status (read before width reservation) ─────────────────
# Claude sessions keep their existing summary source. Opt-in GPT sessions use
# only OpenAI's exact "Codex API" component, with a separate cache and test
# seams, so a GPT render can never inherit Claude's icon or overall page state.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
GENERIC_SVC_FETCH="${CC_STATUSLINE_SVC_FETCH:-${SCRIPT_DIR:-$HOME/.local/share/cc-statusline}/claude-status-fetch.sh}"
if [ "$GPT_ACTIVE" = "1" ]; then
    SVC_CACHE="${CC_STATUSLINE_CODEX_SVC_CACHE:-$(_state_dir)/codex-status}"
    SVC_FETCH="${CC_STATUSLINE_CODEX_SVC_FETCH:-$GENERIC_SVC_FETCH}"
    SVC_PAGE_URL="https://status.openai.com/"
    if [ -x "$SVC_FETCH" ]; then
        SVC_AGE=9999
        [ -f "$SVC_CACHE" ] && SVC_AGE=$(($(date +%s) - $(_file_mtime "$SVC_CACHE")))
        if [ "$SVC_AGE" -ge 60 ]; then
            (CC_STATUSLINE_SVC_CACHE="$SVC_CACHE" \
             CC_STATUSLINE_SVC_URL="https://status.openai.com/api/v2/components.json" \
             CC_STATUSLINE_SVC_COMPONENT="Codex API" \
             "$SVC_FETCH" >/dev/null 2>/dev/null &)
        fi
    fi
else
    SVC_CACHE="${CC_STATUSLINE_SVC_CACHE:-$(_state_dir)/service-status}"
    SVC_FETCH="$GENERIC_SVC_FETCH"
    SVC_PAGE_URL="https://status.claude.com"
    if [ -x "$SVC_FETCH" ]; then
        SVC_AGE=9999
        [ -f "$SVC_CACHE" ] && SVC_AGE=$(($(date +%s) - $(_file_mtime "$SVC_CACHE")))
        if [ "$SVC_AGE" -ge 60 ]; then
            # Pass the resolved cache path so the fetcher writes exactly where we read.
            (CC_STATUSLINE_SVC_CACHE="$SVC_CACHE" "$SVC_FETCH" >/dev/null 2>/dev/null &)
        fi
    fi
fi
# OSC 8 hyperlinks on the status glyphs (Cmd/Ctrl+click -> the status page).
# On by default; opt OUT with STATUSLINE_HYPERLINKS=0. Only fixed glyphs get
# wrapped, never truncation-ladder text, so a slice can never cut mid-escape;
# measure_cols strips the OSC 8 wrapper so the link stays zero-width. Terminals
# without OSC 8 support swallow the sequence (icon shows as plain text). The
# open/close are literal \033/\a like the rest of the script (final printf '%b'
# and measure_cols both expand them); empty when disabled.
GH_LINK_OPEN="" GH_LINK_CLOSE="" SVC_LINK_OPEN="" SVC_LINK_CLOSE=""
if [ "${STATUSLINE_HYPERLINKS:-1}" != "0" ]; then
    GH_LINK_OPEN='\033]8;;https://www.githubstatus.com\a';  GH_LINK_CLOSE='\033]8;;\a'
    SVC_LINK_OPEN="\033]8;;${SVC_PAGE_URL}\a";             SVC_LINK_CLOSE='\033]8;;\a'
fi
SVC_SEG=""
if [ -f "$SVC_CACHE" ]; then
    case "$(head -1 "$SVC_CACHE" 2>/dev/null)" in
        operational)                     SVC_SEG=" ${SEP2} ${CLR_OK}${SVC_LINK_OPEN}✓${SVC_LINK_CLOSE}${B2}" ;;
        incident:*)                      SVC_SEG=" ${SEP2} ${CLR_INC}${SVC_LINK_OPEN}⚠${SVC_LINK_CLOSE}${B2}" ;;
        degraded_performance:*)          SVC_SEG=" ${SEP2} ${CLR_GOLD}${SVC_LINK_OPEN}~${SVC_LINK_CLOSE}${B2}" ;;
        partial_outage:*|major_outage:*) SVC_SEG=" ${SEP2} ${CLR_BAD}${SVC_LINK_OPEN}✗${SVC_LINK_CLOSE}${B2}" ;;
    esac
fi

# ── Update indicator (cc-statusline itself; line 1, right-aligned) ──────────
# On by default; opt OUT with STATUSLINE_UPDATE_CHECK=0. Shows a gold
# "⇡ X.Y.Z" (hyperlinked to that release's page) at the RIGHT edge of line 1
# when the latest GitHub release is newer than the VERSION file installed next
# to this script, and nothing at all otherwise: a current install renders
# exactly as before. cc-statusline-update-fetch.sh refreshes the per-user cache
# in the background at most once an hour (the .fetching marker also throttles
# retries while offline, so a dead network costs one curl per hour, not one
# per render). Placement happens in the padding pass at the bottom: the
# segment is dropped into line 1's padding zone (the columns line 2 already
# occupies), so it costs nothing on a typical render and is simply omitted
# when line 1 is the wider line and appending it would breach TARGET. It is a
# fixed, non-sliceable segment, so wrapping it in OSC 8 is safe (see the
# hyperlink invariants above). Both version strings are shape-checked before
# use: the cached tag comes off the network and ends up inside a terminal
# escape, so anything but a bare v?MAJOR.MINOR.PATCH hides the indicator.
# Test seams: CC_STATUSLINE_UPDATE_CACHE (cache path), CC_STATUSLINE_UPDATE_FETCH
# (fetcher path; a non-executable path disables spawning).
UPD_SEG=""
_ver_gt() {  # true when MAJOR.MINOR.PATCH $1 is newer than $2 (bare, no "v")
    local a1 a2 a3 b1 b2 b3
    IFS=. read -r a1 a2 a3 <<<"$1"
    IFS=. read -r b1 b2 b3 <<<"$2"
    [ "$((10#$a1))" -ne "$((10#$b1))" ] && { [ "$((10#$a1))" -gt "$((10#$b1))" ]; return; }
    [ "$((10#$a2))" -ne "$((10#$b2))" ] && { [ "$((10#$a2))" -gt "$((10#$b2))" ]; return; }
    [ "$((10#$a3))" -gt "$((10#$b3))" ]
}
if [ "${STATUSLINE_UPDATE_CHECK:-1}" != "0" ]; then
    UPD_CACHE="${CC_STATUSLINE_UPDATE_CACHE:-$(_state_dir)/update-check}"
    UPD_FETCH="${CC_STATUSLINE_UPDATE_FETCH:-${SCRIPT_DIR:-$HOME/.local/share/cc-statusline}/cc-statusline-update-fetch.sh}"
    UPD_INTERVAL=3600
    if [ -x "$UPD_FETCH" ]; then
        UPD_NOW=$(date +%s)
        UPD_AGE=9999
        [ -f "$UPD_CACHE" ] && UPD_AGE=$((UPD_NOW - $(_file_mtime "$UPD_CACHE")))
        if [ "$UPD_AGE" -ge "$UPD_INTERVAL" ] || [ "$UPD_AGE" -lt 0 ]; then
            # The marker is touched BEFORE spawning, so concurrent sessions
            # and failed attempts (cache untouched) share one attempt per hour.
            UPD_MARK="$UPD_CACHE.fetching"
            UPD_MARK_AGE=9999
            [ -f "$UPD_MARK" ] && UPD_MARK_AGE=$((UPD_NOW - $(_file_mtime "$UPD_MARK")))
            if [ "$UPD_MARK_AGE" -ge "$UPD_INTERVAL" ] || [ "$UPD_MARK_AGE" -lt 0 ]; then
                touch "$UPD_MARK" 2>/dev/null || true
                (CC_STATUSLINE_UPDATE_CACHE="$UPD_CACHE" "$UPD_FETCH" >/dev/null 2>/dev/null &)
            fi
        fi
    fi
    # Installed version: the VERSION file next to this script (brew libexec,
    # install.sh prefix and the dev tree all ship it as a sibling), with the
    # parent dir as a fallback to match the fetchers' lookup.
    UPD_LOCAL=$({ cat "${SCRIPT_DIR:-.}/VERSION" "${SCRIPT_DIR:-.}/../VERSION"; } 2>/dev/null | head -1)
    UPD_LATEST=""
    [ -f "$UPD_CACHE" ] && UPD_LATEST=$(head -1 "$UPD_CACHE" 2>/dev/null || true)
    UPD_VER_RE='^v?[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'
    if [[ "$UPD_LATEST" =~ $UPD_VER_RE ]] && [[ "$UPD_LOCAL" =~ $UPD_VER_RE ]] \
       && _ver_gt "${UPD_LATEST#v}" "${UPD_LOCAL#v}"; then
        UPD_LINK_OPEN="" UPD_LINK_CLOSE=""
        if [ "${STATUSLINE_HYPERLINKS:-1}" != "0" ]; then
            UPD_LINK_OPEN="\033]8;;https://github.com/vtmocanu/cc-statusline/releases/tag/v${UPD_LATEST#v}\a"
            UPD_LINK_CLOSE='\033]8;;\a'
        fi
        UPD_SEG="${SEP}${B} ${UPD_CLR}${UPD_LINK_OPEN}⇡ ${UPD_LATEST#v}${UPD_LINK_CLOSE}${B} "
    fi
fi

# ── Peer sessions in this repo (line 1, after the handle) ──────────────────────
# On by default; opt OUT with STATUSLINE_PEERS=0. Counts EVERY live session
# working in the same repository, this one included, by state, so all of the
# repo's sessions show the same repo-wide total (up to each one's own render
# moment; the split differs by design where a session waits on you, since it
# counts itself as ○ while the others count it as ?) and a multi-session setup
# shows at a glance which need attention:
#   ⚙N busy  (a turn, background subagent, or similar is running)
#   ◷N shell (the turn ended but background shells are still running, e.g. a
#            watcher that will wake the session when a delegated run finishes)
#   ?N asks  (idle, and its last reply asked you something: a pending
#            AskUserQuestion, or the final line of its last text ends with "?").
#            Drawn in reverse video so it stands out. The session showing the
#            segment never counts itself here (you are already looking at it);
#            it falls to ○ instead
#   ○N idle  (idle and asked nothing: probably finished, NOT proof of it).
# The count this session belongs to is bracketed ([⚙N], [◷N] or [○N]), so each
# session shows its own state within the repo-wide picture.
# The ? test is a HINT from the transcript tail, not a guarantee.
# Zero counts are omitted, and the whole segment is absent unless at least one
# OTHER session shares the repo, so a solo session renders exactly as before.
# Source: the same UNDOCUMENTED per-session registry as the @handle
# (~/.claude/sessions/<pid>.json: .sessionId, .pid, .status, .cwd). Only
# Claude Code sessions count: Codex threads attached through session-peers shims
# register there too (.entrypoint "codex"), but they are Codex runs helping a
# Claude session, not sessions of their own. An entry counts only when its pid
# is alive (registry files can outlive a crashed process) and its .cwd sits
# inside one of this repo's worktrees: one `git worktree list` per render covers
# linked worktrees at any path, with no per-peer git call. Unknown .status
# values are ignored. An idle peer's transcript is found by session id under
# ~/.claude/projects/*/ (no reliance on how Claude Code names those folders) and
# only its last 300 lines are read. Counts follow the handle (or lead when it
# is hidden). Phone counts follow directory/branch. The whole segment drops
# after K8S on wide layouts and first on phones; it is never sliced.
# Test seams: CC_STATUSLINE_SESSIONS_DIR, CC_STATUSLINE_PROJECTS_DIR.
PEER_SEG=""
if [ "${STATUSLINE_PEERS:-1}" != "0" ] && [ -n "$SESSION_ID" ]; then
    _PEER_DIR="${CC_STATUSLINE_SESSIONS_DIR:-$HOME/.claude/sessions}"
    _PROJ_DIR="${CC_STATUSLINE_PROJECTS_DIR:-$HOME/.claude/projects}"
    _PEER_WTS=""
    [ -d "$_PEER_DIR" ] && _PEER_WTS=$(git -C "$CWD_FULL" worktree list --porcelain 2>/dev/null \
        | sed -n 's/^worktree //p' || true)
    if [ -n "$_PEER_WTS" ]; then
        _in_repo() {  # _in_repo <path>: is it one of this repo's worktrees, or under one?
            local w
            while IFS= read -r w; do
                [ -n "$w" ] || continue
                case "$1" in "$w"|"$w"/*) return 0 ;; esac
            done <<<"$_PEER_WTS"
            return 1
        }
        P_BUSY=0 P_SHELL=0 P_ASK=0 P_IDLE=0 P_OTHERS=0 P_SELF=""
        _P_IDLE_SIDS=""   # idle peers (not this session) whose transcript to check
        # Registry files are joined with an RS byte and parsed one by one
        # (fromjson?), so a malformed or half-written file is skipped instead of
        # aborting the read for every session after it. Files come both compact
        # and pretty-printed, which rules out line-based parsing.
        while IFS=$'\t' read -r _p_sid _p_pid _p_status _p_cwd; do
            case "$_p_pid" in ''|0|*[!0-9]*) continue ;; esac   # kill -0 0 probes our own group
            kill -0 "$_p_pid" 2>/dev/null || continue
            if ! _in_repo "$_p_cwd"; then
                # Git reports physical paths; the registry may hold a symlinked
                # one (macOS /tmp vs /private/tmp). Resolve only on a miss, so
                # the common case costs no subshell.
                _p_phys=$(cd "$_p_cwd" 2>/dev/null && pwd -P) || continue
                _in_repo "$_p_phys" || continue
            fi
            case "$_p_status" in
                busy)  P_BUSY=$((P_BUSY + 1)) ;;
                shell) P_SHELL=$((P_SHELL + 1)) ;;
                idle)
                    if [ "$_p_sid" = "$SESSION_ID" ]; then
                        P_IDLE=$((P_IDLE + 1))
                    else
                        # Classified in one batch below; until then it is idle.
                        P_IDLE=$((P_IDLE + 1))
                        # The id becomes a file name and a JSON string: only a
                        # plain id is looked up, anything else stays idle.
                        case "$_p_sid" in ''|*[!A-Za-z0-9_-]*) ;; *) _P_IDLE_SIDS+="$_p_sid " ;; esac
                    fi ;;
                *)     continue ;;
            esac
            if [ "$_p_sid" = "$SESSION_ID" ]; then P_SELF="$_p_status"; else P_OTHERS=$((P_OTHERS + 1)); fi
        done < <(for _p_f in "$_PEER_DIR"/*.json; do
                     [ -f "$_p_f" ] && { cat "$_p_f"; printf '\036'; }
                 done 2>/dev/null | jq -Rrs '
                     split("\u001e")[] | fromjson? | objects
                     | select(.entrypoint != "codex")
                     | [(.sessionId // "" | tostring), (.pid // "" | tostring),
                        (.status // "" | tostring), (.cwd // "" | tostring)] | @tsv' 2>/dev/null || true)
        # "?" check, one jq pass for every idle peer: each transcript tail is
        # preceded by a {"__peer":id} marker. A peer asks when an AskUserQuestion
        # call has no tool_result yet (answered and cancelled prompts both write
        # one), or when its last assistant block is text whose final non-blank
        # line ends with "?" (trailing markdown stripped). Lines are prefiltered
        # to assistant records and tool results; fromjson? skips any line the
        # tail cut in half.
        if [ -n "$_P_IDLE_SIDS" ]; then
            P_ASK=$(for _p_sid in $_P_IDLE_SIDS; do
                for _p_tr in "$_PROJ_DIR"/*/"$_p_sid".jsonl; do
                    [ -f "$_p_tr" ] || break
                    printf '{"__peer":"%s"}\n' "$_p_sid"
                    tail -n 300 "$_p_tr" 2>/dev/null | grep -F -e '"assistant"' -e '"tool_result"' || true
                    break
                done
            done 2>/dev/null | jq -nR '
                reduce (inputs | fromjson? | objects) as $r ({cur: null, s: {}};
                  if $r.__peer then .cur = $r.__peer | .s[.cur] = {pend: {}, last: "no"}
                  elif .cur == null then .
                  elif $r.type == "assistant" and ($r.message.content | type) == "array" then
                    reduce $r.message.content[] as $c (.;
                      if $c.type == "tool_use" then
                        (if $c.name == "AskUserQuestion" then .s[.cur].pend[($c.id // "?") | tostring] = true else . end)
                        | .s[.cur].last = "no"
                      elif $c.type == "text" then
                        .s[.cur].last = ($c.text | tostring | split("\n") | map(select(test("\\S"))) | last // ""
                                         | gsub("[\\s*_`)\\]]+$"; "")
                                         | if endswith("?") then "ask" else "no" end)
                      else . end)
                  elif ($r.message.content | type) == "array" then
                    reduce ($r.message.content[] | objects | select(.type == "tool_result")
                            | (.tool_use_id // "") | tostring) as $id (.; .s[.cur].pend |= del(.[$id]))
                  else . end)
                | [.s[] | select((.pend | length) > 0 or .last == "ask")] | length' 2>/dev/null || echo 0)
            P_ASK=$(_gate_int "$P_ASK" 0)
            [ "$P_ASK" -gt "$P_IDLE" ] && P_ASK=$P_IDLE
            P_IDLE=$((P_IDLE - P_ASK))
        fi
        # Weight, not hue, carries urgency: the 12 project backgrounds make any
        # fixed color unreadable on some of them, while the palette's own dark
        # text stays legible on all. Segment themes use a dark peer surface
        # with its own light ink. Busy is bold, idle is the dim separator
        # tone, and a waiting question is reversed (dark chip, light text).
        _P_DIM="$PEER_DIM"
        _P_BODY=""
        _p_add() {  # _p_add <count> <style> <glyph> <self-state>: bracket the
            # count this session belongs to, so each session spots its own state
            [ "$1" -gt 0 ] || return 0
            if [ "$P_SELF" = "$4" ]; then
                _P_BODY+=" ${PEER_BOLD}[${2}${3}${1}${PEER_BOLD}]${PEER_B}"
            else
                _P_BODY+=" ${2}${3}${1}${PEER_B}"
            fi
        }
        _p_add "$P_BUSY"  "$PEER_BOLD"        "⚙" busy
        _p_add "$P_SHELL" "$PEER_FG"          "◷" shell
        _p_add "$P_ASK"   "\033[7m$PEER_BOLD" "?" never   # this session is never "?"
        _p_add "$P_IDLE"  "$_P_DIM"          "○" idle
        [ "$P_OTHERS" -gt 0 ] && [ -n "$_P_BODY" ] && PEER_SEG="${_P_BODY# }"
    fi
fi

# ── GitHub service status (line 1, after the branch; repo-scoped) ───────────
# On by default; opt OUT with STATUSLINE_GITHUB_STATUS=0. Uses the SAME status
# glyphs and colors as the Claude icon above (green ✓ / gold ~ / orange ⚠ /
# coral ✗), but on line 1 with the project palette, and ONLY when the current
# repo has a github.com remote (GitHub's health is only worth a column where you
# are actually pushing to it) -- on any other repo the separator and glyph are
# both absent, so line 1 is unchanged. Reuses claude-status-fetch.sh pointed at
# githubstatus.com (same Statuspage API), writing a SEPARATE per-user cache;
# CC_STATUSLINE_IGNORE_INCIDENTS="" turns off the Claude-only suspension filter
# so real GitHub incidents are never masked. Test seams mirror the SVC ones:
# CC_STATUSLINE_GH_CACHE overrides the cache path AND (when set) stands in for
# the github-remote probe so a render is deterministic; CC_STATUSLINE_GH_FETCH
# overrides the fetcher path.
if [ "${STATUSLINE_GITHUB_STATUS:-1}" != "0" ]; then
    GH_ON=0
    if [ -n "${CC_STATUSLINE_GH_CACHE:-}" ]; then
        GH_ON=1   # explicit cache (test seam) implies "treat this as a GitHub repo"
    else
        case "$(git -C "$CWD_FULL" remote get-url origin 2>/dev/null || echo '')" in
            *github.com*) GH_ON=1 ;;
        esac
    fi
    if [ "$GH_ON" = "1" ]; then
        GH_CACHE="${CC_STATUSLINE_GH_CACHE:-$(_state_dir)/github-status}"
        GH_FETCH="${CC_STATUSLINE_GH_FETCH:-$GENERIC_SVC_FETCH}"
        if [ -x "$GH_FETCH" ]; then
            GH_AGE=9999
            [ -f "$GH_CACHE" ] && GH_AGE=$(($(date +%s) - $(_file_mtime "$GH_CACHE")))
            if [ "$GH_AGE" -ge 60 ]; then
                (CC_STATUSLINE_SVC_CACHE="$GH_CACHE" \
                 CC_STATUSLINE_SVC_URL="https://www.githubstatus.com/api/v2/summary.json" \
                 CC_STATUSLINE_IGNORE_INCIDENTS="" \
                 "$GH_FETCH" >/dev/null 2>/dev/null &)
            fi
        fi
        if [ -f "$GH_CACHE" ]; then
            case "$(head -1 "$GH_CACHE" 2>/dev/null)" in
                operational)                     GH_GLYPH="${CLR_OK}${GH_LINK_OPEN}✓${GH_LINK_CLOSE}" ;;
                incident:*)                      GH_GLYPH="${CLR_INC}${GH_LINK_OPEN}⚠${GH_LINK_CLOSE}" ;;
                degraded_performance:*)          GH_GLYPH="${CLR_GOLD}${GH_LINK_OPEN}~${GH_LINK_CLOSE}" ;;
                partial_outage:*|major_outage:*) GH_GLYPH="${CLR_BAD}${GH_LINK_OPEN}✗${GH_LINK_CLOSE}" ;;
            esac
            # Keep alerts legible on the bright gradient with one dark cell.
            if [ "$THEME" = synthwave ] && [ -n "$GH_GLYPH" ]; then
                GH_GLYPH="\033[48;2;26;16;51m${GH_GLYPH}"
            fi
            [ -n "$GH_GLYPH" ] && GH_SEG=" ${SEP}${B} ${GH_GLYPH}${B}"
        fi
    fi
fi

# ── Phone layout: line 2 override ──────────────────────────────────────────
# Same palette, corners, bands and tier machinery as the wide render, fewer
# segments: account, optional context, and whichever 5h/7d windows are present.
# The tiers below feed the SAME widest-that-fits selection used for the wide
# render, so the countdowns drop before the percentages and the pace arrows
# survive longest (they are the alert). Model, effort, elapsed, cost, context
# and cache are dropped: on a phone they cost more columns than they earn.
# ↻ costs one column and stops the countdown reading as a second percentage.
_apply_phone_l2() {
    L2C="${RST}${CAP2_L}${BG2}"
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
        PH_SEP=" ${SEP2}"
    fi
    CACHE_SEG=""; TIMER_SEG=""
    if [ "$RATE_READY" = "1" ]; then
        # Context is the first optional segment to shed. Each limit window is
        # independent so GPT accounts that currently expose only weekly usage
        # still retain their one useful percentage at every rate tier.
        local CTX_PH=""
        [ "${STATUSLINE_CTX:-1}" != "0" ] && CTX_PH="${PH_SEP} ${L2_TXT}ctx ${CTX_CLR}${PCT}%${B2}"
        if [ -n "$CTX_PH" ]; then
            RATE_FULL="$CTX_PH"; RATE_COMPACT="$CTX_PH"; RATE_MINIMAL=""
            if [ -n "${FIVE_PCT:-}" ]; then
                RATE_FULL+=" ${SEP2} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
                [ -n "$FIVE_TIME" ] && RATE_FULL+=" ${L2_DIM}↻${L2_TXT}${FIVE_TIME}${B2}"
                RATE_COMPACT+=" ${SEP2} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
                RATE_MINIMAL="${PH_SEP} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
            fi
            if [ -n "${SEVEN_PCT:-}" ]; then
                RATE_FULL+=" ${SEP2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                [ -n "$SEVEN_TIME" ] && RATE_FULL+=" ${L2_DIM}↻${L2_TXT}${SEVEN_TIME}${B2}"
                RATE_COMPACT+=" ${SEP2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                if [ -n "${FIVE_PCT:-}" ]; then
                    RATE_MINIMAL+=" ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                else
                    RATE_MINIMAL="${PH_SEP} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                fi
            fi
        else
            RATE_FULL=""; RATE_COMPACT=""; RATE_MINIMAL=""
            if [ -n "${FIVE_PCT:-}" ]; then
                RATE_FULL="${PH_SEP} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
                [ -n "$FIVE_TIME" ] && RATE_FULL+=" ${L2_DIM}↻${L2_TXT}${FIVE_TIME}${B2}"
                RATE_COMPACT="${PH_SEP} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
                [ -n "$FIVE_TIME" ] && RATE_COMPACT+=" ${L2_DIM}↻${L2_TXT}${FIVE_TIME}${B2}"
                RATE_MINIMAL="${PH_SEP} ${L2_TXT}5h ${FIVE_CLR}${FIVE_PCT}%${FIVE_ARROW}${B2}"
            fi
            if [ -n "${SEVEN_PCT:-}" ]; then
                if [ -n "$RATE_FULL" ]; then
                    RATE_FULL+=" ${SEP2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                    RATE_COMPACT+=" ${SEP2} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                else
                    RATE_FULL="${PH_SEP} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                    RATE_COMPACT="$RATE_FULL"
                fi
                [ -n "$SEVEN_TIME" ] && RATE_FULL+=" ${L2_DIM}↻${L2_TXT}${SEVEN_TIME}${B2}"
                if [ -n "${FIVE_PCT:-}" ]; then
                    RATE_MINIMAL+=" ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                else
                    RATE_MINIMAL="${PH_SEP} ${L2_TXT}7d ${SEVEN_CLR}${SEVEN_PCT}%${SEVEN_ARROW}${B2}"
                fi
            fi
        fi
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
read -r L1_COLS BASE_W RFULL_W RCOMPACT_W RMINIMAL_W CACHE_W TIMER_W SVC_W < <(
    measure_cols "$L1C" "$L2C" "$RATE_FULL" "$RATE_COMPACT" "$RATE_MINIMAL" "$CACHE_SEG" "$TIMER_SEG" "$SVC_SEG" | tr '\n' ' '
)
L1_COLS=${L1_COLS:-0}; BASE_W=${BASE_W:-0}
RFULL_W=${RFULL_W:-0}; RCOMPACT_W=${RCOMPACT_W:-0}; RMINIMAL_W=${RMINIMAL_W:-0}
CACHE_W=${CACHE_W:-0}; TIMER_W=${TIMER_W:-0}; SVC_W=${SVC_W:-0}

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
    read -r L1_COLS BASE_W RFULL_W RCOMPACT_W RMINIMAL_W CACHE_W TIMER_W SVC_W < <(
        measure_cols "$L1C" "$L2C" "$RATE_FULL" "$RATE_COMPACT" "$RATE_MINIMAL" "$CACHE_SEG" "$TIMER_SEG" "$SVC_SEG" | tr '\n' ' '
    )
    L1_COLS=${L1_COLS:-0}; BASE_W=${BASE_W:-0}
    RFULL_W=${RFULL_W:-0}; RCOMPACT_W=${RCOMPACT_W:-0}; RMINIMAL_W=${RMINIMAL_W:-0}
    CACHE_W=${CACHE_W:-0}; TIMER_W=${TIMER_W:-0}; SVC_W=${SVC_W:-0}
fi

# ── Line 1 truncation, measured. Priority (least to most essential, so the
# leaf dir is preserved longest): K8S > PEERS > BRANCH > AGENT > MODE > TOPIC > DIR.
# Each round drops peers whole or trims a component by the measured overage
# (plus 2 for "..") and
# re-measures. The common case takes zero rounds; only an overflowing line
# re-measures, keeping the perl-call budget at ~2 per render.
# Phone renders DIR + BRANCH plus optional peer counts. Trimming the others
# would burn a
# re-measure without shrinking the line: walk just the components in play.
TRUNC_ORDER="K8S PEERS BRANCH AGENT MODE TOPIC NAME DIR"
# DIRLEAF drops the parent component ("cc-statusline/phone" -> "phone") before
# anything gets character-mangled: on a phone a whole leaf name reads better
# than two half-words, and it usually buys back more columns than trimming the
# branch would.
# The phone ladder must CONVERGE: every step either sheds columns or defers to
# the next, and the last two steps can always shed. Without them the ladder
# bottomed out with line 1 still over budget, and a NARROWER viewport rendered a
# WIDER line (COLUMNS=30 produced 51 columns against a 29-column budget), which
# is precisely the overflow that makes cli-truncate drop line 2.
[ "$LAYOUT" = "phone" ] && TRUNC_ORDER="PEERS DIRLEAF BRANCH GITST DIR BRANCHDROP DIRHARD"
for _t in $TRUNC_ORDER; do
    [ "$L1_COLS" -le "$TARGET" ] 2>/dev/null && break
    OVER=$((L1_COLS - TARGET))
    case $_t in
        PEERS) [ -n "$PEER_SEG" ] || continue
               PEER_SEG="" ;;
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
        NAME)   [ -n "$SESSION_HANDLE" ] || continue
                MAX=$(($(_clen "$SESSION_HANDLE") - OVER - 2))
                if [ "$MAX" -gt 5 ]; then SESSION_HANDLE="$(_head_cp "$SESSION_HANDLE" "$MAX").."; else SESSION_HANDLE=""; fi ;;
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

# ── Line 2: widest rate tier that fits, then cache/timer if room remains ───
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
# The cooldown timer outranks the hit rate: it is most urgent in its last
# minute, exactly when "<1m·5m" is widest, so the hit rate is shed first.
L2_LEFT=$((TARGET - BASE_W - RATE_W - SVC_W))
if [ "$((CACHE_W + TIMER_W))" -le "$L2_LEFT" ] 2>/dev/null; then
    L2C+="${CACHE_SEG}${TIMER_SEG}"
elif [ "$TIMER_W" -gt 0 ] && [ "$TIMER_W" -le "$L2_LEFT" ] 2>/dev/null; then
    L2C+="$TIMER_SEG"
elif [ "$CACHE_W" -gt 0 ] && [ "$CACHE_W" -le "$L2_LEFT" ] 2>/dev/null; then
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
# Preview callers suppress this out-of-band write to their controlling TTY.
if [ "${STATUSLINE_TAB_TITLE:-1}" != "0" ]; then
    { printf '\033]1;%s\007' "$_TAB_TITLE" > /dev/tty; } 2>/dev/null || true
fi

# ── Pad shorter line to match longer ────────────────────────────────────────
# The update indicator alone occupies line 1's right padding zone. It is
# shown only when it fits within TARGET and is dropped whole, never sliced.
{
    read -r L1_COLS L2_COLS UPD_W < <(
        measure_cols "$L1C" "$L2C" "$UPD_SEG" | tr '\n' ' '
    )
    L1_COLS=${L1_COLS:-0}; L2_COLS=${L2_COLS:-0}; UPD_W=${UPD_W:-0}
    SYNC_W=$L2_COLS
    [ "$L1_COLS" -gt "$SYNC_W" ] 2>/dev/null && SYNC_W=$L1_COLS
    _right_fits() {  # _right_fits <width>: does a right segment of that width fit?
        [ "$1" -gt 0 ] && [ "$L1_COLS" -gt 10 ] \
            && { [ "$((L1_COLS + $1))" -le "$SYNC_W" ] || [ "$((L1_COLS + $1))" -le "$TARGET" ]; }
    } 2>/dev/null
    RIGHT_SEG=""; RIGHT_W=0
    if [ -n "$UPD_SEG" ] && _right_fits "$UPD_W"; then
        RIGHT_SEG="$UPD_SEG"; RIGHT_W=$UPD_W
    fi
    if [ -n "$RIGHT_SEG" ]; then
        [ "$((L1_COLS + RIGHT_W))" -gt "$SYNC_W" ] && SYNC_W=$((L1_COLS + RIGHT_W))
        L1C+="${BG1}$(printf '%*s' "$((SYNC_W - L1_COLS - RIGHT_W))" '')${RIGHT_SEG}"
        L1_COLS=$SYNC_W
    fi
    if [ "$L1_COLS" -gt 10 ] 2>/dev/null && [ "$L1_COLS" -lt "$SYNC_W" ] 2>/dev/null; then
        L1C+="${BG1}$(printf '%*s' "$((SYNC_W - L1_COLS))" '')"
    fi
    if [ "$L2_COLS" -gt 10 ] 2>/dev/null && [ "$L2_COLS" -lt "$SYNC_W" ] 2>/dev/null; then
        L2C+="${BG2}$(printf '%*s' "$((SYNC_W - L2_COLS))" '')"
    fi
} 2>/dev/null || true

# ── Output ───────────────────────────────────────────────────────────────────
[ "$THEME_STYLE" != "flat" ] && [ -z "${RIGHT_SEG:-}" ] && CAP1_R=""
trap - EXIT  # disarm crash trap before normal output
if [ "$THEME" = "synthwave" ]; then
    # After every width decision and padding step, add only zero-width SGRs.
    # Preserve foreground/style and OSC 8 tokens; never slice their payloads.
    SYNTH_LINE=$(printf '%b' "$L1C" | perl -CS -0777 -ne '
        my @tokens = /(?:\e\]8;;.*?(?:\a|\e\\)|\e\[[0-9;]*m|.)/sg;
        my $n = scalar(grep { substr($_, 0, 1) ne "\e" } @tokens) - 1;
        my $i = -1;
        my $chip = 0;
        my @stops = ([255,42,109], [123,44,255], [5,217,232]);
        for my $token (@tokens) {
            if (substr($token, 0, 1) eq "\e") {
                if ($token =~ /^\e\[48;2;[0-9]+;[0-9]+;[0-9]+m$/) {
                    $chip = $token eq "\e[48;2;26;16;51m";
                    next unless $chip; # retain only the explicit dark surface
                } elsif ($token eq "\e[0m" || $token eq "\e[49m") { $chip = 0 }
                print $token; next;
            }
            if ($i < 0) { print $token; $i = 0; next } # leading cap
            my $t = $n > 1 ? $i / ($n - 1) : 0;
            my $half = $t < 0.5 ? 0 : 1;
            my $u = $t < 0.5 ? 2*$t : 2*$t-1;
            my @rgb = map { int($stops[$half][$_] +
                ($stops[$half+1][$_]-$stops[$half][$_])*$u) } 0..2;
            print "\e[48;2;", join(";", @rgb), "m" unless $chip;
            print $token;
            ++$i;
        }
    ' 2>/dev/null) || SYNTH_LINE=$(printf '%b' "$L1C")
    # The perl result is already expanded. A second %b would interpret content.
    printf '\033[0m%s%b\n' "$SYNTH_LINE" "${RST}${CAP1_R}${RST}"
else
    printf '\033[0m%b\n' "${L1C}${RST}${CAP1_R}${RST}"
fi
printf '\033[0m%b\n' "${L2C}${RST}${CAP2_R}${RST}"
