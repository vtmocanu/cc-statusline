#!/usr/bin/env bash
# cc-statusline test harness
#
# For each fixture in tests/fixtures/, pipe it through statusline.sh and assert:
#   - exit code is 0
#   - stdout has exactly 2 lines
#   - each visible line is within STATUSLINE_WIDTH + WIDTH_SLOP columns
#     (the script truncates against the same ANSI-aware codepoint count this
#      harness measures, so WIDTH_SLOP defaults to 0)
#   - stderr is empty
#
# Run from anywhere; resolves the repo root from this script's location.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
STATUSLINE="$REPO_DIR/statusline.sh"
FIXTURES="$SCRIPT_DIR/fixtures"

# Default safe width matches statusline.sh's default
SAFE_WIDTH="${STATUSLINE_WIDTH:-110}"
export STATUSLINE_WIDTH="$SAFE_WIDTH"
# Tolerance for the script's width measurement vs the harness's. The statusline
# now drives all truncation off the same ANSI-aware codepoint count this harness
# uses (measure_cols == vis_cols), so no slop is needed: the script targets
# SAFE_WIDTH - WIDE_GLYPH_MARGIN and never exceeds SAFE_WIDTH. Overridable for
# debugging.
WIDTH_SLOP="${WIDTH_SLOP:-0}"

# Run from a scratch directory so the cwd-derived git/k8s state of the
# test runner doesn't leak into output. Also unset KUBECONFIG so the
# kubectl-current-context lookup returns nothing.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
export KUBECONFIG=/dev/null
unset GIT_DIR GIT_WORK_TREE
# The statusline now narrows SAFE_WIDTH to the viewport when Claude Code exports
# COLUMNS (v2.1.153+). A runner that happens to export it would silently shrink
# every fixture's budget (and flip the phone layout on), so drop it here; the
# phone-layout tests below set it explicitly per run.
unset COLUMNS LINES
# Isolate the layout override file ($XDG_CONFIG_HOME/cc-statusline/layout): the
# maintainer's own file must not decide which layout the fixtures render.
export XDG_CONFIG_HOME="$SCRATCH/xdg-empty"
# An ambient token (harness run from inside a CLAUDE_CODE_OAUTH_TOKEN session)
# would silently switch the account-keyed rate-limits cache path; drop it so
# the rl-account-keyed test controls the token explicitly.
unset CLAUDE_CODE_OAUTH_TOKEN

# Isolate the service-status cache and fetcher from the host. The
# statusline reads CC_STATUSLINE_SVC_CACHE / CC_STATUSLINE_SVC_FETCH env
# vars (added in v2.1.x) to avoid touching /tmp/claude-service-status or
# spawning a real curl in the background during tests.
export CC_STATUSLINE_SVC_CACHE="$SCRATCH/svc-cache"
export CC_STATUSLINE_SVC_FETCH="$SCRATCH/no-such-fetcher.sh"
export CC_STATUSLINE_CODEX_SVC_CACHE="$SCRATCH/codex-svc-cache"
export CC_STATUSLINE_CODEX_SVC_FETCH="$SCRATCH/no-such-codex-status-fetcher.sh"
# Same isolation for the usage fetchers: non-executable paths ensure a render
# can never hit Anthropic or launch the real Codex app server during tests.
export CC_STATUSLINE_RL_FETCH="$SCRATCH/no-such-usage-fetcher.sh"
export CC_STATUSLINE_GPT_FETCH="$SCRATCH/no-such-codex-fetcher.sh"
export CC_STATUSLINE_GPT_CREDITS_FETCH="$SCRATCH/no-such-credit-fetcher.sh"
# Same for the update check: a scratch cache (absent unless a test seeds it, so
# no fixture ever shows the indicator) and a non-executable fetcher path so a
# render never hits api.github.com during tests.
export CC_STATUSLINE_UPDATE_CACHE="$SCRATCH/update-cache"
export CC_STATUSLINE_UPDATE_FETCH="$SCRATCH/no-such-update-fetcher.sh"
# GPT context-hold snapshot: a scratch path so no render (fixture or test)
# reads or writes the real per-session snapshot in the runtime dir. The
# context-hold tests below point each case at its own path.
export CC_STATUSLINE_CTX_CACHE="$SCRATCH/ctx-snapshot"

# Pin the clock so rate-limit reset countdowns and pace arrows are
# deterministic across runs and locales. Fixtures with future resets_at are
# authored relative to this epoch. Fixtures with resets_at=0 are unaffected.
export CC_STATUSLINE_NOW=1700000000
# Disable the profile badge so the runner's ~/.claude/profile-labels.json
# (present on the maintainer's machine, absent in CI) can't change line-2
# width between environments.
export STATUSLINE_PROFILE=0
# Isolate HOME. The effort level falls back to `jq .effortLevel
# ~/.claude/settings.json`, so the runner's own setting changes line 2's base
# width (xhigh is 5 columns, medium is 6). That used to be cosmetic; since the
# layout tier is chosen from the MEASURED base width, the runner's settings can
# now flip a decision the tests assert on, which is how a suite passes locally
# and fails in CI. Tests that need a real HOME set it themselves.
export HOME="$SCRATCH/home"
mkdir -p "$HOME/.claude"
# Same leak through the env: Claude Code exports CLAUDE_EFFORT to every child,
# so a suite run from inside a session would render that session's effort.
unset CLAUDE_EFFORT

pass=0
fail=0
errors=()

vis_cols() {
    # Use perl with explicit UTF-8 decoding so column counting is independent
    # of the runner's locale. `wc -m` falls back to byte-counting under C
    # locale, which inflates the count for multi-byte chars (▰▱│ etc.).
    perl -e '
        use Encode qw(decode);
        my $s = do { local $/; <STDIN> };
        $s =~ s/\e\]8;;.*?(?:\a|\e\\)//g;   # OSC 8 hyperlink open/close (zero width)
        $s =~ s/\e\[[0-9;]*m//g;
        $s =~ s/\n+$//;
        my $decoded = decode("UTF-8", $s, Encode::FB_DEFAULT);
        print length($decoded);
    '
}

run_one() {
    local fixture="$1"
    local name
    name=$(basename "$fixture" .json)

    # Per-fixture shared rate-limits cache: an empty scratch path so a fixture
    # with rate_limits (which now writes the cache) cannot leak account-wide
    # bars into a later fixture that has none (e.g. 03-no-rate-limits). Seeded
    # cross-snapshot behavior is exercised by rate_limit_cache_tests below.
    export CC_STATUSLINE_RL_CACHE="$SCRATCH/$name.rl-cache"

    local stdout_file="$SCRATCH/$name.out"
    local stderr_file="$SCRATCH/$name.err"

    # Materialize a companion transcript into the scratch dir so a fixture can
    # set "transcript_path" to a relative "<name>.transcript.jsonl" and have it
    # resolve at runtime (the statusline runs with cwd=$SCRATCH). Mirrors the
    # service-cache scratch isolation above; used by the agent-pane model test.
    local companion="$FIXTURES/$name.transcript.jsonl"
    [ -f "$companion" ] && cp "$companion" "$SCRATCH/$name.transcript.jsonl"

    (cd "$SCRATCH" && bash "$STATUSLINE" <"$fixture" >"$stdout_file" 2>"$stderr_file")
    local rc=$?

    local fail_reasons=()

    if [ "$rc" -ne 0 ]; then
        fail_reasons+=("exit code $rc")
    fi

    local line_count
    line_count=$(wc -l <"$stdout_file" | tr -d ' ')
    if [ "$line_count" -ne 2 ]; then
        fail_reasons+=("expected 2 stdout lines, got $line_count")
    fi

    if [ -s "$stderr_file" ]; then
        fail_reasons+=("non-empty stderr: $(head -1 "$stderr_file")")
    fi

    local lineno=0
    local max_allowed=$((SAFE_WIDTH + WIDTH_SLOP))
    while IFS= read -r line; do
        lineno=$((lineno + 1))
        local cols
        cols=$(printf '%s' "$line" | vis_cols)
        if [ "$cols" -gt "$max_allowed" ]; then
            fail_reasons+=("line $lineno is $cols cols (> ${max_allowed} = SAFE_WIDTH+${WIDTH_SLOP})")
        fi
    done <"$stdout_file"

    # Optional content assertion: <name>.expect-l2 holds a substring that line 2
    # (ANSI-stripped) must contain. Used to prove the transcript-derived model
    # name actually reaches line 2, not just that the render stays within width.
    local expect_file="$FIXTURES/$name.expect-l2"
    if [ -f "$expect_file" ]; then
        local want line2 stripped
        want=$(cat "$expect_file")
        line2=$(sed -n '2p' "$stdout_file")
        stripped=$(printf '%s' "$line2" | perl -pe 's/\e\[[0-9;]*m//g' 2>/dev/null)
        case "$stripped" in
            *"$want"*) : ;;
            *) fail_reasons+=("line 2 missing expected substring: $want") ;;
        esac
    fi

    if [ ${#fail_reasons[@]} -eq 0 ]; then
        printf '  PASS  %s\n' "$name"
        pass=$((pass + 1))
    else
        printf '  FAIL  %s\n' "$name"
        for r in "${fail_reasons[@]}"; do
            printf '          - %s\n' "$r"
            errors+=("$name: $r")
        done
        fail=$((fail + 1))
    fi
}

# ── Rate-limit shared-cache tests ──────────────────────────────────────────
# Beyond the generic width/exit checks, these pre-seed the cache and assert
# WHICH snapshot the render displays on line 2, and (for writes) what the cache
# holds afterward. Run in-harness so test-c-locale exercises them in both
# locales too. Times are pinned via CC_STATUSLINE_NOW (exported above) so the
# reset countdowns are deterministic.
_strip_ansi() { perl -pe 's/\e\]8;;.*?(?:\a|\e\\)//g; s/\e\[[0-9;]*m//g' 2>/dev/null; }
_rl_l2() { sed -n '2p' "$1" | _strip_ansi; }
_has() { case "$1" in *"$2"*) return 0 ;; *) return 1 ;; esac; }
# Detached fetchers can start late on a loaded runner. Poll for at most 2.5s
# instead of guessing that one fixed sleep is long enough.
_wait_for_content() {  # path exact-content
    local path="$1" expected="$2" got
    for _ in {1..50}; do
        got=""; [ -f "$path" ] && got=$(head -1 "$path" 2>/dev/null)
        [ "$got" = "$expected" ] && return 0
        sleep 0.05
    done
    return 1
}
_stays_absent() {  # one or more paths, observed for the same bounded interval
    local path
    for _ in {1..50}; do
        for path in "$@"; do [ -e "$path" ] && return 1; done
        sleep 0.05
    done
    return 0
}
_stays_content() {  # path exact-content, observed for the same bounded interval
    local path="$1" expected="$2" got
    for _ in {1..50}; do
        got=""; [ -f "$path" ] && got=$(head -1 "$path" 2>/dev/null)
        [ "$got" = "$expected" ] || return 1
        sleep 0.05
    done
    return 0
}

# Emit a stdin JSON payload with the given rate limits (short cwd, no git).
_rl_json() {
    printf '{"model":{"display_name":"Claude Opus 4.6","id":"opus"},'
    printf '"cwd":"/home/test/rl","context_window":{"remaining_percentage":50,'
    printf '"context_window_size":1000000},"cost":{"total_duration_ms":300000},'
    printf '"session_id":"rl-test","rate_limits":'
    printf '{"five_hour":{"used_percentage":%s,"resets_at":%s},' "$1" "$2"
    printf '"seven_day":{"used_percentage":%s,"resets_at":%s}}}' "$3" "$4"
}
# A REALISTIC payload: rate limits plus a cost readout, so line 2's wide base is
# as wide as a real session's. The viewport-band defect is invisible to a bare
# payload, whose base fits in widths where a real one does not.
_rl_json_rich() {
    printf '{"model":{"display_name":"Claude Opus 4.6","id":"opus"},'
    printf '"cwd":"/home/test/rl","context_window":{"remaining_percentage":50,'
    printf '"context_window_size":1000000},'
    printf '"cost":{"total_duration_ms":300000,"total_cost_usd":12.34},'
    printf '"session_id":"rl-rich","rate_limits":'
    printf '{"five_hour":{"used_percentage":15,"resets_at":1700009660},'
    printf '"seven_day":{"used_percentage":2,"resets_at":1700361000}}}'
}
# Same payload but with NO rate_limits object at all.
_rl_json_norl() {
    printf '{"model":{"display_name":"Claude Opus 4.6","id":"opus"},'
    printf '"cwd":"/home/test/rl","context_window":{"remaining_percentage":50,'
    printf '"context_window_size":1000000},"cost":{"total_duration_ms":300000},'
    printf '"session_id":"rl-test-norl"}'
}

_rl_pass() { printf '  PASS  %s\n' "$1"; pass=$((pass + 1)); }
_rl_fail() {
    printf '  FAIL  %s\n' "$1"
    printf '          - %s\n' "$2"
    errors+=("$1: $2")
    fail=$((fail + 1))
}

rate_limit_cache_tests() {
    printf '\n'
    printf 'rate-limit shared-cache tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local cache out err l2 name

    # 1. Cache strictly fresher (later 5h reset) than stdin -> cache displayed,
    #    and the fresher cache is NOT clobbered by the staler stdin.
    name="rl-cache-wins"; cache="$SCRATCH/rl1.cache"
    out="$SCRATCH/rl1.out"; err="$SCRATCH/rl1.err"
    printf '88|1700018000|40|1700200000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 15 1700010000 2 1700010000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "88%" || ! _has "$l2" "40%"; then
        _rl_fail "$name" "expected cached 88%/40% on line 2, got: $l2"
    elif [ "$(cat "$cache")" != "88|1700018000|40|1700200000" ]; then
        _rl_fail "$name" "fresher cache was clobbered: $(cat "$cache")"
    else _rl_pass "$name"; fi

    # 2. Stdin strictly fresher -> stdin displayed AND cache refreshed.
    name="rl-stdin-wins"; cache="$SCRATCH/rl2.cache"
    out="$SCRATCH/rl2.out"; err="$SCRATCH/rl2.err"
    printf '10|1700005000|5|1700100000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 60 1700020000 30 1700300000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "60%" || ! _has "$l2" "30%"; then
        _rl_fail "$name" "expected stdin 60%/30% on line 2, got: $l2"
    elif [ "$(cat "$cache")" != "60|1700020000|30|1700300000" ]; then
        _rl_fail "$name" "cache not refreshed from stdin: $(cat "$cache")"
    else _rl_pass "$name"; fi

    # 3. Malformed cache is ignored (stdin displayed) and overwritten.
    name="rl-malformed-cache"; cache="$SCRATCH/rl3.cache"
    out="$SCRATCH/rl3.out"; err="$SCRATCH/rl3.err"
    printf 'garbage|not|numeric|here\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 42 1700009000 7 1700099000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "42%" || ! _has "$l2" "7%"; then
        _rl_fail "$name" "expected stdin 42%/7% on line 2, got: $l2"
    elif [ "$(cat "$cache")" != "42|1700009000|7|1700099000" ]; then
        _rl_fail "$name" "malformed cache not overwritten: $(cat "$cache")"
    else _rl_pass "$name"; fi

    # 4. STATUSLINE_RL_SHARE=0 disables the feature: stdin shown, cache untouched
    #    even though it holds fresher values.
    name="rl-share-disabled"; cache="$SCRATCH/rl4.cache"
    out="$SCRATCH/rl4.out"; err="$SCRATCH/rl4.err"
    printf '88|1700018000|40|1700200000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 15 1700010000 2 1700010000 \
        | STATUSLINE_RL_SHARE=0 CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) \
        >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "15%" || ! _has "$l2" "2%"; then
        _rl_fail "$name" "expected stdin 15%/2% on line 2, got: $l2"
    elif [ "$(cat "$cache")" != "88|1700018000|40|1700200000" ]; then
        _rl_fail "$name" "cache mutated while sharing disabled: $(cat "$cache")"
    else _rl_pass "$name"; fi

    # 5. Cache fills the gap: stdin has NO rate limits, cache does -> cached bars
    #    render.
    name="rl-fills-gap"; cache="$SCRATCH/rl5.cache"
    out="$SCRATCH/rl5.out"; err="$SCRATCH/rl5.err"
    printf '55|1700016000|22|1700150000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json_norl \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "55%" || ! _has "$l2" "22%"; then
        _rl_fail "$name" "expected cached 55%/22% on line 2, got: $l2"
    else _rl_pass "$name"; fi

    # 6. Empty cache (nonexistent path) + stdin rate limits -> stdin seeds it.
    name="rl-seed-empty"; cache="$SCRATCH/rl6.cache"
    out="$SCRATCH/rl6.out"; err="$SCRATCH/rl6.err"
    rm -f "$cache"
    ( cd "$SCRATCH" && _rl_json 33 1700007000 11 1700077000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "33%" || ! _has "$l2" "11%"; then
        _rl_fail "$name" "expected stdin 33%/11% on line 2, got: $l2"
    elif [ "$(cat "$cache" 2>/dev/null)" != "33|1700007000|11|1700077000" ]; then
        _rl_fail "$name" "empty cache not seeded from stdin: $(cat "$cache" 2>/dev/null)"
    else _rl_pass "$name"; fi

    # 7. Corrupted-but-numeric cache percentages are re-clamped to [0,100] on
    #    read: a tampered fresher cache must never render "999%"/a full bar.
    name="rl-clamp-cached-pct"; cache="$SCRATCH/rl7.cache"
    out="$SCRATCH/rl7.out"; err="$SCRATCH/rl7.err"
    printf '999|1700018000|888|1700200000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 15 1700010000 2 1700010000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "999%" || _has "$l2" "888%"; then
        _rl_fail "$name" "out-of-range cached pct not clamped: $l2"
    elif ! _has "$l2" "100%"; then
        _rl_fail "$name" "expected clamped 100% on line 2, got: $l2"
    else _rl_pass "$name"; fi

    # 8. An over-length field (>=4-digit pct) voids the whole line: stdin is
    #    shown and the corrupt cache is overwritten (no stderr from arithmetic).
    name="rl-overlong-void"; cache="$SCRATCH/rl8.cache"
    out="$SCRATCH/rl8.out"; err="$SCRATCH/rl8.err"
    printf '9999|1700018000|40|1700200000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 15 1700010000 2 1700010000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "15%" || ! _has "$l2" "2%"; then
        _rl_fail "$name" "expected stdin 15%/2% after voiding corrupt cache, got: $l2"
    elif [ "$(cat "$cache")" != "15|1700010000|2|1700010000" ]; then
        _rl_fail "$name" "corrupt cache not overwritten from stdin: $(cat "$cache")"
    else _rl_pass "$name"; fi

    # 9. An oversized STDIN resets_at (past intmax) must not spill "integer
    #    expected" out of the compare: it normalizes to 0, and with a seeded
    #    (fresher) cache the render stays clean and shows the cached snapshot.
    name="rl-huge-stdin-reset"; cache="$SCRATCH/rl9.cache"
    out="$SCRATCH/rl9.out"; err="$SCRATCH/rl9.err"
    printf '20|1700005000|10|1700100000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 40 999999999999999999999999999999 20 1700099000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "20%" || ! _has "$l2" "10%"; then
        _rl_fail "$name" "expected cached 20%/10% on line 2, got: $l2"
    else _rl_pass "$name"; fi

    # 10. Core rollover rule in isolation: a NEW window (LOWER used% but LATER
    #     resets_at) must beat an OLD-window cache (higher used%, earlier
    #     resets_at). Locks "later resets_at wins over higher pct" so a fresh
    #     window's low numbers are never masked by the prior window's high ones.
    #     rl-cache-wins can't prove this: there the winner is higher on BOTH.
    name="rl-later-reset-beats-pct"; cache="$SCRATCH/rl10.cache"
    out="$SCRATCH/rl10.out"; err="$SCRATCH/rl10.err"
    printf '90|1700010000|80|1700100000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 5 1700020000 3 1700300000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "90%" || _has "$l2" "80%"; then
        _rl_fail "$name" "old-window cache masked the new window: $l2"
    elif ! _has "$l2" "5%" || ! _has "$l2" "3%"; then
        _rl_fail "$name" "expected new-window 5%/3% on line 2, got: $l2"
    elif [ "$(cat "$cache")" != "5|1700020000|3|1700300000" ]; then
        _rl_fail "$name" "cache not rewritten with new-window snapshot: $(cat "$cache")"
    else _rl_pass "$name"; fi

    # 11. Account keying + isolation: a session launched with
    #     CLAUDE_CODE_OAUTH_TOKEN uses its own cache file (rate-limits-<cksum>)
    #     and displays ONLY that file's fetched numbers, never the stdin
    #     rate_limits (which Claude Code serves from the account-agnostic shared
    #     cache and can belong to another account). Exercises the DEFAULT path
    #     (blank CC_STATUSLINE_RL_CACHE) via a scratch XDG_RUNTIME_DIR.
    name="rl-account-keyed"
    local state="$SCRATCH/rl11-state" statedir tok tokhash
    out="$SCRATCH/rl11.out"; err="$SCRATCH/rl11.err"
    mkdir -p "$state"
    statedir="$state/cc-statusline-$(id -u)"
    tok="sk-ant-oat01-test-token"
    tokhash=$(printf '%s' "$tok" | cksum | cut -d' ' -f1)
    # Default (token-less) account seeds the unsuffixed cache from stdin.
    ( cd "$SCRATCH" && _rl_json 15 1700010000 2 1700010000 \
        | XDG_RUNTIME_DIR="$state" CC_STATUSLINE_RL_CACHE="" CC_STATUSLINE_RL_KEY="" \
          bash "$STATUSLINE" ) >/dev/null 2>"$err"
    # The token account's own fetched line (5-field, stamp within TTL), written
    # as if by claude-usage-fetch.sh into ITS OWN keyed cache.
    mkdir -p "$statedir"
    printf '90|1700018000|70|1700200000|1699999990\n' > "$statedir/rate-limits-$tokhash"
    # Token render: stdin carries a DIFFERENT (polluting) account's 33%/11%.
    # Must display its own 90%/70%, never let stdin in, never rewrite the cache,
    # and never touch the unsuffixed (keychain) cache.
    ( cd "$SCRATCH" && _rl_json 33 1700007000 11 1700077000 \
        | XDG_RUNTIME_DIR="$state" CC_STATUSLINE_RL_CACHE="" \
          CLAUDE_CODE_OAUTH_TOKEN="$tok" bash "$STATUSLINE" ) >"$out" 2>>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "33%" || _has "$l2" "11%"; then
        _rl_fail "$name" "polluting stdin leaked into token session: $l2"
    elif ! _has "$l2" "90%" || ! _has "$l2" "70%"; then
        _rl_fail "$name" "expected own fetched 90%/70% on line 2, got: $l2"
    elif [ "$(cat "$statedir/rate-limits-$tokhash" 2>/dev/null)" != "90|1700018000|70|1700200000|1699999990" ]; then
        _rl_fail "$name" "token keyed cache clobbered: $(cat "$statedir/rate-limits-$tokhash" 2>/dev/null)"
    elif [ "$(cat "$statedir/rate-limits" 2>/dev/null)" != "15|1700010000|2|1700010000" ]; then
        _rl_fail "$name" "unsuffixed cache polluted or missing: $(cat "$statedir/rate-limits" 2>/dev/null)"
    else _rl_pass "$name"; fi

    # 12. Ancestor env scan: Claude Code consumes CLAUDE_CODE_OAUTH_TOKEN, so
    #     the statusline's OWN env lacks it; the key must come from an
    #     ancestor's exec-time environment (/proc/PID/environ or ps eww). With
    #     the token's own fetched line pre-seeded in the keyed cache, a render
    #     whose token lives only in an ancestor must resolve that keyed cache
    #     (show 90%/70%) and still ignore the polluting stdin. The intermediate
    #     `bash -c` holds the token at exec, then strips it from the statusline's
    #     env with `env -u`, mirroring the real process tree. The trailing
    #     `exit $?` stops bash -c from tail-exec'ing into env (which would
    #     collapse the chain and leave no token-bearing ancestor).
    name="rl-ancestor-env-scan"
    out="$SCRATCH/rl12.out"; err="$SCRATCH/rl12.err"
    mkdir -p "$statedir"
    printf '90|1700018000|70|1700200000|1699999990\n' > "$statedir/rate-limits-$tokhash"
    ( cd "$SCRATCH" && _rl_json 33 1700007000 11 1700077000 \
        | XDG_RUNTIME_DIR="$state" CC_STATUSLINE_RL_CACHE="" \
          CLAUDE_CODE_OAUTH_TOKEN="$tok" \
          bash -c 'env -u CLAUDE_CODE_OAUTH_TOKEN bash "$1"; exit $?' _ "$STATUSLINE" ) \
        >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "33%" || _has "$l2" "11%"; then
        _rl_fail "$name" "polluting stdin leaked despite ancestor-scanned key: $l2"
    elif ! _has "$l2" "90%" || ! _has "$l2" "70%"; then
        _rl_fail "$name" "expected ancestor-keyed 90%/70% on line 2, got: $l2"
    else _rl_pass "$name"; fi

    # 13. Fresh AUTHORITATIVE cache (5th field = fetch stamp within TTL) beats
    #     stdin even when stdin would win the freshness compare (later resets,
    #     higher pct): the fetched snapshot is the account's own API view while
    #     stdin can carry another account's numbers. Cache must not be
    #     overwritten either. Stamp 1699999990 is 10s before the pinned clock.
    name="rl-auth-overrides-stdin"; cache="$SCRATCH/rl13.cache"
    out="$SCRATCH/rl13.out"; err="$SCRATCH/rl13.err"
    printf '10|1700005000|5|1700100000|1699999990\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 60 1700020000 30 1700300000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "10%" || ! _has "$l2" "5%"; then
        _rl_fail "$name" "expected authoritative 10%/5% on line 2, got: $l2"
    elif [ "$(cat "$cache")" != "10|1700005000|5|1700100000|1699999990" ]; then
        _rl_fail "$name" "authoritative line clobbered by stdin: $(cat "$cache")"
    else _rl_pass "$name"; fi

    # 14. STALE authoritative stamp (older than the TTL) demotes the line to a
    #     plain snapshot: normal freshness compare resumes, the fresher stdin is
    #     displayed and rewrites the cache (4-field, stamp dropped).
    name="rl-auth-stale-falls-back"; cache="$SCRATCH/rl14.cache"
    out="$SCRATCH/rl14.out"; err="$SCRATCH/rl14.err"
    printf '10|1700005000|5|1700100000|1699000000\n' > "$cache"
    ( cd "$SCRATCH" && _rl_json 60 1700020000 30 1700300000 \
        | CC_STATUSLINE_RL_CACHE="$cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "60%" || ! _has "$l2" "30%"; then
        _rl_fail "$name" "expected stdin 60%/30% after stale auth, got: $l2"
    elif [ "$(cat "$cache")" != "60|1700020000|30|1700300000" ]; then
        _rl_fail "$name" "stale auth line not replaced by stdin: $(cat "$cache")"
    else _rl_pass "$name"; fi

    # 15. Account-specific session (RL_KEY set) with a STALE fetched line (5th-
    #     field stamp older than the TTL) keeps showing ITS OWN numbers, unlike a
    #     keychain session (case 14) which falls back to the fresher stdin. For a
    #     keyed session the stdin belongs to the account-agnostic shared cache
    #     (possibly another account), so a stale reading of the RIGHT account
    #     still beats it, and the cache is not overwritten.
    name="rl-keyed-stale-keeps-own"
    local st15="$SCRATCH/rl15-state" sd15
    out="$SCRATCH/rl15.out"; err="$SCRATCH/rl15.err"
    sd15="$st15/cc-statusline-$(id -u)"; mkdir -p "$sd15"
    printf '12|1700005000|8|1700100000|1699000000\n' > "$sd15/rate-limits-acct15"
    ( cd "$SCRATCH" && _rl_json 60 1700020000 30 1700300000 \
        | XDG_RUNTIME_DIR="$st15" CC_STATUSLINE_RL_CACHE="" CC_STATUSLINE_RL_KEY="acct15" \
          bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "60%" || _has "$l2" "30%"; then
        _rl_fail "$name" "stdin leaked into keyed session with stale line: $l2"
    elif ! _has "$l2" "12%" || ! _has "$l2" "8%"; then
        _rl_fail "$name" "expected own stale 12%/8% on line 2, got: $l2"
    elif [ "$(cat "$sd15/rate-limits-acct15" 2>/dev/null)" != "12|1700005000|8|1700100000|1699000000" ]; then
        _rl_fail "$name" "stale keyed line overwritten: $(cat "$sd15/rate-limits-acct15" 2>/dev/null)"
    else _rl_pass "$name"; fi

    # 16. Account-specific session with NO fetched line yet must show NO rate
    #     bars rather than the wrong account's stdin numbers, and must NOT seed
    #     its keyed cache from stdin (the old seed-from-stdin behavior is exactly
    #     how the keychain numbers first polluted a token cache).
    name="rl-keyed-no-fetch-blank"
    local st16="$SCRATCH/rl16-state" sd16
    out="$SCRATCH/rl16.out"; err="$SCRATCH/rl16.err"
    sd16="$st16/cc-statusline-$(id -u)"; mkdir -p "$sd16"
    rm -f "$sd16/rate-limits-acct16"
    ( cd "$SCRATCH" && _rl_json 33 1700007000 11 1700077000 \
        | XDG_RUNTIME_DIR="$st16" CC_STATUSLINE_RL_CACHE="" CC_STATUSLINE_RL_KEY="acct16" \
          bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "33%" || _has "$l2" "11%"; then
        _rl_fail "$name" "stdin shown for keyed session with no fetched line: $l2"
    elif [ -e "$sd16/rate-limits-acct16" ]; then
        _rl_fail "$name" "keyed cache seeded from stdin: $(cat "$sd16/rate-limits-acct16" 2>/dev/null)"
    else _rl_pass "$name"; fi
}

# ── GPT/Codex integration tests ─────────────────────────────────────────────
_gpt_json() {
    printf '{"model":{"display_name":"GPT Test","id":"%s"},' "$1"
    printf '"cwd":"/home/test/gpt","context_window":{"remaining_percentage":50,'
    printf '"context_window_size":1000000},"cost":{"total_duration_ms":300000'
    [ -n "${2:-}" ] && printf ',"total_cost_usd":%s' "$2"
    printf '},"session_id":"gpt-test","rate_limits":{'
    printf '"five_hour":{"used_percentage":99,"resets_at":1700009660},'
    printf '"seven_day":{"used_percentage":98,"resets_at":1700361000}}}'
}

gpt_rate_limit_tests() {
    printf '\n'
    printf 'GPT/Codex integration tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local cache ccache out err l2 raw name id n csvc clsvc crcache crstate crdir crkey otherkey w fake hits phome token tokhash state statedir generic dedicated
    cache="$SCRATCH/gpt.cache"; ccache="$SCRATCH/gpt-claude.cache"
    out="$SCRATCH/gpt.out"; err="$SCRATCH/gpt.err"

    # All provider-explicit IDs route to the Codex cache. The fake 99%/98%
    # Claude payload must never leak into a GPT render.
    n=0
    for id in gpt-5.6-sol 'gpt-5.6-sol[1m]' claude-ocx-native--gpt-5.6-sol \
              clodex:openai-oauth:gpt-5.6-sol anthropic-openai-oauth__gpt-5.6-sol; do
        n=$((n + 1)); name="gpt-id-$n"
        printf '|||65|1700361000|604800|1699999990\n' >"$cache"; rm -f "$ccache"
        (cd "$SCRATCH" && _gpt_json "$id" \
            | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
              CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
        l2=$(_rl_l2 "$out")
        if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif ! _has "$l2" "7d" || ! _has "$l2" "65%"; then
            _rl_fail "$name" "weekly Codex limit missing for $id: $l2"
        elif _has "$l2" "5h" || _has "$l2" "99%" || _has "$l2" "98%"; then
            _rl_fail "$name" "Claude limits leaked for $id: $l2"
        elif [ -e "$ccache" ]; then _rl_fail "$name" "GPT render wrote Claude cache"
        else _rl_pass "$name"; fi
    done

    # A single 5h window is valid too.
    name="gpt-five-only"; printf '42|1700009660|18000||||1699999990\n' >"$cache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "5h" || ! _has "$l2" "42%" || _has "$l2" "7d"; then
        _rl_fail "$name" "5h-only cache rendered incorrectly: $l2"
    else _rl_pass "$name"; fi

    # GPT pace uses each Codex window's reported duration. At the pinned clock,
    # 60% halfway through 5h is ahead, while 50% halfway through 7d is on pace.
    name="gpt-pace-ahead-and-on"
    printf '60|1700009000|18000|50|1700302400|604800|1699999990\n' >"$cache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "60%↑" || ! _has "$l2" "50%→"; then
        _rl_fail "$name" "GPT pace projections wrong: $l2"
    else _rl_pass "$name"; fi

    name="gpt-pace-safe"
    printf '20|1700009000|18000|20|1700302400|604800|1699999990\n' >"$cache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "↑" || _has "$l2" "→"; then _rl_fail "$name" "safe GPT pace showed an arrow: $l2"
    else _rl_pass "$name"; fi

    name="gpt-pace-zero-suppressed"
    printf '0|1700009000|18000|0|1700302400|604800|1699999990\n' >"$cache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "↑" || _has "$l2" "→"; then _rl_fail "$name" "zero GPT window showed an arrow: $l2"
    else _rl_pass "$name"; fi

    # A 315-minute reported duration produces on-pace here; a hardcoded 300
    # minutes would incorrectly classify the same snapshot as ahead.
    name="gpt-pace-reported-duration"
    printf '85|1700004900|18900||||1699999990\n' >"$cache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "85%→" || _has "$l2" "85%↑"; then
        _rl_fail "$name" "reported GPT duration was not used: $l2"
    else _rl_pass "$name"; fi

    name="gpt-pace-phone-width"
    printf '60|1700009000|18000|50|1700302400|604800|1699999990\n' >"$cache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | env COLUMNS=46 STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
              CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out"); w=$(sed -n '2p' "$out" | vis_cols)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "60%↑" || ! _has "$l2" "50%→"; then
        _rl_fail "$name" "phone GPT pace detail missing: $l2"
    elif [ "$w" -gt 45 ]; then _rl_fail "$name" "phone GPT pace width $w exceeds 45"
    else _rl_pass "$name"; fi

    # Claude keeps its historical both-window contract. A partial Anthropic
    # payload is treated as no rates, even though GPT explicitly supports one.
    name="claude-partial-stays-hidden"
    printf '%s' '{"model":{"display_name":"Claude Opus 5","id":"claude-opus-5"},"cwd":"/home/test/rl","context_window":{"remaining_percentage":50,"context_window_size":1000000},"cost":{"total_duration_ms":300000},"session_id":"claude-partial","rate_limits":{"five_hour":{"used_percentage":42,"resets_at":1700009660}}}' >"$SCRATCH/claude-partial.json"
    (cd "$SCRATCH" && STATUSLINE_RL_SHARE=0 bash "$STATUSLINE" <"$SCRATCH/claude-partial.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "5h" || _has "$l2" "42%"; then
        _rl_fail "$name" "partial Claude payload became visible: $l2"
    else _rl_pass "$name"; fi

    # API-key routes are not ChatGPT plan accounts and must retain Claude input.
    name="gpt-api-key-excluded"; printf '|||65|1700361000|604800|1699999990\n' >"$cache"
    rm -f "$ccache"
    (cd "$SCRATCH" && _gpt_json clodex:openai:gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "99%" || ! _has "$l2" "98%" || _has "$l2" "65%"; then
        _rl_fail "$name" "API-key route used ChatGPT cache: $l2"
    else _rl_pass "$name"; fi

    # The feature is default-off even for an obvious gpt-* model.
    name="gpt-default-off"; rm -f "$ccache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | CC_STATUSLINE_GPT_CACHE="$cache" CC_STATUSLINE_RL_CACHE="$ccache" \
          bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "99%" || ! _has "$l2" "98%" || _has "$l2" "65%"; then
        _rl_fail "$name" "default-off toggle changed Claude limits: $l2"
    else _rl_pass "$name"; fi

    # Claude Code applies Claude prices to GPT tokens, so the resulting native
    # dollar value is invalid and hidden. Claude's own cost behavior is unchanged.
    name="gpt-native-cost-hidden"; printf '|||65|1700361000|604800|1699999990\n' >"$cache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol 108.4706675 \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" '$108.47' || _has "$l2" '$'; then
        _rl_fail "$name" "invalid native GPT dollar cost was displayed: $l2"
    else _rl_pass "$name"; fi

    name="claude-native-cost-unchanged"; rm -f "$ccache"
    (cd "$SCRATCH" && _rl_json_rich \
        | CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" '$12.34'; then
        _rl_fail "$name" "Claude native cost disappeared: $l2"
    else _rl_pass "$name"; fi

    # A stale Codex snapshot blanks rates rather than falling back to Claude.
    name="gpt-stale-no-claude-fallback"; printf '|||65|1700361000|604800|1699999000\n' >"$cache"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "65%" || _has "$l2" "99%" || _has "$l2" "98%"; then
        _rl_fail "$name" "stale GPT cache fell back to wrong limits: $l2"
    else _rl_pass "$name"; fi

    # Agent-pane transcript correction changes the effective provider even when
    # stdin still reports the Claude parent model.
    name="gpt-transcript-effective-model"; printf '|||65|1700361000|604800|1699999990\n' >"$cache"
    rm -f "$ccache" "$ccache.fetching"
    printf '%s\n' '{"type":"assistant","message":{"model":"clodex:openai-oauth:gpt-5.6-sol","content":[]}}' >"$SCRATCH/gpt-transcript.jsonl"
    printf '%s' '{"model":{"display_name":"Claude Opus 5","id":"claude-opus-5"},"cwd":"/home/test/gpt","transcript_path":"' >"$SCRATCH/gpt-transcript.json"
    printf '%s' "$SCRATCH/gpt-transcript.jsonl" >>"$SCRATCH/gpt-transcript.json"
    printf '%s' '","context_window":{"remaining_percentage":50,"context_window_size":1000000},"cost":{"total_duration_ms":300000},"session_id":"gpt-pane","rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1700009660},"seven_day":{"used_percentage":98,"resets_at":1700361000}}}' >>"$SCRATCH/gpt-transcript.json"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "65%" || _has "$l2" "99%" || _has "$l2" "98%"; then
        _rl_fail "$name" "transcript GPT model did not replace Claude limits: $l2"
    elif [ -e "$ccache" ] || [ -e "$ccache.fetching" ]; then
        _rl_fail "$name" "transcript-only GPT detection touched the Claude rate cache"
    else _rl_pass "$name"; fi

    # Colon is allowed only as another safe model-id character. The OAuth route
    # switches providers, while an API-key route remains excluded.
    name="gpt-transcript-api-key-excluded"
    printf '%s\n' '{"type":"assistant","message":{"model":"clodex:openai:gpt-5.6-sol","content":[]}}' >"$SCRATCH/gpt-api-key-transcript.jsonl"
    printf '%s' '{"model":{"display_name":"Claude Opus 5","id":"claude-opus-5"},"cwd":"/home/test/gpt","transcript_path":"' >"$SCRATCH/gpt-api-key-transcript.json"
    printf '%s' "$SCRATCH/gpt-api-key-transcript.jsonl" >>"$SCRATCH/gpt-api-key-transcript.json"
    printf '%s' '","context_window":{"remaining_percentage":50,"context_window_size":1000000},"cost":{"total_duration_ms":300000},"session_id":"gpt-api-key-pane","rate_limits":{"five_hour":{"used_percentage":99,"resets_at":1700009660},"seven_day":{"used_percentage":98,"resets_at":1700361000}}}' >>"$SCRATCH/gpt-api-key-transcript.json"
    rm -f "$ccache"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE" <"$SCRATCH/gpt-api-key-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "99%" || ! _has "$l2" "98%" || _has "$l2" "65%"; then
        _rl_fail "$name" "transcript API-key route used ChatGPT limits: $l2"
    else _rl_pass "$name"; fi

    # Token-derived profile labels still work in a transcript-only GPT pane, but
    # the separated account-key resolution must not run any Claude limit fetch.
    name="gpt-token-profile-without-claude-fetch"
    phome="$SCRATCH/gpt-profile-home"; state="$SCRATCH/gpt-profile-state"
    mkdir -p "$phome/.claude" "$state"
    token="sk-ant-oat01-gpt-profile"; tokhash=$(printf '%s' "$token" | cksum | cut -d' ' -f1)
    printf '%s\n' '{"oauthAccount":{"accountUuid":"11111111-2222-3333-4444-555555555555"}}' >"$phome/.claude.json"
    printf '{"enabled":true,"profiles":{"%s":{"label":"GPTTOK","color":"blue"},"11111111-2222-3333-4444-555555555555":{"label":"CLAUDE","color":"red"}}}\n' "$tokhash" >"$phome/.claude/profile-labels.json"
    fake="$SCRATCH/fake-claude-usage-fetch.sh"; hits="$SCRATCH/gpt-profile-claude-fetch"
    printf '#!/usr/bin/env bash\nprintf x > "%s"\n' "$hits" >"$fake"; chmod +x "$fake"
    rm -f "$hits"
    statedir="$state/cc-statusline-$(id -u)"
    (cd "$SCRATCH" && env -u CC_STATUSLINE_RL_KEY HOME="$phome" XDG_RUNTIME_DIR="$state" STATUSLINE_PROFILE=1 \
        CLAUDE_CODE_OAUTH_TOKEN="$token" STATUSLINE_GPT_LIMITS=1 \
        CC_STATUSLINE_GPT_CACHE="$cache" CC_STATUSLINE_RL_CACHE="" \
        CC_STATUSLINE_RL_FETCH="$fake" bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "GPTTOK" || _has "$l2" "CLAUDE"; then
        _rl_fail "$name" "GPT token profile key was not preserved: $l2"
    elif ! _stays_absent "$hits" "$statedir/rate-limits-$tokhash" \
        "$statedir/rate-limits-$tokhash.fetching"; then
        _rl_fail "$name" "GPT profile resolution triggered Claude rate-limit work"
    else _rl_pass "$name"; fi

    # Fresh transcript-derived units render as a compact, rounded ChatGPT credit
    # estimate in the former dollar-cost position.
    crcache="$SCRATCH/gpt-credits.cache"
    printf 'ok|2074808840|1699999990\n' >"$crcache"
    name="gpt-credit-render"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" CC_STATUSLINE_RL_CACHE="$ccache" \
        bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out"); w=$(sed -n '2p' "$out" | vis_cols)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "2.07k cr" || _has "$l2" '$'; then
        _rl_fail "$name" "credit estimate rendered incorrectly: $l2"
    elif [ "$w" -gt "$((SAFE_WIDTH + WIDTH_SLOP))" ]; then
        _rl_fail "$name" "credit segment widened line 2 to $w columns"
    else _rl_pass "$name"; fi

    name="gpt-credit-below-1000"; printf 'ok|211289540|1699999990\n' >"$crcache"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" CC_STATUSLINE_RL_CACHE="$ccache" \
        bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "211.29 cr"; then _rl_fail "$name" "sub-1000 credits rendered incorrectly: $l2"
    else _rl_pass "$name"; fi

    name="gpt-credit-zero-hidden"; printf 'ok|0|1699999990\n' >"$crcache"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" CC_STATUSLINE_RL_CACHE="$ccache" \
        bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "0.00 cr" || _has "$l2" " cr"; then
        _rl_fail "$name" "fresh zero-usage session showed credits: $l2"
    else _rl_pass "$name"; fi

    # Restore a positive cache for the width-tier checks below.
    printf 'ok|211289540|1699999990\n' >"$crcache"
    name="gpt-credit-phone-tier"
    (cd "$SCRATCH" && env COLUMNS=46 STATUSLINE_GPT_LIMITS=1 \
        CC_STATUSLINE_GPT_CACHE="$cache" CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" \
        CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out"); w=$(sed -n '2p' "$out" | vis_cols)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" " cr"; then _rl_fail "$name" "phone tier kept credit segment: $l2"
    elif [ "$w" -gt 45 ]; then _rl_fail "$name" "phone credit render exceeded 45 columns: $w"
    else _rl_pass "$name"; fi

    name="gpt-credit-opt-out"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 STATUSLINE_GPT_CREDITS=0 \
        CC_STATUSLINE_GPT_CACHE="$cache" CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" \
        CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" " cr"; then _rl_fail "$name" "STATUSLINE_GPT_CREDITS=0 still showed credits: $l2"
    else _rl_pass "$name"; fi

    name="gpt-credit-stale-hidden"; printf 'ok|2074808840|1699999000\n' >"$crcache"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" CC_STATUSLINE_RL_CACHE="$ccache" \
        bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" " cr"; then _rl_fail "$name" "stale credit cache stayed visible: $l2"
    else _rl_pass "$name"; fi

    name="gpt-credit-unavailable-hidden"; printf 'unavailable||1699999990\n' >"$crcache"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" CC_STATUSLINE_RL_CACHE="$ccache" \
        bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" " cr"; then _rl_fail "$name" "unavailable credit cache became visible: $l2"
    else _rl_pass "$name"; fi

    name="gpt-credit-malformed-cache-hidden"; printf 'ok|not-a-number|1699999990\n' >"$crcache"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" CC_STATUSLINE_RL_CACHE="$ccache" \
        bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" " cr"; then _rl_fail "$name" "malformed credit cache became visible: $l2"
    else _rl_pass "$name"; fi

    # Full transcript scans are throttled to 60s. The fake helper also records
    # the pinned clock it receives from the statusline.
    fake="$SCRATCH/fake-credit-fetch.sh"
    cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${CC_STATUSLINE_NOW:-}" >"${CC_STATUSLINE_GPT_CREDITS_CACHE}.hit"
EOF
    chmod +x "$fake"
    name="gpt-credit-refresh-waits-60s"
    printf 'ok|211289540|1699999970\n' >"$crcache"
    rm -f "$crcache.hit" "$crcache.fetching"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" CC_STATUSLINE_GPT_CREDITS_FETCH="$fake" \
        CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _stays_absent "$crcache.hit" "$crcache.fetching"; then
        _rl_fail "$name" "30-second cache triggered a full transcript scan"
    else _rl_pass "$name"; fi

    name="gpt-credit-refresh-at-60s"
    printf 'ok|211289540|1699999940\n' >"$crcache"
    rm -f "$crcache.hit" "$crcache.fetching"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$crcache" CC_STATUSLINE_GPT_CREDITS_FETCH="$fake" \
        CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _wait_for_content "$crcache.hit" "1700000000"; then
        _rl_fail "$name" "60-second refresh did not run with pinned clock"
    elif [ ! -e "$crcache.fetching" ]; then _rl_fail "$name" "credit refresh marker missing"
    else _rl_pass "$name"; fi

    # Codex usage snapshots receive the same pinned clock as transcript credits.
    fake="$SCRATCH/fake-codex-usage-fetch.sh"
    cat >"$fake" <<'EOF'
#!/usr/bin/env bash
printf '%s' "${CC_STATUSLINE_NOW:-}" >"${CC_STATUSLINE_GPT_CACHE}.now"
EOF
    chmod +x "$fake"
    name="gpt-limit-fetch-receives-clock"
    rm -f "$cache" "$cache.fetching" "$cache.now"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_GPT_FETCH="$fake" CC_STATUSLINE_RL_CACHE="$ccache" \
          bash "$STATUSLINE") >"$out" 2>"$err"
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _wait_for_content "$cache.now" "1700000000"; then
        _rl_fail "$name" "Codex usage helper did not receive pinned clock"
    else _rl_pass "$name"; fi
    printf '|||65|1700361000|604800|1699999990\n' >"$cache"

    # A cache keyed for another transcript must never appear in this session.
    name="gpt-credit-session-isolation"; crstate="$SCRATCH/gpt-credit-state"
    crdir="$crstate/cc-statusline-$(id -u)"; mkdir -p "$crdir"
    otherkey=$(printf '%s' "$SCRATCH/other-session.jsonl" | cksum | cut -d' ' -f1)
    printf 'ok|999999999|1699999990\n' >"$crdir/gpt-credits-$otherkey"
    crkey=$(printf '%s' "$SCRATCH/gpt-transcript.jsonl" | cksum | cut -d' ' -f1)
    rm -f "$crdir/gpt-credits-$crkey"
    (cd "$SCRATCH" && STATUSLINE_GPT_LIMITS=1 XDG_RUNTIME_DIR="$crstate" \
        CC_STATUSLINE_GPT_CACHE="$cache" CC_STATUSLINE_GPT_CREDITS_CACHE="" \
        CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" " cr"; then _rl_fail "$name" "another session's credits leaked: $l2"
    else _rl_pass "$name"; fi

    # Weekly-only also survives the phone tier and keeps the context fallback
    # from replacing a real rate window.
    name="gpt-phone-weekly-only"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | env COLUMNS=46 STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
              CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "7d" || ! _has "$l2" "65%" || _has "$l2" "5h"; then
        _rl_fail "$name" "phone weekly-only limit rendered incorrectly: $l2"
    else _rl_pass "$name"; fi

    # GPT selects only its dedicated Codex component cache and OpenAI link, even
    # when the Claude cache contains a conflicting status.
    csvc="$SCRATCH/gpt-codex-svc"; clsvc="$SCRATCH/gpt-claude-svc"
    printf '|||65|1700361000|604800|1699999990\n' >"$cache"
    printf 'operational\n' >"$csvc"; printf 'incident:Claude outage\n' >"$clsvc"
    name="gpt-service-source-and-link"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_CODEX_SVC_CACHE="$csvc" CC_STATUSLINE_SVC_CACHE="$clsvc" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out"); raw=$(sed -n '2p' "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "✓" || _has "$l2" "⚠"; then
        _rl_fail "$name" "GPT selected Claude status: $l2"
    elif ! _has "$raw" "https://status.openai.com/" || _has "$raw" "https://status.claude.com"; then
        _rl_fail "$name" "GPT service hyperlink selected the wrong provider"
    elif [ "$(head -1 "$csvc")" != operational ] || [ "$(head -1 "$clsvc")" != "incident:Claude outage" ]; then
        _rl_fail "$name" "provider service caches were cross-written"
    else _rl_pass "$name"; fi

    name="gpt-service-degraded"
    printf 'degraded_performance:Codex API:Codex API\n' >"$csvc"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_CODEX_SVC_CACHE="$csvc" CC_STATUSLINE_SVC_CACHE="$clsvc" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "~" || _has "$l2" "⚠"; then
        _rl_fail "$name" "Codex degraded status rendered incorrectly: $l2"
    else _rl_pass "$name"; fi

    # A missing Codex cache must not fall back to the available Claude cache.
    name="gpt-service-missing-no-claude-fallback"; rm -f "$csvc"
    printf 'operational\n' >"$clsvc"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_CODEX_SVC_CACHE="$csvc" CC_STATUSLINE_SVC_CACHE="$clsvc" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out"); raw=$(sed -n '2p' "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "✓" || _has "$raw" "status.claude.com"; then
        _rl_fail "$name" "missing Codex status fell back to Claude: $l2"
    else _rl_pass "$name"; fi

    # With no dedicated override, GPT status inherits the generic service
    # fetcher override. A dedicated override still has first precedence.
    generic="$SCRATCH/fake-generic-svc.sh"; dedicated="$SCRATCH/fake-codex-svc.sh"
    hits="$SCRATCH/gpt-svc-fetch-hit"
    cat >"$generic" <<'EOF'
#!/usr/bin/env bash
printf 'generic|%s|%s' "${CC_STATUSLINE_SVC_COMPONENT:-}" "${CC_STATUSLINE_SVC_URL:-}" >"$TEST_HIT"
EOF
    cat >"$dedicated" <<'EOF'
#!/usr/bin/env bash
printf 'dedicated|%s|%s' "${CC_STATUSLINE_SVC_COMPONENT:-}" "${CC_STATUSLINE_SVC_URL:-}" >"$TEST_HIT"
EOF
    chmod +x "$generic" "$dedicated"

    name="gpt-service-generic-fetch-fallback"; rm -f "$csvc" "$hits"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | TEST_HIT="$hits" STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_CODEX_SVC_CACHE="$csvc" CC_STATUSLINE_CODEX_SVC_FETCH="" \
          CC_STATUSLINE_SVC_FETCH="$generic" CC_STATUSLINE_RL_CACHE="$ccache" \
          bash "$STATUSLINE") >"$out" 2>"$err"
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _wait_for_content "$hits" "generic|Codex API|https://status.openai.com/api/v2/components.json"; then
        _rl_fail "$name" "generic service override was not used for GPT"
    else _rl_pass "$name"; fi

    name="gpt-service-dedicated-fetch-precedence"; rm -f "$csvc" "$hits"
    (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
        | TEST_HIT="$hits" STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$cache" \
          CC_STATUSLINE_CODEX_SVC_CACHE="$csvc" CC_STATUSLINE_CODEX_SVC_FETCH="$dedicated" \
          CC_STATUSLINE_SVC_FETCH="$generic" CC_STATUSLINE_RL_CACHE="$ccache" \
          bash "$STATUSLINE") >"$out" 2>"$err"
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _wait_for_content "$hits" "dedicated|Codex API|https://status.openai.com/api/v2/components.json"; then
        _rl_fail "$name" "dedicated Codex service override did not win"
    else _rl_pass "$name"; fi

    # Claude sessions still ignore the Codex cache and link.
    name="claude-service-source-unchanged"; printf 'major_outage:Codex API:Codex API\n' >"$csvc"
    printf 'operational\n' >"$clsvc"
    (cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
        | CC_STATUSLINE_CODEX_SVC_CACHE="$csvc" CC_STATUSLINE_SVC_CACHE="$clsvc" \
          CC_STATUSLINE_RL_CACHE="$ccache" bash "$STATUSLINE") >"$out" 2>"$err"
    l2=$(_rl_l2 "$out"); raw=$(sed -n '2p' "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "✓" || _has "$l2" "✗"; then
        _rl_fail "$name" "Claude selected Codex status: $l2"
    elif ! _has "$raw" "https://status.claude.com" || _has "$raw" "status.openai.com"; then
        _rl_fail "$name" "Claude service hyperlink changed provider"
    else _rl_pass "$name"; fi
}

# ── Update-indicator tests ─────────────────────────────────────────────────
# The line-1 right-aligned "⇡ X.Y.Z" (STATUSLINE_UPDATE_CHECK, default on).
# Seeds the cache through the CC_STATUSLINE_UPDATE_CACHE seam and asserts when
# the indicator shows (only a strictly newer tag), that it never breaks the
# width budget (dropped, not truncated, when line 1 has no room), that it is
# hyperlinked to the release page, and that a malformed cache line can never
# reach the terminal.
update_check_tests() {
    printf '\n'
    printf 'update-indicator tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local name out err l1 raw1 w1 w2 cache local_ver bad
    local_ver=$(head -1 "$REPO_DIR/VERSION" 2>/dev/null)
    cache="$SCRATCH/upd-seam-cache"

    _upd_run() {  # _upd_run <out> <err> <env...> -- render 18-session-name
        local o="$1" e="$2"; shift 2
        ( cd "$SCRATCH" && env "$@" CC_STATUSLINE_RL_CACHE="$SCRATCH/upd.cache" \
            bash "$STATUSLINE" <"$FIXTURES/18-session-name.json" ) >"$o" 2>"$e"
    }
    _upd_l1() { sed -n '1p' "$1" | _strip_ansi; }
    _w() { sed -n "$2p" "$1" | vis_cols; }

    # 1. Newer tag -> gold "⇡ 99.0.0" on line 1, both lines the same width and
    #    inside the budget, and the raw line carries the OSC 8 release link.
    name="upd-newer-shows"; out="$SCRATCH/upd1.out"; err="$SCRATCH/upd1.err"
    printf 'v99.0.0\n' > "$cache"
    _upd_run "$out" "$err" CC_STATUSLINE_UPDATE_CACHE="$cache"
    l1=$(_upd_l1 "$out"); raw1=$(sed -n '1p' "$out"); w1=$(_w "$out" 1); w2=$(_w "$out" 2)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "⇡ 99.0.0"; then _rl_fail "$name" "line 1 missing '⇡ 99.0.0': $l1"
    elif [ "$w1" -ne "$w2" ]; then _rl_fail "$name" "line widths differ after placement: $w1 vs $w2"
    elif [ "$w1" -gt "$((SAFE_WIDTH + WIDTH_SLOP))" ]; then _rl_fail "$name" "line 1 width $w1 exceeds budget"
    elif ! _has "$raw1" "releases/tag/v99.0.0"; then _rl_fail "$name" "release hyperlink missing from raw line 1"
    else _rl_pass "$name"; fi

    # 2. Right-aligned: the indicator is the LAST visible text on line 1 (one
    #    trailing space, then the top-right corner glyph U+E0B8; no padding run
    #    after it).
    name="upd-right-aligned"
    case "$l1" in
        *"⇡ 99.0.0 "$'\xee\x82\xb8') _rl_pass "$name" ;;
        *) _rl_fail "$name" "indicator not at the right edge: [$l1]" ;;
    esac

    # 3. Same version as the installed VERSION file -> hidden.
    name="upd-same-hidden"; out="$SCRATCH/upd3.out"; err="$SCRATCH/upd3.err"
    printf 'v%s\n' "$local_ver" > "$cache"
    _upd_run "$out" "$err" CC_STATUSLINE_UPDATE_CACHE="$cache"
    l1=$(_upd_l1 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "⇡"; then _rl_fail "$name" "indicator shown for the installed version $local_ver: $l1"
    else _rl_pass "$name"; fi

    # 4. Older tag (a rollback, or a stale cache after a local upgrade) -> hidden.
    name="upd-older-hidden"; out="$SCRATCH/upd4.out"; err="$SCRATCH/upd4.err"
    printf 'v0.0.1\n' > "$cache"
    _upd_run "$out" "$err" CC_STATUSLINE_UPDATE_CACHE="$cache"
    l1=$(_upd_l1 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "⇡"; then _rl_fail "$name" "indicator shown for an older tag: $l1"
    else _rl_pass "$name"; fi

    # 5. Numeric, not lexical: MAJOR.1000.0 beats MAJOR.9.x even though "1" sorts
    #    before "9" as text; a bare tag without the "v" is accepted too.
    name="upd-numeric-compare"; out="$SCRATCH/upd5.out"; err="$SCRATCH/upd5.err"
    printf '%s\n' "${local_ver%%.*}.1000.0" > "$cache"
    _upd_run "$out" "$err" CC_STATUSLINE_UPDATE_CACHE="$cache"
    l1=$(_upd_l1 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "⇡ ${local_ver%%.*}.1000.0"; then _rl_fail "$name" "minor 1000 not treated as newer: $l1"
    else _rl_pass "$name"; fi

    # 6. Malformed cache lines (escape injection, shell text, pre-release
    #    suffix, junk) never render, and none of their bytes reach line 1.
    #    The first entry embeds a real ESC and BEL (an OSC 8 open sequence).
    for bad in "v1.2.3$(printf '\033')]8;;https://evil$(printf '\a')" 'v1.2.3-rc1' \
               'v99.0.0; rm -rf /' '99' 'latest' 'v99.0.0 extra'; do
        name="upd-bad-cache-hidden"; out="$SCRATCH/upd6.out"; err="$SCRATCH/upd6.err"
        printf '%s\n' "$bad" > "$cache"
        _upd_run "$out" "$err" CC_STATUSLINE_UPDATE_CACHE="$cache"
        l1=$(_upd_l1 "$out"); raw1=$(sed -n '1p' "$out")
        if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr for [${bad//[^[:print:]]/?}]: $(head -1 "$err")"
        elif _has "$l1" "⇡"; then _rl_fail "$name" "indicator shown for malformed [${bad//[^[:print:]]/?}]: $l1"
        elif _has "$raw1" "evil" || _has "$raw1" "rm -rf"; then _rl_fail "$name" "cache bytes leaked into line 1 for [${bad//[^[:print:]]/?}]"
        else _rl_pass "$name [${bad//[^[:print:]]/?}]"; fi
    done

    # 7. Opt-OUT: STATUSLINE_UPDATE_CHECK=0 hides it even with a newer tag.
    name="upd-opt-out"; out="$SCRATCH/upd7.out"; err="$SCRATCH/upd7.err"
    printf 'v99.0.0\n' > "$cache"
    _upd_run "$out" "$err" STATUSLINE_UPDATE_CHECK=0 CC_STATUSLINE_UPDATE_CACHE="$cache"
    l1=$(_upd_l1 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "⇡"; then _rl_fail "$name" "indicator shown while opted out (=0): $l1"
    else _rl_pass "$name"; fi

    # 8. STATUSLINE_HYPERLINKS=0 keeps the text but drops the OSC 8 wrapper.
    name="upd-hyperlinks-off"; out="$SCRATCH/upd8.out"; err="$SCRATCH/upd8.err"
    _upd_run "$out" "$err" STATUSLINE_HYPERLINKS=0 CC_STATUSLINE_UPDATE_CACHE="$cache"
    l1=$(_upd_l1 "$out"); raw1=$(sed -n '1p' "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "⇡ 99.0.0"; then _rl_fail "$name" "indicator missing with hyperlinks off: $l1"
    elif _has "$raw1" "releases/tag"; then _rl_fail "$name" "OSC 8 link emitted with STATUSLINE_HYPERLINKS=0"
    else _rl_pass "$name"; fi

    # 9. No room: a line 1 that already fills the budget (long title + long dir
    #    trimmed to TARGET) DROPS the indicator instead of overflowing.
    name="upd-no-room-dropped"; out="$SCRATCH/upd9.out"; err="$SCRATCH/upd9.err"
    local longdir="$SCRATCH/upd-long/aaaaaaaaaaaaaaaaaaaaaaaaa/bbbbbbbbbbbbbbbbbbbbbbbbb/ccccccccccccccccccccccccc"
    mkdir -p "$longdir"
    { printf '{"model":{"display_name":"Claude Opus 4.6","id":"opus"},"cwd":"%s",' "$longdir"
      printf '"session_name":"a very long descriptive session title that fills",'
      printf '"context_window":{"remaining_percentage":50,"context_window_size":1000000},'
      printf '"cost":{"total_duration_ms":300000},"session_id":"upd9"}'; } \
      | ( cd "$SCRATCH" && env CC_STATUSLINE_UPDATE_CACHE="$cache" \
            CC_STATUSLINE_RL_CACHE="$SCRATCH/upd9.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l1=$(_upd_l1 "$out"); w1=$(_w "$out" 1); w2=$(_w "$out" 2)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$w1" -gt "$((SAFE_WIDTH + WIDTH_SLOP))" ] || [ "$w2" -gt "$((SAFE_WIDTH + WIDTH_SLOP))" ]; then
        _rl_fail "$name" "widths $w1/$w2 exceed budget with the indicator: $l1"
    elif [ "$w1" -ne "$w2" ]; then _rl_fail "$name" "line widths differ: $w1 vs $w2"
    elif _has "$l1" "⇡" && [ "$w1" -gt "$((SAFE_WIDTH - 3))" ]; then
        _rl_fail "$name" "indicator kept past TARGET: $l1"
    else _rl_pass "$name"; fi

    # 10. Default cache path: with the seam blank, the state dir's update-check
    #     file (via XDG_RUNTIME_DIR) is read, exactly where the fetcher writes.
    name="upd-default-path"; out="$SCRATCH/upd10.out"; err="$SCRATCH/upd10.err"
    local statedir; statedir="$SCRATCH/upd-state/cc-statusline-$(id -u)"
    mkdir -p "$statedir"; printf 'v99.0.0\n' > "$statedir/update-check"
    _upd_run "$out" "$err" XDG_RUNTIME_DIR="$SCRATCH/upd-state" CC_STATUSLINE_UPDATE_CACHE=""
    l1=$(_upd_l1 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "⇡ 99.0.0"; then _rl_fail "$name" "default state-dir cache not read: $l1"
    else _rl_pass "$name"; fi

    # 11. Spawn throttle: an executable fake fetcher is spawned once when the
    #     cache is stale, and NOT again while the .fetching marker is fresh.
    name="upd-spawn-throttle"; out="$SCRATCH/upd11.out"; err="$SCRATCH/upd11.err"
    local fake="$SCRATCH/fake-update-fetch.sh" hits="$SCRATCH/upd11.hits" c11="$SCRATCH/upd11.cache"
    printf '#!/usr/bin/env bash\nprintf x >> "%s"\n' "$hits" > "$fake"; chmod +x "$fake"
    rm -f "$hits" "$c11" "$c11.fetching"
    _upd_run "$out" "$err" CC_STATUSLINE_UPDATE_CACHE="$c11" CC_STATUSLINE_UPDATE_FETCH="$fake"
    _upd_run "$out" "$err" CC_STATUSLINE_UPDATE_CACHE="$c11" CC_STATUSLINE_UPDATE_FETCH="$fake"
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ ! -f "$c11.fetching" ]; then _rl_fail "$name" ".fetching marker not written"
    elif ! _wait_for_content "$hits" "x" || ! _stays_content "$hits" "x"; then
        _rl_fail "$name" "expected exactly 1 spawn across 2 renders, got $(wc -c <"$hits" 2>/dev/null | tr -d ' ')"
    else _rl_pass "$name"; fi

    # 12. Phone layout: same placement rule; a narrow viewport never overflows.
    name="upd-phone-width"; out="$SCRATCH/upd12.out"; err="$SCRATCH/upd12.err"
    printf 'v99.0.0\n' > "$cache"
    _upd_run "$out" "$err" COLUMNS=46 CC_STATUSLINE_UPDATE_CACHE="$cache"
    w1=$(_w "$out" 1); w2=$(_w "$out" 2)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$w1" -gt 45 ] || [ "$w2" -gt 45 ]; then _rl_fail "$name" "widths $w1/$w2 exceed COLUMNS-1 (45)"
    elif [ "$w1" -ne "$w2" ]; then _rl_fail "$name" "line widths differ: $w1 vs $w2"
    else _rl_pass "$name"; fi
}

# ── Phone-layout tests ─────────────────────────────────────────────────────
# Cover the viewport-driven layout switch: COLUMNS narrows SAFE_WIDTH, a width
# under STATUSLINE_PHONE_COLS selects the phone render (folder + branch on line
# 1, account + 5h/7d on line 2), and STATUSLINE_LAYOUT forces a tier either way.
phone_layout_tests() {
    printf '\n'
    printf 'phone-layout tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local out err l2 name w1 w2 lines

    _phone_run() {  # _phone_run <out> <err> <cols-env...> -- runs one render
        local o="$1" e="$2"; shift 2
        ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
            | env "$@" bash "$STATUSLINE" ) >"$o" 2>"$e"
    }
    _w() { sed -n "$2p" "$1" | vis_cols; }

    # 1. COLUMNS=46 -> phone layout, both lines inside the viewport, line 2
    #    carries the account-window percentages and the 5h reset countdown.
    name="phone-cols-46"; out="$SCRATCH/ph1.out"; err="$SCRATCH/ph1.err"
    _phone_run "$out" "$err" COLUMNS=46 CC_STATUSLINE_RL_CACHE="$SCRATCH/ph1.cache"
    lines=$(wc -l <"$out" | tr -d ' '); w1=$(_w "$out" 1); w2=$(_w "$out" 2)
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$lines" -ne 2 ]; then _phone_fail "$name" "expected 2 lines, got $lines"
    elif [ "$w1" -gt 45 ] || [ "$w2" -gt 45 ]; then
        _phone_fail "$name" "line widths $w1/$w2 exceed COLUMNS-1 (45)"
    elif ! _has "$l2" "5h " || ! _has "$l2" "7d "; then
        _phone_fail "$name" "line 2 missing 5h/7d: $l2"
    elif _has "$l2" "Opus" || _has "$l2" "of 1000k"; then
        _phone_fail "$name" "line 2 still carries wide-layout segments: $l2"
    else _phone_pass "$name"; fi

    # 2. Wide viewport -> untouched wide render (model + context still present).
    name="phone-cols-wide"; out="$SCRATCH/ph2.out"; err="$SCRATCH/ph2.err"
    _phone_run "$out" "$err" COLUMNS=200 CC_STATUSLINE_RL_CACHE="$SCRATCH/ph2.cache"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "of 1000k"; then
        _phone_fail "$name" "wide viewport lost the context segment: $l2"
    else _phone_pass "$name"; fi

    # 3. STATUSLINE_WIDTH stays a cap: a wide COLUMNS must not raise it.
    name="phone-width-is-a-cap"; out="$SCRATCH/ph3.out"; err="$SCRATCH/ph3.err"
    _phone_run "$out" "$err" COLUMNS=300 STATUSLINE_WIDTH=70 CC_STATUSLINE_RL_CACHE="$SCRATCH/ph3.cache"
    w1=$(_w "$out" 1); w2=$(_w "$out" 2)
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$w1" -gt 70 ] || [ "$w2" -gt 70 ]; then
        _phone_fail "$name" "COLUMNS raised the cap: $w1/$w2 > 70"
    else _phone_pass "$name"; fi

    # 4. Forced phone layout on a wide viewport.
    name="phone-forced"; out="$SCRATCH/ph4.out"; err="$SCRATCH/ph4.err"
    _phone_run "$out" "$err" COLUMNS=200 STATUSLINE_LAYOUT=phone CC_STATUSLINE_RL_CACHE="$SCRATCH/ph4.cache"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "of 1000k"; then
        _phone_fail "$name" "STATUSLINE_LAYOUT=phone still rendered the wide line 2: $l2"
    else _phone_pass "$name"; fi

    # 5. Forced wide layout on a narrow viewport (escape hatch).
    name="phone-forced-wide"; out="$SCRATCH/ph5.out"; err="$SCRATCH/ph5.err"
    _phone_run "$out" "$err" COLUMNS=46 STATUSLINE_LAYOUT=wide CC_STATUSLINE_RL_CACHE="$SCRATCH/ph5.cache"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "Opus"; then
        _phone_fail "$name" "STATUSLINE_LAYOUT=wide dropped the model segment: $l2"
    else _phone_pass "$name"; fi

    # 6. The layout FILE flips a wide viewport to phone. This is the escape
    #     hatch for clients that report NO viewport; auto-detection covers the
    #     normal case, since COLUMNS reports the viewing client's width (see
    #     KNOWN_ISSUES). Env var still wins over the file.
    name="phone-layout-file"; out="$SCRATCH/ph7.out"; err="$SCRATCH/ph7.err"
    mkdir -p "$SCRATCH/xdg/cc-statusline"
    printf 'phone\n' > "$SCRATCH/xdg/cc-statusline/layout"
    _phone_run "$out" "$err" COLUMNS=200 XDG_CONFIG_HOME="$SCRATCH/xdg" \
        CC_STATUSLINE_RL_CACHE="$SCRATCH/ph7.cache"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l2" "of 1000k"; then
        _phone_fail "$name" "layout file ignored, wide line 2 rendered: $l2"
    else _phone_pass "$name"; fi

    # 7. The env var still beats the file.
    name="phone-layout-file-env-wins"; out="$SCRATCH/ph8.out"; err="$SCRATCH/ph8.err"
    _phone_run "$out" "$err" COLUMNS=200 XDG_CONFIG_HOME="$SCRATCH/xdg" \
        STATUSLINE_LAYOUT=wide CC_STATUSLINE_RL_CACHE="$SCRATCH/ph8.cache"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "of 1000k"; then
        _phone_fail "$name" "env var did not override the layout file: $l2"
    else _phone_pass "$name"; fi

    # 8. Phone layout with no rate limits at all -> context fallback, not an
    #    empty band.
    name="phone-no-rate-limits"; out="$SCRATCH/ph6.out"; err="$SCRATCH/ph6.err"
    ( cd "$SCRATCH" && _rl_json_norl \
        | env COLUMNS=46 CC_STATUSLINE_RL_CACHE="$SCRATCH/ph6.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "ctx "; then
        _phone_fail "$name" "expected the ctx fallback on line 2, got: $l2"
    else _phone_pass "$name"; fi
}
_phone_pass() { _rl_pass "$1"; }
_phone_fail() { _rl_fail "$1" "$2"; }

# ── Phone truncation-ladder tests ──────────────────────────────────────────
# The ladder (DIRLEAF -> BRANCH -> GITST -> DIR -> BRANCHDROP -> DIRHARD) had NO
# coverage when it shipped: every other phone test runs from $SCRATCH, which is
# not a git repo, so BRANCH and GIT_STATUS are empty and line 1 is ~16 columns.
# Two blocking bugs lived in exactly that blind spot: a short branch collapsed to
# a bare ".." (bash returns the empty string for an over-long negative offset),
# and the ladder could bottom out over budget so a NARROWER viewport rendered a
# WIDER line. These tests need a real git repo with a real branch to reach it.
phone_truncation_tests() {
    printf '\n'
    printf 'phone truncation-ladder tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local repo="$SCRATCH/ladder-repo"
    local leaf="a-very-long-worktree-leaf-name"
    local wd="$repo/$leaf"
    mkdir -p "$wd"
    ( cd "$repo" && git init -q -b main . && git -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m init ) >/dev/null 2>&1

    local name out err cols cap widest line stripped
    local json='{"model":{"display_name":"Claude Opus 5","id":"opus"},"cwd":"WD",'
    json+='"context_window":{"remaining_percentage":50,"context_window_size":1000000},'
    json+='"cost":{"total_duration_ms":300000},"session_id":"ladder"}'

    _ladder_render() {  # _ladder_render <cols> <outfile> <errfile>
        printf '%s' "${json/WD/$wd}" \
            | ( cd "$wd" && env COLUMNS="$1" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/ladder.cache" bash "$STATUSLINE" ) \
              >"$2" 2>"$3"
    }
    _widest() {  # _widest <outfile> -> max visible columns across both lines
        local w=0 c
        while IFS= read -r line; do
            c=$(printf '%s' "$line" | vis_cols)
            [ "$c" -gt "$w" ] && w=$c
        done <"$1"
        printf '%s' "$w"
    }

    # 1. A short branch must SURVIVE the ladder, not collapse to "..". The dir is
    #    long enough that line 1 genuinely overflows, so the BRANCH step runs.
    #    An 8-char branch is the regression case that used to GROW to 10 chars.
    local br
    for br in main develop release1; do
        name="ladder-short-branch-$br"
        out="$SCRATCH/lad-$br.out"; err="$SCRATCH/lad-$br.err"
        ( cd "$repo" && git checkout -q -B "$br" ) >/dev/null 2>&1
        _ladder_render 44 "$out" "$err"
        stripped=$(sed -n '1p' "$out" | _strip_ansi)
        if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif ! _has "$stripped" "$br"; then
            _rl_fail "$name" "branch '$br' did not survive truncation: $stripped"
        elif _has "$stripped" "..$br"; then
            # Containing the name is not enough: "..release1" contains
            # "release1" while being two columns WIDER than the untrimmed name,
            # so a substring check alone cannot see the growth regression.
            _rl_fail "$name" "branch '$br' was widened to '..$br' by the trim step: $stripped"
        elif [ "$(_widest "$out")" -gt 43 ]; then
            _rl_fail "$name" "line exceeds COLUMNS-1: $(_widest "$out") > 43"
        else _rl_pass "$name"; fi
    done

    # 2. Convergence across the whole accepted COLUMNS range, with a branch and
    #    leaf both long enough to force every rung. The ladder must never leave
    #    a line wider than the viewport, at ANY width the code accepts.
    ( cd "$repo" && git checkout -q -B devmetaminds/feature/really-long-branch-name-here ) >/dev/null 2>&1
    name="ladder-converges"
    local failed_at=""
    for cols in 20 22 26 30 32 36 40 44 50 60 80; do
        out="$SCRATCH/lad-c$cols.out"; err="$SCRATCH/lad-c$cols.err"
        _ladder_render "$cols" "$out" "$err"
        cap=$((cols - 1))
        widest=$(_widest "$out")
        if [ -s "$err" ]; then failed_at="COLUMNS=$cols stderr: $(head -1 "$err")"; break; fi
        if [ "$(wc -l <"$out" | tr -d ' ')" -ne 2 ]; then
            failed_at="COLUMNS=$cols produced $(wc -l <"$out" | tr -d ' ') lines"; break
        fi
        if [ "$widest" -gt "$cap" ]; then
            failed_at="COLUMNS=$cols rendered $widest cols (cap $cap)"; break
        fi
    done
    if [ -n "$failed_at" ]; then _rl_fail "$name" "$failed_at"; else _rl_pass "$name"; fi

    # 3. Monotonicity: a narrower viewport must never render a WIDER line. This
    #    is the property the non-convergent ladder violated (30 cols -> 51 wide,
    #    while 40 cols -> 38 wide), and a width-cap assertion alone misses it
    #    whenever both widths happen to sit under their own caps.
    name="ladder-monotonic"
    local prev=0 cur bad=""
    for cols in 20 26 30 36 44 60 80; do
        out="$SCRATCH/lad-m$cols.out"; err="$SCRATCH/lad-m$cols.err"
        _ladder_render "$cols" "$out" "$err"
        cur=$(_widest "$out")
        if [ "$cur" -lt "$prev" ]; then
            bad="COLUMNS=$cols rendered $cur cols, narrower than the previous step's $prev"
        fi
        prev=$cur
    done
    if [ -n "$bad" ]; then _rl_fail "$name" "$bad"; else _rl_pass "$name"; fi

    # 3b. The viewport BAND. The tier is picked from the width, but only a
    #     measurement knows whether the wide render fits it: line 2's wide base
    #     (model, effort, clock, cost, context) has no truncation step, so just
    #     above the phone threshold every rate tier could be dropped and the
    #     line still overflowed, and the padding pass widened line 1 to match.
    #     Measured before the fallback: COLUMNS=61 rendered 74 columns. The band
    #     MOVES with the base, so a realistic payload (rate limits AND cost) is
    #     required; a bare payload has a base narrow enough to fit and the band
    #     does not exist for it. That is why this sweeps with _rl_json_rich.
    name="viewport-band"
    local band_fail=""
    for cols in $(seq 56 1 92); do
        out="$SCRATCH/band-$cols.out"; err="$SCRATCH/band-$cols.err"
        ( cd "$SCRATCH" && _rl_json_rich \
            | env COLUMNS="$cols" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/band-$cols.cache" bash "$STATUSLINE" ) \
            >"$out" 2>"$err"
        widest=$(_widest "$out")
        if [ -s "$err" ]; then band_fail="COLUMNS=$cols stderr: $(head -1 "$err")"; break; fi
        if [ "$widest" -gt "$((cols - 1))" ]; then
            band_fail="COLUMNS=$cols rendered $widest cols (cap $((cols - 1)))"; break
        fi
    done
    if [ -n "$band_fail" ]; then _rl_fail "$name" "$band_fail"; else _rl_pass "$name"; fi

    # 3c. Multibyte names, in whatever locale the suite is running. Bash counts
    #     BYTES for ${#s} and ${s: -n} when the locale is not UTF-8, while the
    #     width measurement counts codepoints, so under LC_ALL=C a 3-byte-per-
    #     character name used to shed a third of what the ladder thought and the
    #     render overflowed (COLUMNS=20 -> 23 cols) with a half-cut character in
    #     it. This test only discriminates under LC_ALL=C, which is exactly what
    #     the second suite run provides.
    name="phone-multibyte-leaf"
    local mb_leaf="日本語のディレクトリ名前テスト-très-long"
    local mb_dir="$repo/$mb_leaf"
    mkdir -p "$mb_dir"
    local mb_fail=""
    for cols in 20 24 28 32 40 52; do
        out="$SCRATCH/mb-$cols.out"; err="$SCRATCH/mb-$cols.err"
        printf '%s' "${json/WD/$mb_dir}" \
            | ( cd "$mb_dir" && env COLUMNS="$cols" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/mb-$cols.cache" bash "$STATUSLINE" ) \
              >"$out" 2>"$err"
        widest=$(_widest "$out")
        if [ -s "$err" ]; then mb_fail="COLUMNS=$cols stderr: $(head -1 "$err")"; break; fi
        if [ "$widest" -gt "$((cols - 1))" ]; then
            mb_fail="COLUMNS=$cols rendered $widest cols (cap $((cols - 1)))"; break
        fi
        # Byte slicing cuts a multibyte character in half; assert the output is
        # still decodable rather than merely narrow.
        if ! perl -e 'use Encode; my $s = do { local $/; <STDIN> };
                      eval { Encode::decode("UTF-8", $s, Encode::FB_CROAK) }; exit($@ ? 1 : 0);' <"$out"; then
            mb_fail="COLUMNS=$cols emitted invalid UTF-8 (a character was cut mid-sequence)"; break
        fi
    done
    if [ -n "$mb_fail" ]; then _rl_fail "$name" "$mb_fail"; else _rl_pass "$name"; fi

    # 4. The leaf directory is the last thing standing: at a width where nothing
    #    else fits, line 1 must still carry part of it (identity beats
    #    provenance), and must not be blank or a bare "..".
    name="ladder-keeps-the-leaf"
    out="$SCRATCH/lad-leaf.out"; err="$SCRATCH/lad-leaf.err"
    _ladder_render 22 "$out" "$err"
    stripped=$(sed -n '1p' "$out" | _strip_ansi)
    case "$stripped" in
        *[a-z]*) _rl_pass "$name" ;;
        *) _rl_fail "$name" "line 1 lost the directory entirely at COLUMNS=22: '$stripped'" ;;
    esac
}

# ── Phone gap tests (mutation-derived) ─────────────────────────────────────
# Each of these kills a mutant that survived the rest of the suite: the render
# could lose the service-icon width reservation, collapse to a lower rate tier,
# drop the git dirty markers, or print a constant context percentage, and every
# other assertion stayed green. A test nobody can fail is documentation, so
# these were written FROM the surviving mutants rather than from the feature
# description. Derived from the tester's proposed guards.
phone_gap_tests() {
    printf '\n'
    printf 'phone gap tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local name out err l1 l2 c w bad

    # The badge fixture is shared by G4 and G6, so it is built once up here.
    local bh="$SCRATCH/badge-home"
    mkdir -p "$bh/.claude"
    printf '{"oauthAccount":{"accountUuid":"11111111-2222-3333-4444-555555555555"}}\n' > "$bh/.claude.json"
    printf '{"enabled":true,"profiles":{"11111111-2222-3333-4444-555555555555":{"label":"very-long-account-label-here","color":"blue"}}}\n' \
        > "$bh/.claude/profile-labels.json"

    # G1. The service icon's width is reserved BEFORE the rate tier is chosen
    #     (AVAIL = TARGET - BASE_W - SVC_W). Nothing else in the suite seeds the
    #     service cache in phone mode, so dropping SVC_W from that subtraction
    #     shipped silently; with the cache seeded it overflows at 34/38/39/40.
    name="phone-svc-reserved"; bad=""
    printf 'operational\n' > "$SCRATCH/svc-seeded"
    for c in 34 38 39 40; do
        out="$SCRATCH/svc$c.out"; err="$SCRATCH/svc$c.err"
        ( cd "$SCRATCH" && _rl_json 100 1700009660 100 1700361000 \
            | env COLUMNS="$c" CC_STATUSLINE_SVC_CACHE="$SCRATCH/svc-seeded" \
                  XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/svc$c.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
        l2=$(_rl_l2 "$out")
        if [ -s "$err" ]; then bad="COLUMNS=$c stderr: $(head -1 "$err")"; break; fi
        _has "$l2" "✓" || { bad="COLUMNS=$c lost the service icon"; break; }
        w=$(sed -n '2p' "$out" | vis_cols)
        if [ "$w" -gt "$((c - 1))" ]; then bad="COLUMNS=$c line 2 is $w cols (cap $((c-1)))"; break; fi
    done
    if [ -n "$bad" ]; then _rl_fail "$name" "$bad"; else _rl_pass "$name"; fi

    # G2. Tier selection must actually DIFFER by width. "line 2 contains 5h and
    #     7d" passes for every tier, so a render that silently collapsed to the
    #     minimal tier was invisible: assert the countdown is present at 46 and
    #     that both windows survive at 30.
    name="phone-tier-detail"; bad=""
    ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
        | env COLUMNS=46 XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/t46.cache" bash "$STATUSLINE" ) \
        >"$SCRATCH/t46.out" 2>"$SCRATCH/t46.err"
    l2=$(_rl_l2 "$SCRATCH/t46.out")
    # Pin BOTH countdowns by value, not the ↻ glyph: the compact tier still
    # carries one ↻, so asserting the glyph passes on a render that silently
    # dropped the 5h countdown and fell back a tier. Verified: that mutant
    # survives a glyph check and dies against these two.
    _has "$l2" "↻2h41m" || bad="COLUMNS=46 lost the 5h reset countdown: $l2"
    _has "$l2" "↻4d4h"  || bad="${bad:-COLUMNS=46 lost the 7d reset countdown: $l2}"
    ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
        | env COLUMNS=30 XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/t30.cache" bash "$STATUSLINE" ) \
        >"$SCRATCH/t30.out" 2>"$SCRATCH/t30.err"
    l2=$(_rl_l2 "$SCRATCH/t30.out")
    { _has "$l2" "5h " && _has "$l2" "7d "; } || bad="${bad:-COLUMNS=30 dropped a window: $l2}"
    if [ -n "$bad" ]; then _rl_fail "$name" "$bad"; else _rl_pass "$name"; fi

    # G3. Phone line 1 keeps the git dirty markers when they fit, and the ctx
    #     fallback shows the REAL percentage rather than a constant.
    name="phone-l1-dirty-markers"
    local dr="$SCRATCH/dirty-repo"
    mkdir -p "$dr"
    ( cd "$dr" && git init -q -b main . && git -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m init && : > untracked ) >/dev/null 2>&1
    printf '{"model":{"display_name":"Claude Opus 4.6","id":"opus"},"cwd":"%s",' "$dr" \
        > "$SCRATCH/dirty.json"
    printf '"context_window":{"remaining_percentage":50,"context_window_size":1000000},' \
        >> "$SCRATCH/dirty.json"
    printf '"cost":{"total_duration_ms":300000},"session_id":"d"}' >> "$SCRATCH/dirty.json"
    ( cd "$dr" && env COLUMNS=46 XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
        CC_STATUSLINE_RL_CACHE="$SCRATCH/dirty.cache" bash "$STATUSLINE" <"$SCRATCH/dirty.json" ) \
        >"$SCRATCH/dirty.out" 2>"$SCRATCH/dirty.err"
    l1=$(sed -n '1p' "$SCRATCH/dirty.out" | _strip_ansi)
    l2=$(_rl_l2 "$SCRATCH/dirty.out")
    if [ -s "$SCRATCH/dirty.err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$SCRATCH/dirty.err")"
    elif ! _has "$l1" "?1"; then _rl_fail "$name" "line 1 lost the dirty marker: $l1"
    elif ! _has "$l2" "ctx 50%"; then _rl_fail "$name" "ctx fallback lost the real percentage: $l2"
    else _rl_pass "$name"; fi

    # G5. The service icon's width is also part of the WIDE-BASE FALLBACK
    #     condition (BASE_W + SVC_W > TARGET). Dropping the SVC_W term there
    #     leaves the suite green and overflows by up to 3 columns at 72-74 with
    #     a seeded service cache, because nothing else in the suite ever writes
    #     one. This is a different mutant from G1, which guards the AVAIL
    #     reservation; both terms are load-bearing and neither implies the other.
    name="phone-fallback-reserves-svc"; bad=""
    for c in 72 73 74; do
        out="$SCRATCH/fbsvc$c.out"; err="$SCRATCH/fbsvc$c.err"
        ( cd "$SCRATCH" && _rl_json_rich \
            | env COLUMNS="$c" CC_STATUSLINE_SVC_CACHE="$SCRATCH/svc-seeded" \
                  XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/fbsvc$c.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
        if [ -s "$err" ]; then bad="COLUMNS=$c stderr: $(head -1 "$err")"; break; fi
        w=$(_widest "$out")
        if [ "$w" -gt "$((c - 1))" ]; then bad="COLUMNS=$c rendered $w cols (cap $((c-1)))"; break; fi
    done
    if [ -n "$bad" ]; then _rl_fail "$name" "$bad"; else _rl_pass "$name"; fi

    # G6. The phone ctx fallback must be SHEDDABLE. Appended to line 2's base it
    #     could not be dropped by anything, so with a badge and no rate limits
    #     every viewport from 20 to 23 rendered 23 columns and the padding pass
    #     widened line 1 to match. Needs all three conditions at once (badge on,
    #     no rate limits, very narrow), which is why no other test sees it.
    name="phone-ctx-fallback-sheds"; bad=""
    printf '{"model":{"display_name":"Claude Opus 4.6","id":"opus"},"cwd":"/work/proj/leaf",' \
        > "$SCRATCH/norl-badge.json"
    printf '"context_window":{"remaining_percentage":0,"context_window_size":1000000},' \
        >> "$SCRATCH/norl-badge.json"
    printf '"cost":{"total_duration_ms":300000},"session_id":"ctxfb"}' >> "$SCRATCH/norl-badge.json"
    for c in 20 21 22 23 24 30; do
        out="$SCRATCH/ctxfb$c.out"; err="$SCRATCH/ctxfb$c.err"
        ( cd "$SCRATCH" && env COLUMNS="$c" HOME="$bh" STATUSLINE_PROFILE=1 \
            XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
            CC_STATUSLINE_RL_CACHE="$SCRATCH/ctxfb$c.cache" \
            bash "$STATUSLINE" <"$SCRATCH/norl-badge.json" ) >"$out" 2>"$err"
        if [ -s "$err" ]; then bad="COLUMNS=$c stderr: $(head -1 "$err")"; break; fi
        if [ "$(wc -l <"$out" | tr -d ' ')" -ne 2 ]; then bad="COLUMNS=$c produced $(wc -l <"$out" | tr -d ' ') lines"; break; fi
        w=$(_widest "$out")
        if [ "$w" -gt "$((c - 1))" ]; then bad="COLUMNS=$c rendered $w cols (cap $((c-1)))"; break; fi
    done
    # ...and it must still be SHOWN where it fits, or "sheddable" would be
    # satisfied by never rendering it at all.
    if [ -z "$bad" ] && ! _has "$(_rl_l2 "$SCRATCH/ctxfb30.out")" "ctx "; then
        bad="COLUMNS=30 dropped the ctx fallback even though it fits"
    fi
    if [ -n "$bad" ]; then _rl_fail "$name" "$bad"; else _rl_pass "$name"; fi

    # G4. The account badge lives in the phone line-2 base, which no tier can
    #     shed. A long label must be capped AND marked as truncated, and must
    #     not displace the rate limits that are the reason line 2 exists.
    name="phone-badge-fits"
    out="$SCRATCH/badge.out"; err="$SCRATCH/badge.err"
    ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
        | env COLUMNS=30 HOME="$bh" STATUSLINE_PROFILE=1 \
              XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/badge.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l2=$(_rl_l2 "$out"); w=$(sed -n '2p' "$out" | vis_cols)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$w" -gt 29 ]; then _rl_fail "$name" "badge pushed line 2 to $w cols at COLUMNS=30"
    elif ! _has "$l2" "5h"; then
        _rl_fail "$name" "badge displaced the rate limits: $l2"
    elif ! _has "$l2" "…"; then
        _rl_fail "$name" "a truncated badge is not marked as truncated: $l2"
    else _rl_pass "$name"; fi
}

# ── GitHub service-status tests ────────────────────────────────────────────
# The opt-in (STATUSLINE_GITHUB_STATUS=1) line-1 icon: same glyph vocabulary as
# the Claude icon, but only on a repo with a github.com remote. Covers the
# cache->glyph mapping (via the CC_STATUSLINE_GH_CACHE seam, which stands in for
# the remote probe), default-off, and the real git-remote probe both ways.
github_status_tests() {
    printf '\n'
    printf 'github status tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local name out err l1 spec cacheline want statedir
    local nofetch="$SCRATCH/no-such-gh-fetcher.sh"
    local gh_repo="$SCRATCH/gh-repo" nongh_repo="$SCRATCH/nongh-repo"
    statedir="$SCRATCH/gh-state/cc-statusline-$(id -u)"

    mkdir -p "$gh_repo" "$nongh_repo" "$statedir"
    ( cd "$gh_repo" && git init -q -b main . && git -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m init \
        && git remote add origin https://github.com/vtmocanu/cc-statusline.git ) >/dev/null 2>&1
    ( cd "$nongh_repo" && git init -q -b main . && git -c user.email=t@t -c user.name=t \
        commit -q --allow-empty -m init \
        && git remote add origin https://gitlab.com/vtmocanu/thing.git ) >/dev/null 2>&1

    _gh_json() {  # _gh_json <cwd>
        printf '{"model":{"display_name":"Claude Opus 5","id":"opus"},"cwd":"%s",' "$1"
        printf '"context_window":{"remaining_percentage":50,"context_window_size":1000000},'
        printf '"cost":{"total_duration_ms":300000},"session_id":"gh"}'
    }
    _gh_l1() { sed -n '1p' "$1" | _strip_ansi; }

    # A. Each cache state maps to the right glyph on line 1. Runs from a
    #    non-repo scratch cwd (no branch), so only the seeded status can add a
    #    glyph; the CC_STATUSLINE_GH_CACHE seam stands in for the remote probe.
    for spec in "operational=✓" \
                "incident:GitHub Actions incident=⚠" \
                "degraded_performance:x:Actions=~" \
                "partial_outage:x:Pages=✗" \
                "major_outage:x:Git Operations=✗"; do
        cacheline="${spec%=*}"; want="${spec##*=}"
        name="gh-glyph-$cacheline"
        out="$SCRATCH/ghg.out"; err="$SCRATCH/ghg.err"
        printf '%s\n' "$cacheline" > "$SCRATCH/gh-seam-cache"
        ( cd "$SCRATCH" && _gh_json "$SCRATCH" \
            | env STATUSLINE_GITHUB_STATUS=1 CC_STATUSLINE_GH_CACHE="$SCRATCH/gh-seam-cache" \
                  CC_STATUSLINE_GH_FETCH="$nofetch" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/gh.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
        l1=$(_gh_l1 "$out")
        if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif ! _has "$l1" "$want"; then _rl_fail "$name" "line 1 missing '$want' glyph: $l1"
        else _rl_pass "$name"; fi
    done

    # B. Opt-OUT: STATUSLINE_GITHUB_STATUS=0 must suppress the icon (and its
    #    separator) even on a github repo with a seeded cache.
    name="gh-explicit-off"; out="$SCRATCH/ghoff.out"; err="$SCRATCH/ghoff.err"
    printf 'major_outage:x:Git\n' > "$SCRATCH/gh-seam-cache"
    ( cd "$SCRATCH" && _gh_json "$SCRATCH" \
        | env STATUSLINE_GITHUB_STATUS=0 CC_STATUSLINE_GH_CACHE="$SCRATCH/gh-seam-cache" \
              CC_STATUSLINE_GH_FETCH="$nofetch" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/gh.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l1=$(_gh_l1 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "✗"; then _rl_fail "$name" "icon shown while opted out (=0): $l1"
    else _rl_pass "$name"; fi

    # C. Default ON via the real git-remote probe: with the var UNSET and a
    #    github.com origin, the icon shows, reading the DEFAULT cache path (no
    #    seam). XDG_RUNTIME_DIR points _state_dir at a scratch dir whose
    #    github-status file is pre-seeded.
    name="gh-default-on-github-remote"; out="$SCRATCH/ghp.out"; err="$SCRATCH/ghp.err"
    printf 'major_outage:x:Git\n' > "$statedir/github-status"
    ( cd "$gh_repo" && _gh_json "$gh_repo" \
        | env XDG_RUNTIME_DIR="$SCRATCH/gh-state" \
              CC_STATUSLINE_GH_FETCH="$nofetch" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/ghp.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l1=$(_gh_l1 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "✗"; then _rl_fail "$name" "github remote did not show the icon by default: $l1"
    else _rl_pass "$name"; fi

    # D. Real probe, NON-github origin -> no icon even by default with a seeded
    #    default cache (repo-scoping: GitHub health only where you push it).
    name="gh-nongithub-remote-no-icon"; out="$SCRATCH/ghn.out"; err="$SCRATCH/ghn.err"
    ( cd "$nongh_repo" && _gh_json "$nongh_repo" \
        | env XDG_RUNTIME_DIR="$SCRATCH/gh-state" \
              CC_STATUSLINE_GH_FETCH="$nofetch" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/ghn.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    l1=$(_gh_l1 "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "✗"; then _rl_fail "$name" "non-github repo showed the icon: $l1"
    else _rl_pass "$name"; fi

    # E. OSC 8 hyperlink on the glyph: on by default, wraps the icon in an
    #    \e]8;; ... link to githubstatus.com; STATUSLINE_HYPERLINKS=0 drops the
    #    escape while keeping the glyph. Asserts against the RAW line 1 (not
    #    _strip_ansi, which now strips OSC 8), and confirms the glyph survives.
    local raw1
    printf 'operational\n' > "$SCRATCH/gh-seam-cache"
    name="gh-hyperlink-default-on"; out="$SCRATCH/ghl.out"; err="$SCRATCH/ghl.err"
    ( cd "$SCRATCH" && _gh_json "$SCRATCH" \
        | env STATUSLINE_GITHUB_STATUS=1 CC_STATUSLINE_GH_CACHE="$SCRATCH/gh-seam-cache" \
              CC_STATUSLINE_GH_FETCH="$nofetch" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/ghl.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    raw1=$(sed -n '1p' "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$raw1" "8;;https://www.githubstatus.com"; then
        _rl_fail "$name" "line 1 has no OSC 8 link to githubstatus.com"
    elif ! _has "$(_gh_l1 "$out")" "✓"; then
        _rl_fail "$name" "glyph missing under the hyperlink"
    else _rl_pass "$name"; fi

    name="gh-hyperlink-opt-out"; out="$SCRATCH/ghlo.out"; err="$SCRATCH/ghlo.err"
    ( cd "$SCRATCH" && _gh_json "$SCRATCH" \
        | env STATUSLINE_GITHUB_STATUS=1 STATUSLINE_HYPERLINKS=0 \
              CC_STATUSLINE_GH_CACHE="$SCRATCH/gh-seam-cache" \
              CC_STATUSLINE_GH_FETCH="$nofetch" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/ghlo.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    raw1=$(sed -n '1p' "$out")
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$raw1" "8;;"; then _rl_fail "$name" "OSC 8 emitted while opted out (=0)"
    elif ! _has "$(_gh_l1 "$out")" "✓"; then _rl_fail "$name" "glyph dropped when hyperlinks off"
    else _rl_pass "$name"; fi
}

# ── Session name/title tests ───────────────────────────────────────────────
# Line 1 carries two distinct native identifiers:
#   @handle  the addressable name peers message (SendMessage to:), read ONLY from
#            Claude Code's per-session registry (~/.claude/sessions/<pid>.json
#            .name, keyed by .sessionId), via the CC_STATUSLINE_SESSIONS_DIR seam
#            so the suite never reads the real registry.
#   topic    the descriptive session title, read from the stdin .session_name
#            (Claude Code's /rename value or auto-generated title).
# These come from different sources and must not bleed into each other: a
# .session_name must NEVER appear as a handle, and the registry .name must NEVER
# appear as the topic. Covers both sources, both opt-outs
# (STATUSLINE_SESSION_NAME / STATUSLINE_TOPIC), coexistence, absence, and
# control-byte stripping of each user-controlled value.
session_name_tests() {
    printf '\n'
    printf 'session name/title tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local name out err l1 reg home esc
    reg="$SCRATCH/sess-reg"
    home="$SCRATCH/sess-home"; mkdir -p "$home/.claude"
    # A JSON escape for ESC (U+001B) built without a literal backslash-u in the
    # source, so jq decodes it to a real byte the statusline must strip.
    esc="$(printf '\\')u001b"

    _sess_json() {  # _sess_json <session_id> [session_name]  (name may hold $esc)
        printf '{"model":{"display_name":"Claude Opus 5","id":"opus"},"cwd":"/home/test/sess",'
        printf '"context_window":{"remaining_percentage":50,"context_window_size":1000000},'
        printf '"cost":{"total_duration_ms":300000},"session_id":"%s"' "$1"
        [ -n "${2:-}" ] && printf ',"session_name":"%s"' "$2"
        printf '}'
    }
    _sess_reg() {  # _sess_reg <sessionId> <name-json>  (name-json may hold $esc)
        rm -rf "$reg"; mkdir -p "$reg"
        printf '{"pid":123,"sessionId":"%s","name":"%s","nameSource":"derived","status":"idle"}\n' \
            "$1" "$2" > "$reg/123.json"
        # A second, non-matching entry proves the sessionId select is real.
        printf '{"pid":456,"sessionId":"other-sid","name":"other-99","status":"idle"}\n' \
            > "$reg/456.json"
    }
    _sess_run() {  # _sess_run <out> <err> <stdin-json> <env...>
        local o="$1" e="$2" j="$3"; shift 3
        ( cd "$SCRATCH" && printf '%s' "$j" \
            | env HOME="$home" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/sess.cache" "$@" \
                  bash "$STATUSLINE" ) >"$o" 2>"$e"
    }

    # 1. Registry .name is shown as the leading @handle, matched by sessionId.
    name="sess-handle-from-registry"; out="$SCRATCH/s1.out"; err="$SCRATCH/s1.err"
    _sess_reg "sid-1" "uzi-60"
    _sess_run "$out" "$err" "$(_sess_json sid-1)" CC_STATUSLINE_SESSIONS_DIR="$reg"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "@uzi-60"; then _rl_fail "$name" "line 1 missing @uzi-60 handle: $l1"
    elif _has "$l1" "other-99"; then _rl_fail "$name" "non-matching registry entry leaked: $l1"
    else _rl_pass "$name"; fi

    # 2. The handle is registry-ONLY: a stdin .session_name with no registry match
    #    must NOT become a handle. It appears as the topic instead (no @).
    name="sess-handle-is-registry-only"; out="$SCRATCH/s2.out"; err="$SCRATCH/s2.err"
    _sess_reg "sid-other" "uzi-60"   # registry present, but no entry for sid-2
    _sess_run "$out" "$err" "$(_sess_json sid-2 lonely-title)" CC_STATUSLINE_SESSIONS_DIR="$reg"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "@"; then _rl_fail "$name" "session_name leaked in as a handle: $l1"
    elif ! _has "$l1" "lonely-title"; then _rl_fail "$name" "session_name not shown as the topic: $l1"
    else _rl_pass "$name"; fi

    # 3. Both together: registry handle AND the native title (topic) coexist, with
    #    the title kept out of the @ segment.
    name="sess-handle-and-title"; out="$SCRATCH/s3.out"; err="$SCRATCH/s3.err"
    _sess_reg "sid-3" "uzi-60"
    _sess_run "$out" "$err" "$(_sess_json sid-3 Add-session-names)" CC_STATUSLINE_SESSIONS_DIR="$reg"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "@uzi-60"; then _rl_fail "$name" "handle missing: $l1"
    elif ! _has "$l1" "Add-session-names"; then _rl_fail "$name" "native title (topic) missing: $l1"
    elif _has "$l1" "@Add-session-names"; then _rl_fail "$name" "title bled into the handle: $l1"
    else _rl_pass "$name"; fi

    # 4. STATUSLINE_SESSION_NAME=0 hides the @handle; the topic still shows.
    name="sess-opt-out-handle"; out="$SCRATCH/s4.out"; err="$SCRATCH/s4.err"
    _sess_reg "sid-4" "uzi-60"
    _sess_run "$out" "$err" "$(_sess_json sid-4 keep-topic)" \
        CC_STATUSLINE_SESSIONS_DIR="$reg" STATUSLINE_SESSION_NAME=0
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "@"; then _rl_fail "$name" "opt-out still rendered a handle: $l1"
    elif ! _has "$l1" "keep-topic"; then _rl_fail "$name" "opt-out also dropped the topic: $l1"
    else _rl_pass "$name"; fi

    # 5. STATUSLINE_TOPIC=0 hides the title; the @handle still shows.
    name="sess-opt-out-topic"; out="$SCRATCH/s5.out"; err="$SCRATCH/s5.err"
    _sess_reg "sid-5" "uzi-60"
    _sess_run "$out" "$err" "$(_sess_json sid-5 drop-this-title)" \
        CC_STATUSLINE_SESSIONS_DIR="$reg" STATUSLINE_TOPIC=0
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "@uzi-60"; then _rl_fail "$name" "topic opt-out also dropped the handle: $l1"
    elif _has "$l1" "drop-this-title"; then _rl_fail "$name" "STATUSLINE_TOPIC=0 still showed the title: $l1"
    else _rl_pass "$name"; fi

    # 6. No registry match and no stdin title -> neither segment appears.
    name="sess-none"; out="$SCRATCH/s6.out"; err="$SCRATCH/s6.err"
    _sess_reg "sid-other" "uzi-60"
    _sess_run "$out" "$err" "$(_sess_json sid-6)" CC_STATUSLINE_SESSIONS_DIR="$reg"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "@"; then _rl_fail "$name" "a handle appeared with no source: $l1"
    else _rl_pass "$name"; fi

    # 7. Control byte in the registry name (a crafted /rename value) is stripped:
    #    no raw ESC reaches the line, stderr stays empty, "evil" survives as @evil.
    name="sess-handle-control-bytes"; out="$SCRATCH/s7.out"; err="$SCRATCH/s7.err"
    _sess_reg "sid-7" "ev${esc}il"
    _sess_run "$out" "$err" "$(_sess_json sid-7)" CC_STATUSLINE_SESSIONS_DIR="$reg"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "@evil"; then _rl_fail "$name" "handle control byte not stripped cleanly: $l1"
    else _rl_pass "$name"; fi

    # 8. Control byte in the stdin title is stripped too (same guard, its own site):
    #    "safe" survives as the topic, no raw ESC, stderr empty.
    name="sess-title-control-bytes"; out="$SCRATCH/s8.out"; err="$SCRATCH/s8.err"
    _sess_reg "sid-other" "uzi-60"
    _sess_run "$out" "$err" "$(_sess_json sid-8 "sa${esc}fe")" CC_STATUSLINE_SESSIONS_DIR="$reg"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "safe"; then _rl_fail "$name" "title control byte not stripped cleanly: $l1"
    else _rl_pass "$name"; fi
}

# ── Env-input hardening tests ──────────────────────────────────────────────
# Bash evaluates a variable's VALUE as an arithmetic expression and performs
# command substitution inside array subscripts while doing so, so any env value
# reaching $(( )) is an execution sink. These assert the charset gates hold:
# the payload must NOT run, the render must stay well-formed, and stderr must
# stay empty. The negative control (an ungated var) is what proves the probe
# itself works, so a gate that silently stopped being applied cannot read as a
# pass here.
env_hardening_tests() {
    printf '\n'
    printf 'env-input hardening tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local out err name marker lines
    local payload_dir="$SCRATCH/exec-probe"
    mkdir -p "$payload_dir"

    # Every env var that reaches arithmetic OR a numeric [ in statusline.sh.
    # Adding one to the script without adding it here is the regression this
    # list exists to catch. The last two reach a numeric [ rather than $(( )),
    # which cannot execute but does break the empty-stderr contract.
    local v
    for v in STATUSLINE_WIDTH STATUSLINE_GLYPH_MARGIN STATUSLINE_PHONE_COLS \
             CC_STATUSLINE_NOW COLUMNS \
             STATUSLINE_RL_AUTH_TTL STATUSLINE_RL_BACKOFF; do
        name="env-exec-$v"
        marker="$payload_dir/$v"
        out="$SCRATCH/env-$v.out"; err="$SCRATCH/env-$v.err"
        rm -f "$marker"
        ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
            | env "$v=PCT[\$(touch $marker)]" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/env-$v.cache" \
                  bash "$STATUSLINE" ) >"$out" 2>"$err"
        lines=$(wc -l <"$out" | tr -d ' ')
        if [ -e "$marker" ]; then
            _rl_fail "$name" "COMMAND EXECUTION: payload in \$$v ran (marker created)"
        elif [ -s "$err" ]; then
            _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif [ "$lines" -ne 2 ]; then
            _rl_fail "$name" "expected 2 lines with a hostile \$$v, got $lines"
        else _rl_pass "$name"; fi
    done

    # GPT cache TTLs reach the same arithmetic sinks, but only inside a detected
    # GPT render with a valid fetched line and backoff marker.
    for v in STATUSLINE_GPT_AUTH_TTL STATUSLINE_GPT_BACKOFF; do
        name="env-exec-$v"; marker="$payload_dir/$v"
        out="$SCRATCH/env-$v.out"; err="$SCRATCH/env-$v.err"
        rm -f "$marker"
        printf '|||65|1700361000|604800|1699999990\n' >"$SCRATCH/env-gpt.cache"
        : >"$SCRATCH/env-gpt.cache.backoff"
        touch -t 202311010000 "$SCRATCH/env-gpt.cache.backoff" 2>/dev/null
        (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
            | env "$v=PCT[\$(touch $marker)]" STATUSLINE_GPT_LIMITS=1 \
                  CC_STATUSLINE_GPT_CACHE="$SCRATCH/env-gpt.cache" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/env-gpt-claude.cache" \
                  bash "$STATUSLINE") >"$out" 2>"$err"
        lines=$(wc -l <"$out" | tr -d ' ')
        if [ -e "$marker" ]; then
            _rl_fail "$name" "COMMAND EXECUTION: payload in \$$v ran (marker created)"
        elif [ -s "$err" ]; then
            _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif [ "$lines" -ne 2 ]; then
            _rl_fail "$name" "expected 2 lines with a hostile \$$v, got $lines"
        else _rl_pass "$name"; fi
    done

    name="env-exec-STATUSLINE_GPT_CREDITS_TTL"
    marker="$payload_dir/STATUSLINE_GPT_CREDITS_TTL"
    out="$SCRATCH/env-STATUSLINE_GPT_CREDITS_TTL.out"; err="$SCRATCH/env-STATUSLINE_GPT_CREDITS_TTL.err"
    rm -f "$marker"
    printf '|||65|1700361000|604800|1699999990\n' >"$SCRATCH/env-credit-rate.cache"
    printf 'ok|2074808840|1699999990\n' >"$SCRATCH/env-credit.cache"
    (cd "$SCRATCH" && env "STATUSLINE_GPT_CREDITS_TTL=PCT[\$(touch $marker)]" \
        STATUSLINE_GPT_LIMITS=1 CC_STATUSLINE_GPT_CACHE="$SCRATCH/env-credit-rate.cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$SCRATCH/env-credit.cache" \
        CC_STATUSLINE_RL_CACHE="$SCRATCH/env-credit-claude.cache" \
        bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    lines=$(wc -l <"$out" | tr -d ' ')
    if [ -e "$marker" ]; then
        _rl_fail "$name" "COMMAND EXECUTION: payload in \$STATUSLINE_GPT_CREDITS_TTL ran"
    elif [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$lines" -ne 2 ]; then _rl_fail "$name" "expected 2 lines, got $lines"
    else _rl_pass "$name"; fi

    # Negative control: the same payload in a variable the script feeds to
    # arithmetic WITHOUT a gate does execute. If this stops executing, the probe
    # is broken and every pass above is meaningless.
    name="env-exec-probe-is-live"
    marker="$payload_dir/control"
    rm -f "$marker"
    ( cd "$SCRATCH" && bash -c 'V=$1; : $((V)); exit 0' _ "PCT[\$(touch $marker)]" ) >/dev/null 2>&1
    if [ -e "$marker" ]; then _rl_pass "$name"
    else _rl_fail "$name" "probe did not execute in the ungated control; the exec tests above prove nothing"; fi

    # A non-numeric value must fall back to the default, not blank the render.
    # `STATUSLINE_WIDTH=abc` used to abort at TARGET=$(( )) under set -u and
    # emit a single empty line, i.e. no statusline at all.
    for v in STATUSLINE_WIDTH STATUSLINE_GLYPH_MARGIN CC_STATUSLINE_NOW \
             STATUSLINE_RL_AUTH_TTL STATUSLINE_RL_BACKOFF; do
        name="env-junk-$v"
        out="$SCRATCH/junk-$v.out"; err="$SCRATCH/junk-$v.err"
        # The two RL vars are only COMPARED when an authoritative (5-field,
        # fetch-stamped) cache exists and, for the backoff, a .backoff marker.
        # Without both, the branch never runs and the assertion cannot fail:
        # verified against the pre-fix script, where an unseeded run passes and
        # a seeded one reports "[: abc: integer expected".
        printf '90|1700018000|70|1700200000|1699999990\n' > "$SCRATCH/junk-$v.cache"
        : > "$SCRATCH/junk-$v.cache.backoff"
        # The marker's age is computed against the PINNED clock (2023-11-14), so
        # a marker created now yields a negative age and the `-ge 0` test
        # short-circuits before the junk value is ever compared. Backdate it.
        touch -t 202311010000 "$SCRATCH/junk-$v.cache.backoff" 2>/dev/null
        ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
            | env "$v=abc" CC_STATUSLINE_RL_CACHE="$SCRATCH/junk-$v.cache" \
                  bash "$STATUSLINE" ) >"$out" 2>"$err"
        lines=$(wc -l <"$out" | tr -d ' ')
        if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif [ "$lines" -ne 2 ]; then
            _rl_fail "$name" "junk \$$v produced $lines lines (expected 2, i.e. the default was used)"
        else _rl_pass "$name"; fi
    done

    for v in STATUSLINE_GPT_AUTH_TTL STATUSLINE_GPT_BACKOFF; do
        name="env-junk-$v"; out="$SCRATCH/junk-$v.out"; err="$SCRATCH/junk-$v.err"
        printf '|||65|1700361000|604800|1699999990\n' >"$SCRATCH/junk-gpt.cache"
        : >"$SCRATCH/junk-gpt.cache.backoff"
        touch -t 202311010000 "$SCRATCH/junk-gpt.cache.backoff" 2>/dev/null
        (cd "$SCRATCH" && _gpt_json gpt-5.6-sol \
            | env "$v=abc" STATUSLINE_GPT_LIMITS=1 \
                  CC_STATUSLINE_GPT_CACHE="$SCRATCH/junk-gpt.cache" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/junk-gpt-claude.cache" \
                  bash "$STATUSLINE") >"$out" 2>"$err"
        lines=$(wc -l <"$out" | tr -d ' ')
        if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif [ "$lines" -ne 2 ]; then
            _rl_fail "$name" "junk \$$v produced $lines lines (expected 2)"
        else _rl_pass "$name"; fi
    done

    name="env-junk-STATUSLINE_GPT_CREDITS_TTL"
    out="$SCRATCH/junk-STATUSLINE_GPT_CREDITS_TTL.out"; err="$SCRATCH/junk-STATUSLINE_GPT_CREDITS_TTL.err"
    printf '|||65|1700361000|604800|1699999990\n' >"$SCRATCH/junk-credit-rate.cache"
    printf 'ok|2074808840|1699999990\n' >"$SCRATCH/junk-credit.cache"
    (cd "$SCRATCH" && env STATUSLINE_GPT_CREDITS_TTL=abc STATUSLINE_GPT_LIMITS=1 \
        CC_STATUSLINE_GPT_CACHE="$SCRATCH/junk-credit-rate.cache" \
        CC_STATUSLINE_GPT_CREDITS_CACHE="$SCRATCH/junk-credit.cache" \
        CC_STATUSLINE_RL_CACHE="$SCRATCH/junk-credit-claude.cache" \
        bash "$STATUSLINE" <"$SCRATCH/gpt-transcript.json") >"$out" 2>"$err"
    lines=$(wc -l <"$out" | tr -d ' ')
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$lines" -ne 2 ]; then _rl_fail "$name" "junk credit TTL produced $lines lines"
    else _rl_pass "$name"; fi

    # A value too large for the shell's integer conversion must not reach a bare
    # `[`, and a zero-padded one must not be read as octal (060 is 60, not 48).
    name="env-columns-overflow"
    out="$SCRATCH/cols-of.out"; err="$SCRATCH/cols-of.err"
    ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
        | env COLUMNS=99999999999999999999 \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/cols-of.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    else _rl_pass "$name"; fi

    # The value has to STRADDLE the threshold under the two readings or the
    # test cannot fail: 060 is 60 decimal / 48 octal and both select phone, so
    # it proves nothing. 070 is 70 decimal (SAFE_WIDTH 69 -> wide) and 56 octal
    # (SAFE_WIDTH 55 -> phone), so the layout is the discriminator.
    name="env-columns-zero-padded"
    out="$SCRATCH/cols-pad.out"; err="$SCRATCH/cols-pad.err"
    ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
        | env COLUMNS=070 XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/cols-pad.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$(_rl_l2 "$out")" "of 1000k"; then
        _rl_fail "$name" "COLUMNS=070 was read as octal (56): layout flipped to phone"
    else _rl_pass "$name"; fi

    # The stdin JSON reaches the same arithmetic sinks as the environment does.
    # Narrower threat model (it needs control of what Claude Code sends, not
    # just the process env), identical mechanism: context_window_size lands in
    # CTX_SIZE_K=$((CTX_SIZE / 1000)) and total_duration_ms in
    # TOTAL_SEC=$((DURATION_MS / 1000)).
    local field
    for field in ctx dur; do
        name="json-exec-$field"
        marker="$payload_dir/json-$field"
        out="$SCRATCH/json-$field.out"; err="$SCRATCH/json-$field.err"
        rm -f "$marker"
        if [ "$field" = ctx ]; then
            printf '{"model":{"display_name":"O","id":"opus"},"cwd":"/home/test/rl",'  >"$SCRATCH/json-$field.json"
            printf '"context_window":{"remaining_percentage":50,'                     >>"$SCRATCH/json-$field.json"
            printf '"context_window_size":"PCT[$(touch %s)]"},'          "$marker"    >>"$SCRATCH/json-$field.json"
            printf '"cost":{"total_duration_ms":300000},"session_id":"j"}'            >>"$SCRATCH/json-$field.json"
        else
            printf '{"model":{"display_name":"O","id":"opus"},"cwd":"/home/test/rl",'  >"$SCRATCH/json-$field.json"
            printf '"context_window":{"remaining_percentage":50,'                     >>"$SCRATCH/json-$field.json"
            printf '"context_window_size":1000000},'                                  >>"$SCRATCH/json-$field.json"
            printf '"cost":{"total_duration_ms":"PCT[$(touch %s)]"},'     "$marker"    >>"$SCRATCH/json-$field.json"
            printf '"session_id":"j"}'                                                >>"$SCRATCH/json-$field.json"
        fi
        ( cd "$SCRATCH" && env CC_STATUSLINE_RL_CACHE="$SCRATCH/json-$field.cache" \
            bash "$STATUSLINE" <"$SCRATCH/json-$field.json" ) >"$out" 2>"$err"
        lines=$(wc -l <"$out" | tr -d ' ')
        if [ -e "$marker" ]; then
            _rl_fail "$name" "COMMAND EXECUTION: hostile stdin JSON ($field) ran"
        elif [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif [ "$lines" -ne 2 ]; then _rl_fail "$name" "expected 2 lines, got $lines"
        else _rl_pass "$name"; fi
    done

    # A hostile layout-override file must not survive the case match.
    name="env-layout-file-hostile"
    out="$SCRATCH/layout-h.out"; err="$SCRATCH/layout-h.err"
    mkdir -p "$SCRATCH/xdg-hostile/cc-statusline"
    printf 'phoney; touch %s/layout-pwn\n' "$payload_dir" > "$SCRATCH/xdg-hostile/cc-statusline/layout"
    ( cd "$SCRATCH" && _rl_json 15 1700009660 2 1700361000 \
        | env XDG_CONFIG_HOME="$SCRATCH/xdg-hostile" COLUMNS=200 \
              CC_STATUSLINE_RL_CACHE="$SCRATCH/layout-h.cache" bash "$STATUSLINE" ) >"$out" 2>"$err"
    lines=$(wc -l <"$out" | tr -d ' ')
    if [ -e "$payload_dir/layout-pwn" ]; then
        _rl_fail "$name" "COMMAND EXECUTION: layout file contents ran"
    elif [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$lines" -ne 2 ]; then _rl_fail "$name" "expected 2 lines, got $lines"
    elif ! _has "$(_rl_l2 "$out")" "of 1000k"; then
        _rl_fail "$name" "unrecognized layout value was not ignored (expected the wide render)"
    else _rl_pass "$name"; fi
}

if [ ! -x "$STATUSLINE" ]; then
    printf 'error: %s is not executable\n' "$STATUSLINE" >&2
    exit 2
fi

# Effort source precedence. Claude Code sends the live level as stdin
# .effort.level and exports CLAUDE_EFFORT; both must beat settings.json, which
# only holds the saved default (a --effort launch flag never reaches it).
effort_tests() {
    printf '\n'
    printf 'effort level tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local home="$SCRATCH/effort-home" esc
    mkdir -p "$home/.claude"
    printf '{"effortLevel":"xhigh"}\n' > "$home/.claude/settings.json"
    esc="$(printf '\\')u001b"

    _eff_json() {  # _eff_json [effort-json-value]
        printf '{"model":{"display_name":"Claude Opus 5","id":"opus"},"cwd":"/home/test/eff",'
        printf '"context_window":{"remaining_percentage":50,"context_window_size":1000000},'
        printf '"cost":{"total_duration_ms":300000},"session_id":"eff"'
        [ -n "${1:-}" ] && printf ',"effort":{"level":%s}' "$1"
        printf '}'
    }
    _eff_case() {  # _eff_case <name> <want> <stdin-json> <env...>
        local name="$1" want="$2" j="$3" out="$SCRATCH/eff.out" err="$SCRATCH/eff.err" l2
        shift 3
        ( cd "$SCRATCH" && printf '%s' "$j" \
            | env HOME="$home" XDG_CONFIG_HOME="$SCRATCH/xdg-empty" \
                  CC_STATUSLINE_RL_CACHE="$SCRATCH/eff.cache" "$@" \
                  bash "$STATUSLINE" ) >"$out" 2>"$err"
        l2=$(sed -n '2p' "$out" | _strip_ansi)
        if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif ! _has "$l2" "Claude Opus 5 · $want "; then _rl_fail "$name" "want effort $want: $l2"
        elif LC_ALL=C grep -q $'\033\\[[0-9;]*[^0-9;m]' "$out"; then _rl_fail "$name" "stray escape in output"
        else _rl_pass "$name"; fi
    }

    _eff_case effort-settings-fallback xhigh "$(_eff_json)"
    _eff_case effort-stdin-beats-settings low "$(_eff_json '"low"')"
    _eff_case effort-env-beats-settings max "$(_eff_json)" CLAUDE_EFFORT=max
    _eff_case effort-stdin-beats-env medium "$(_eff_json '"medium"')" CLAUDE_EFFORT=max
    _eff_case effort-stdin-escape-rejected high "$(_eff_json "\"hi${esc}[31mgh\"")" CLAUDE_EFFORT=high
    _eff_case effort-stdin-nonstring-ignored xhigh "$(_eff_json 3)"
    _eff_case effort-stdin-uppercase-ignored xhigh "$(_eff_json '"HIGH"')"
    _eff_case effort-env-malformed-ignored xhigh "$(_eff_json)" "CLAUDE_EFFORT=hi gh"
}

cache_timer_tests() {
    printf '\n'
    printf 'prompt-cache timer tests\n'
    printf '%s\n' "------------------------------------------------------------"

    # NOW is pinned to 1700000000 (CC_STATUSLINE_NOW above).
    local fire snow alert zap
    zap=$(printf '\xef\x83\xa7'); fire=$(printf '\xef\x81\xad'); alert=$(printf '\xf3\xb1\x97\x97'); snow=$(printf '\xef\x8b\x9c')

    _pc_json() {  # _pc_json [prompt_cache-json] [model-id] [transcript-path]
        printf '{"model":{"display_name":"Claude Opus 5","id":"%s"},"cwd":"/home/test/pc",' "${2:-opus}"
        printf '"context_window":{"remaining_percentage":50,"context_window_size":1000000,'
        printf '"current_usage":{"input_tokens":1000,"cache_creation_input_tokens":4000,"cache_read_input_tokens":95000}},'
        printf '"cost":{"total_duration_ms":300000},"session_id":"pc",'
        [ -n "${3:-}" ] && printf '"transcript_path":"%s",' "$3"
        printf '"rate_limits":{"five_hour":{"used_percentage":15,"resets_at":0},"seven_day":{"used_percentage":2,"resets_at":0}}'
        [ -n "${1:-}" ] && printf ',"prompt_cache":%s' "$1"
        printf '}'
    }
    # _pc_case <name> <want-substring|!unwanted|-> <stdin-json> <env...>
    # "-" asserts the timer is hidden: none of its three icons on line 2.
    # Width is checked against the case's own STATUSLINE_WIDTH when it sets one.
    _pc_case() {
        local name="$1" want="$2" j="$3" out="$SCRATCH/pc.out" err="$SCRATCH/pc.err" l2 cols max limit="$SAFE_WIDTH" a
        shift 3
        for a in "$@"; do case "$a" in STATUSLINE_WIDTH=*) limit="${a#STATUSLINE_WIDTH=}" ;; esac; done
        ( cd "$SCRATCH" && printf '%s' "$j" \
            | env -u STATUSLINE_CACHE_TIMER CC_STATUSLINE_RL_CACHE="$SCRATCH/pc.cache" "$@" \
                  bash "$STATUSLINE" ) >"$out" 2>"$err"
        l2=$(sed -n '2p' "$out" | _strip_ansi)
        max=0
        while IFS= read -r line; do
            cols=$(printf '%s' "$line" | vis_cols)
            [ "$cols" -gt "$max" ] && max=$cols
        done <"$out"
        if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
        elif [ "$(wc -l <"$out" | tr -d ' ')" -ne 2 ]; then _rl_fail "$name" "expected 2 lines"
        elif [ "$max" -gt "$limit" ]; then _rl_fail "$name" "line is $max cols (> $limit)"
        else
            case "$want" in
                -)  if _has "$l2" "$fire" || _has "$l2" "$alert" || _has "$l2" "$snow"; then
                        _rl_fail "$name" "timer should be hidden: $l2"; else _rl_pass "$name"; fi ;;
                !*) if _has "$l2" "${want#!}"; then _rl_fail "$name" "unexpected '${want#!}': $l2"; else _rl_pass "$name"; fi ;;
                *)  if _has "$l2" "$want"; then _rl_pass "$name"; else _rl_fail "$name" "want '$want': $l2"; fi ;;
            esac
        fi
    }

    local w='"caching_observed":true,"warm":true'
    _pc_case pc-warm-1h         "$fire 50m"      "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}")"
    _pc_case pc-warm-rounds-up  "$fire 4m·5m"    "$(_pc_json "{$w,\"ttl\":\"5m\",\"expires_at\":1700000181}")"
    _pc_case pc-expiring-alert  "$alert 12m"     "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700000700}")"
    _pc_case pc-5m-tag          "$fire 4m·5m"    "$(_pc_json "{$w,\"ttl\":\"5m\",\"expires_at\":1700000240}")"
    _pc_case pc-last-minute     "$alert <1m·5m"  "$(_pc_json "{$w,\"ttl\":\"5m\",\"expires_at\":1700000040}")"
    _pc_case pc-1h-untagged     "!m·"            "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}")"
    _pc_case pc-without-hitrate "!$zap"          "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}")" STATUSLINE_CACHE=0
    _pc_case pc-with-hitrate    "$zap 95% $fire 50m" "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}")" STATUSLINE_CACHE=1
    _pc_case pc-skew-capped     "$fire 60m"      "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1799999999}")"
    _pc_case pc-expired-clock   "$snow 184k"     "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1699999000,\"recache_tokens_if_cold\":184000}")"
    _pc_case pc-cold-millions   "$snow 1.2M"     "$(_pc_json '{"caching_observed":true,"warm":false,"expires_at":null,"recache_tokens_if_cold":1234567}')"
    _pc_case pc-cold-unknown    "$snow cold"     "$(_pc_json '{"caching_observed":true,"warm":false,"expires_at":null,"recache_tokens_if_cold":null}')"
    _pc_case pc-caching-off     "-"              "$(_pc_json '{"caching_observed":false,"warm":false}')"
    _pc_case pc-absent          "-"              "$(_pc_json)"
    _pc_case pc-toggle-off      "-"              "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}")" STATUSLINE_CACHE_TIMER=0
    # warm=true with unusable timer data is unknown, not cold: hidden.
    _pc_case pc-garbage-warm    "-"              "$(_pc_json '{"caching_observed":true,"warm":"yes","ttl":"2h","expires_at":"soon","recache_tokens_if_cold":-5}')"
    _pc_case pc-warm-no-ttl     "-"              "$(_pc_json '{"caching_observed":true,"warm":true,"expires_at":1700003000}')"
    _pc_case pc-huge-numbers    "-"              "$(_pc_json '{"caching_observed":true,"warm":true,"ttl":"1h","expires_at":1e300,"recache_tokens_if_cold":1e300}')"
    _pc_case pc-cold-bad-count  "$snow cold"     "$(_pc_json '{"caching_observed":true,"warm":false,"recache_tokens_if_cold":1e300}')"
    # OpenAI-backed panes: Claude Code's TTL does not describe OpenAI's cache.
    # Hidden with or without STATUSLINE_GPT_LIMITS, by stdin id or transcript.
    _pc_case pc-gpt-stdin       "-"              "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}" gpt-6-sol)"
    _pc_case pc-gpt-limits-on   "-"              "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}" claude-ocx-native--gpt-6-sol)" STATUSLINE_GPT_LIMITS=1
    _pc_case pc-gpt-apikey      "-"              "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}" clodex:openai:gpt-6-sol)"
    printf '{"type":"assistant","message":{"model":"gpt-6-sol","content":[]}}\n' >"$SCRATCH/pc-gpt.transcript.jsonl"
    _pc_case pc-gpt-transcript  "-"              "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}" opus pc-gpt.transcript.jsonl)"
    printf '{"type":"assistant","message":{"model":"claude-sonnet-5","content":[]}}\n' >"$SCRATCH/pc-claude.transcript.jsonl"
    _pc_case pc-claude-transcript "$fire 50m"    "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}" opus pc-claude.transcript.jsonl)"
    # Phone layout drops cache and timer alike.
    _pc_case pc-phone-hidden    "-"              "$(_pc_json "{$w,\"ttl\":\"1h\",\"expires_at\":1700003000}")" STATUSLINE_LAYOUT=phone
    # Narrow line: the timer outranks the hit rate, so the hit rate is shed first
    # (the final-minute "<1m·5m" is the widest timer and the most urgent).
    _pc_case pc-narrow-keeps-timer "$alert <1m·5m" "$(_pc_json "{$w,\"ttl\":\"5m\",\"expires_at\":1700000040}")" STATUSLINE_CACHE=1 STATUSLINE_WIDTH=86
    _pc_case pc-narrow-drops-rate  "!$zap"       "$(_pc_json "{$w,\"ttl\":\"5m\",\"expires_at\":1700000040}")" STATUSLINE_CACHE=1 STATUSLINE_WIDTH=86
    # Narrower still: the timer no longer fits alone, but the hit rate does.
    _pc_case pc-narrow-hitrate-only "$zap 95%" "$(_pc_json "{$w,\"ttl\":\"5m\",\"expires_at\":1700000040}")" STATUSLINE_CACHE=1 STATUSLINE_WIDTH=83
    _pc_case pc-narrow-hitrate-only-2 "-"               "$(_pc_json "{$w,\"ttl\":\"5m\",\"expires_at\":1700000040}")" STATUSLINE_CACHE=1 STATUSLINE_WIDTH=83
}

# ── Peer-session tests ─────────────────────────────────────────────────────
# The right-aligned line-1 segment counts EVERY live session in the same repo
# (this one included; shown only when at least one other exists)
# from the session registry (CC_STATUSLINE_SESSIONS_DIR seam): ⚙ busy, ◷ shell,
# ○ idle, zero counts omitted. A throwaway repo with a linked worktree at an
# unrelated path proves "same repo" follows `git worktree list`, not the path.
# Live pids come from this harness ($$); a reaped background job supplies a
# pid that is certainly dead.
peer_tests() {
    printf '\n'
    printf 'peer-session tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local name out err l1 reg repo wt other dead w1 w2
    reg="$SCRATCH/peer-reg"
    # cd -P: git reports physical paths (macOS TMPDIR sits behind /var -> /private/var)
    repo="$(mkdir -p "$SCRATCH/peer-repo" && cd -P "$SCRATCH/peer-repo" && pwd)"
    wt="$(cd -P "$SCRATCH" && pwd)/peer-wt-elsewhere"
    other="$(mkdir -p "$SCRATCH/peer-other" && cd -P "$SCRATCH/peer-other" && pwd)"
    git -C "$repo" init -q 2>/dev/null
    git -C "$repo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init 2>/dev/null
    git -C "$repo" worktree add -q -b peer-wt "$wt" 2>/dev/null
    mkdir -p "$repo/sub"
    git -C "$other" init -q 2>/dev/null
    sleep 0 & dead=$!; wait "$dead" 2>/dev/null

    _peer_entry() {  # _peer_entry <file-id> <pid> <sessionId> <status> <cwd>
        printf '{"pid":%s,"sessionId":"%s","name":"p-%s","status":"%s","cwd":"%s"}\n' \
            "$2" "$3" "$1" "$4" "$5" > "$reg/$1.json"
    }
    _peer_run() {  # _peer_run <out> <err> <env...>
        local o="$1" e="$2"; shift 2
        ( cd "$SCRATCH" && printf '{"model":{"display_name":"Claude Opus 5","id":"opus"},"cwd":"%s","context_window":{"remaining_percentage":50,"context_window_size":1000000},"cost":{"total_duration_ms":300000},"session_id":"self-sid"}' "$repo" \
            | env CC_STATUSLINE_SESSIONS_DIR="$reg" CC_STATUSLINE_RL_CACHE="$SCRATCH/peer.cache" "$@" \
                  bash "$STATUSLINE" ) >"$o" 2>"$e"
    }
    _peer_full_reg() {
        rm -rf "$reg"; mkdir -p "$reg"
        _peer_entry self  "$$"    self-sid busy  "$repo"         # this session: counted ⚙ (repo-wide view)
        _peer_entry busy  "$$"    sid-b    busy  "$repo"         # counted ⚙
        _peer_entry shell "$$"    sid-s    shell "$wt"           # linked worktree: counted ◷
        _peer_entry idle  "$$"    sid-i    idle  "$repo/sub"     # subdir: counted ○
        _peer_entry other "$$"    sid-o    busy  "$other"        # other repo: excluded
        _peer_entry dead  "$dead" sid-d    busy  "$repo"         # dead pid: excluded
        _peer_entry odd   "$$"    sid-u    weird "$repo"         # unknown status: ignored
        _peer_entry pref  "$$"    sid-p    busy  "${repo}-sibling" # path-prefix lookalike: excluded
        # Codex shim (session-peers): a Codex run, not a Claude session: excluded
        printf '{"pid":%s,"sessionId":"sid-c","name":"codex-x","status":"busy","cwd":"%s","entrypoint":"codex"}\n' \
            "$$" "$repo" > "$reg/codex.json"
    }

    # 1. Mixed registry -> self + one busy peer = ⚙2, one shell, one idle;
    #    every other entry filtered.
    name="peers-counts-and-filters"; out="$SCRATCH/pe1.out"; err="$SCRATCH/pe1.err"
    _peer_full_reg
    _peer_run "$out" "$err"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "[⚙2] ◷1 ○1"; then _rl_fail "$name" "expected '[⚙2] ◷1 ○1' on line 1: $l1"
    else _rl_pass "$name"; fi

    # 2. Both lines stay the same width and within budget with the segment placed.
    name="peers-width"
    w1=$(sed -n '1p' "$out" | vis_cols); w2=$(sed -n '2p' "$out" | vis_cols)
    if [ "$w1" -ne "$w2" ]; then _rl_fail "$name" "line widths differ: $w1 vs $w2"
    elif [ "$w1" -gt "$((SAFE_WIDTH + WIDTH_SLOP))" ]; then _rl_fail "$name" "width $w1 exceeds budget"
    else _rl_pass "$name"; fi

    # 3. Zero counts are omitted: only an idle peer -> "○1", no busy/shell glyph.
    name="peers-zero-counts-hidden"; out="$SCRATCH/pe3.out"; err="$SCRATCH/pe3.err"
    rm -rf "$reg"; mkdir -p "$reg"
    _peer_entry idle "$$" sid-i idle "$repo"
    _peer_run "$out" "$err"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "○1"; then _rl_fail "$name" "idle count missing: $l1"
    elif _has "$l1" "⚙" || _has "$l1" "◷"; then _rl_fail "$name" "zero count rendered: $l1"
    else _rl_pass "$name"; fi

    # 4. Only this session (and filtered entries) -> no segment at all: a solo
    #    session renders as before even though it would count itself.
    name="peers-none-no-segment"; out="$SCRATCH/pe4.out"; err="$SCRATCH/pe4.err"
    rm -rf "$reg"; mkdir -p "$reg"
    _peer_entry self  "$$"    self-sid busy "$repo"
    _peer_entry dead  "$dead" sid-d    busy "$repo"
    _peer_entry other "$$"    sid-o    idle "$other"
    _peer_run "$out" "$err"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "⚙" || _has "$l1" "◷" || _has "$l1" "○"; then _rl_fail "$name" "segment shown with no peers: $l1"
    else _rl_pass "$name"; fi

    # 5. STATUSLINE_PEERS=0 opts out.
    name="peers-opt-out"; out="$SCRATCH/pe5.out"; err="$SCRATCH/pe5.err"
    _peer_full_reg
    _peer_run "$out" "$err" STATUSLINE_PEERS=0
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif _has "$l1" "⚙" || _has "$l1" "◷" || _has "$l1" "○"; then _rl_fail "$name" "STATUSLINE_PEERS=0 still rendered: $l1"
    else _rl_pass "$name"; fi

    # 6. Peers and the update indicator share the right edge, peers first.
    name="peers-with-update-indicator"; out="$SCRATCH/pe6.out"; err="$SCRATCH/pe6.err"
    printf 'v99.0.0\n' > "$SCRATCH/peer-upd-cache"
    _peer_run "$out" "$err" CC_STATUSLINE_UPDATE_CACHE="$SCRATCH/peer-upd-cache"
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    w1=$(sed -n '1p' "$out" | vis_cols)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l1" "[⚙2] ◷1 ○1 │ ⇡ 99.0.0"; then _rl_fail "$name" "expected peers then update: $l1"
    elif [ "$w1" -gt "$((SAFE_WIDTH + WIDTH_SLOP))" ]; then _rl_fail "$name" "width $w1 exceeds budget"
    else _rl_pass "$name"; fi

    # 7. Narrow viewport: the segment is dropped, never truncated, and the
    #    line still fits.
    name="peers-narrow-dropped-not-cut"; out="$SCRATCH/pe7.out"; err="$SCRATCH/pe7.err"
    _peer_run "$out" "$err" STATUSLINE_WIDTH=40
    l1=$(sed -n '1p' "$out" | _strip_ansi)
    w1=$(sed -n '1p' "$out" | vis_cols)
    if [ -s "$err" ]; then _rl_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif [ "$w1" -gt 40 ]; then _rl_fail "$name" "width $w1 exceeds 40"
    elif { _has "$l1" "⚙" || _has "$l1" "○"; } && ! _has "$l1" "[⚙2] ◷1 ○1"; then _rl_fail "$name" "segment partially rendered: $l1"
    else _rl_pass "$name"; fi

    git -C "$repo" worktree remove --force "$wt" 2>/dev/null || true

    # ── "?" state: an idle session whose last reply asked something. The
    #    transcript is found by session id under CC_STATUSLINE_PROJECTS_DIR.
    local proj ask_txt done_txt ask_tool
    proj="$SCRATCH/peer-projects"
    ask_txt='{"type":"assistant","message":{"content":[{"type":"text","text":"Done the first part.\n\nShall I **continue?**"}]}}'
    done_txt='{"type":"assistant","message":{"content":[{"type":"text","text":"Is it fixed? Yes.\n\nAll tests pass."}]}}'
    ask_tool='{"type":"assistant","message":{"content":[{"type":"tool_use","name":"AskUserQuestion","input":{}}]}}'
    _peer_tr() {  # _peer_tr <sessionId> <transcript-line>
        mkdir -p "$proj/-some-project"
        printf '%s\n' "$2" > "$proj/-some-project/$1.jsonl"
    }
    _ask_case() {  # _ask_case <name> <expect> <reject-or-empty>
        local n="$1" want="$2" reject="$3"
        out="$SCRATCH/$n.out"; err="$SCRATCH/$n.err"
        _peer_run "$out" "$err" CC_STATUSLINE_PROJECTS_DIR="$proj"
        raw=$(sed -n '1p' "$out"); l1=$(printf '%s' "$raw" | _strip_ansi)
        if [ -s "$err" ]; then _rl_fail "$n" "non-empty stderr: $(head -1 "$err")"
        elif ! _has "$l1" "$want"; then _rl_fail "$n" "expected '$want': $l1"
        elif [ -n "$reject" ] && _has "$l1" "$reject"; then _rl_fail "$n" "unexpected '$reject': $l1"
        else _rl_pass "$n"; fi
    }
    local raw
    rm -rf "$reg" "$proj"; mkdir -p "$reg"
    _peer_entry self "$$" self-sid busy "$repo"
    _peer_entry q    "$$" sid-q    idle "$repo"
    _peer_entry d    "$$" sid-d2   idle "$repo"
    _peer_tr sid-q  "$ask_txt"
    _peer_tr sid-d2 "$done_txt"
    _ask_case peers-ask-question-mark "[⚙1] ?1 ○1" ""
    # The "?" chip is drawn in reverse video
    if _has "$raw" $'\e[7m'; then _rl_pass peers-ask-reverse-video
    else _rl_fail peers-ask-reverse-video "no SGR 7 on the ? chip"; fi

    rm -rf "$reg" "$proj"; mkdir -p "$reg"
    _peer_entry self "$$" self-sid busy "$repo"
    _peer_entry q    "$$" sid-q    idle "$repo"
    _peer_tr sid-q "$ask_tool"
    _ask_case peers-ask-tool "?1" "○"

    # This session never counts itself as "?" (you are looking at it): ○ instead,
    # and the idle count it joined is bracketed so the idle session stands out
    rm -rf "$reg" "$proj"; mkdir -p "$reg"
    _peer_entry self "$$" self-sid idle "$repo"
    _peer_entry b    "$$" sid-b    busy "$repo"
    _peer_tr self-sid "$ask_txt"
    _ask_case peers-ask-not-self "⚙1 [○1]" "?"   # and bracketed: this session is idle

    # No transcript, or a session id that tries to walk out of the folder -> ○
    rm -rf "$reg" "$proj"; mkdir -p "$reg"
    _peer_entry self "$$" self-sid busy "$repo"
    _peer_entry n    "$$" sid-none idle "$repo"
    _peer_entry e    "$$" '../evil' idle "$repo"
    mkdir -p "$proj"; printf '%s\n' "$ask_txt" > "$SCRATCH/evil.jsonl"
    _ask_case peers-ask-missing-or-unsafe "[⚙1] ○2" "?"

    # Answered and cancelled question prompts both get a tool_result, so they
    # no longer count as "?" (cancelled: followed by a tool call, no text).
    local q_use q_res
    q_use='{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu1","name":"AskUserQuestion","input":{}}]}}'
    q_res='{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"tu1","content":"x"}]}}'
    rm -rf "$reg" "$proj"; mkdir -p "$reg"
    _peer_entry self "$$" self-sid busy "$repo"
    _peer_entry a    "$$" sid-ans  idle "$repo"
    _peer_entry c    "$$" sid-can  idle "$repo"
    _peer_tr sid-ans "$q_use"$'\n'"$q_res"$'\n''{"type":"assistant","message":{"content":[{"type":"text","text":"Got it, proceeding."}]}}'
    _peer_tr sid-can "$q_use"$'\n'"$q_res"$'\n''{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu2","name":"Bash","input":{}}]}}'
    _ask_case peers-ask-answered-or-cancelled "[⚙1] ○2" "?"

    # A malformed registry file must not hide the valid sessions after it, and
    # a pid of 0 (kill -0 0 probes our own process group) never counts.
    rm -rf "$reg" "$proj"; mkdir -p "$reg"
    printf '{"pid":' > "$reg/0000-broken.json"
    _peer_entry self "$$" self-sid busy "$repo"
    _peer_entry z    0    sid-zero busy "$repo"
    _peer_entry i    "$$" sid-i    idle "$repo"
    _ask_case peers-malformed-and-pid0 "[⚙1] ○1" "⚙2"

    # A peer whose registry cwd reaches the repo through a symlink still counts.
    rm -rf "$reg" "$proj"; mkdir -p "$reg"
    ln -s "$repo" "$SCRATCH/peer-repo-link"
    _peer_entry self "$$" self-sid busy "$repo"
    _peer_entry l    "$$" sid-l    busy "$SCRATCH/peer-repo-link/sub"
    _ask_case peers-symlinked-cwd "[⚙2]" ""
}

# ── GPT context-hold tests ─────────────────────────────────────────────────
# A GPT session observed sending 21%, then one all-zero context_window (four
# current_usage counters and both totals 0, used 0 / remaining 100), then 21%
# again. That exact shape re-shows the last proven snapshot in dim gray; every
# reset or mismatch must fall back to the native value and drop the snapshot.
# A positive frame is only stored when the transcript holds the matching
# assistant usage after its last compact boundary, so most cases append that
# entry (_ctx_asst) before rendering the frame.
_ctx_counters() {  # shape -> "input cache_creation cache_read"
    case "$1" in
        pos21) printf '1000 0 180000' ;;
        pos21b) printf '900 0 181000' ;;
        pos22) printf '1500 0 190000' ;;
        pos10) printf '2000 0 85000' ;;
        low0)  printf '1 0 0' ;;
    esac
}
_ctx_json() {  # sid model transcript window shape
    local cw i c r p=${5#pos}
    p=${p%b}
    read -r i c r <<<"$(_ctx_counters "$5")"
    case "$5" in
        pos21|pos21b|pos22|pos10)
            cw="\"used_percentage\":$p,\"remaining_percentage\":$((100 - p)),\"total_input_tokens\":$((i + c + r)),\"total_output_tokens\":50,\"current_usage\":{\"input_tokens\":$i,\"output_tokens\":50,\"cache_creation_input_tokens\":$c,\"cache_read_input_tokens\":$r}" ;;
        low0)  cw='"used_percentage":0,"remaining_percentage":100,"total_input_tokens":1,"total_output_tokens":1,"current_usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}' ;;
        zero)  cw='"used_percentage":0,"remaining_percentage":100,"total_input_tokens":0,"total_output_tokens":0,"current_usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}' ;;
        zero-totals) cw='"used_percentage":0,"remaining_percentage":100,"total_input_tokens":5,"total_output_tokens":0,"current_usage":{"input_tokens":0,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}' ;;
        zero-partial) cw='"used_percentage":0,"remaining_percentage":100,"total_input_tokens":0,"total_output_tokens":0,"current_usage":{"input_tokens":0,"output_tokens":0,"cache_read_input_tokens":0}' ;;
        null)  cw='"used_percentage":null,"remaining_percentage":null,"total_input_tokens":0,"total_output_tokens":0,"current_usage":null' ;;
    esac
    printf '{"model":{"display_name":"GPT 6.1 Sol","id":"%s"},"cwd":"/home/test/ctx",' "$2"
    printf '"session_id":"%s","transcript_path":"%s"' "$1" "$3"
    if [ "$5" = "absent" ]; then printf '}'
    else printf ',"context_window":{"context_window_size":%s,%s}}' "$4" "$cw"; fi
}
_ctx_asst() {  # transcript model shape: append that response's assistant entry
    local i c r
    read -r i c r <<<"$(_ctx_counters "$3")"
    printf '{"type":"assistant","uuid":"a-%s","message":{"model":"%s","usage":{"input_tokens":%s,"cache_creation_input_tokens":%s,"cache_read_input_tokens":%s,"output_tokens":50}}}\n' \
        "$3" "$2" "$i" "$c" "$r" >>"$1"
}
_ctx_boundary() {  # transcript uuid
    printf '{"type":"system","subtype":"compact_boundary","uuid":"%s","compactMetadata":{"trigger":"manual","preTokens":181000}}\n' "$2" >>"$1"
}

context_hold_tests() {
    printf '\n'
    printf 'GPT context-hold tests\n'
    printf '%s\n' "------------------------------------------------------------"

    local dim=$'\033[38;2;80;80;80m' sage=$'\033[38;2;150;210;150m'
    local d="$SCRATCH/ctxhold" snap tr out err raw l2 w lines mode state uid i
    local U1=11111111-2222-4333-8444-555555555555 U2=99999999-8888-4777-8666-555555555555
    mkdir -p "$d"
    out="$d/out"; err="$d/err"

    _ctx_run() {  # <json> [env...]: one render with the case's snapshot seam
        local json="$1"; shift
        ( cd "$SCRATCH" && printf '%s' "$json" \
            | env CC_STATUSLINE_CTX_CACHE="$snap" CC_STATUSLINE_RL_CACHE="$d/rl.cache" "$@" \
                  bash "$STATUSLINE" ) >"$out" 2>"$err"
    }
    # _ctx_expect <name> <pct> <stale 0|1> [snapshot: present|absent|-]
    # Checks exit shape, stderr, both widths, the percentage, and whether it is
    # drawn in the dim stale gray (percentage and, when filled, the bar).
    _ctx_expect() {
        local nm="$1" pct="$2" stale="$3" want_snap="${4:--}" reason="" ln
        raw=$(sed -n '2p' "$out"); l2=$(printf '%s' "$raw" | _strip_ansi)
        lines=$(wc -l <"$out" | tr -d ' ')
        if [ -s "$err" ]; then reason="non-empty stderr: $(head -1 "$err")"
        elif [ "$lines" -ne 2 ]; then reason="expected 2 lines, got $lines"
        fi
        if [ -z "$reason" ]; then
            for ln in 1 2; do
                w=$(sed -n "${ln}p" "$out" | vis_cols)
                [ "$w" -le "$((SAFE_WIDTH + WIDTH_SLOP))" ] || reason="line $ln is $w cols"
            done
        fi
        if [ -z "$reason" ]; then
            if ! _has "$l2" "${pct}%"; then reason="expected ${pct}% on line 2: $l2"
            elif [ "$stale" = "1" ] && ! _has "$raw" "${dim}${pct}%"; then reason="expected dim ${pct}%"
            elif [ "$stale" = "0" ] && _has "$raw" "${dim}${pct}%"; then reason="unexpected dim ${pct}%"
            elif [ "$stale" = "1" ] && [ "$pct" != "0" ] && _has "$l2" "of " \
                && _has "$raw" "▰" && ! _has "$raw" "${dim}▰"; then reason="stale bar not dim"
            elif [ "$stale" = "0" ] && _has "$raw" "${dim}▰"; then reason="fresh bar drawn dim"
            fi
        fi
        if [ -z "$reason" ]; then
            case "$want_snap" in
                present) [ -f "$snap" ] || reason="snapshot missing" ;;
                absent)  [ ! -e "$snap" ] || reason="snapshot not removed: $(head -c 200 "$snap")" ;;
            esac
        fi
        if [ -z "$reason" ]; then _rl_pass "$nm"; else _rl_fail "$nm" "$reason"; fi
    }
    # Fresh case: a one-line transcript and an empty snapshot path.
    _ctx_case() {
        snap="$d/$1.snap"; tr="$d/$1.jsonl"
        rm -f "$snap"
        printf '{"type":"user","message":{"content":"hi"}}\n' >"$tr"
    }
    # Append the response's transcript entry, then render its frame.
    _ctx_pos() {  # sid model window shape [env...]
        local sid="$1" m="$2" win="$3" shape="$4"; shift 4
        _ctx_asst "$tr" "$m" "$shape"
        _ctx_run "$(_ctx_json "$sid" "$m" "$tr" "$win" "$shape")" "$@"
    }
    local M=gpt-6.1-sol S=ctx-sess-1 W=872000

    # 1. The captured sequence: 21 -> all-zero -> 21. The zero render holds 21
    #    in dim gray and leaves the snapshot alone; the next 21 is fresh again.
    _ctx_case capture
    _ctx_pos $S $M $W pos21; _ctx_expect ctx-capture-first 21 0 present
    if [ "$(cut -d'|' -f1-8 "$snap")" = "v3|$S|$M|$M|$W|21|1000.0.180000|none" ] && [ "$(cut -d'|' -f13- "$snap")" = "$tr" ]; then
        _rl_pass ctx-capture-snapshot-keys
    else _rl_fail ctx-capture-snapshot-keys "unexpected snapshot: $(cat "$snap")"; fi
    mode=$(ls -l "$snap" | cut -c1-10)
    if [ "$mode" = "-rw-------" ]; then _rl_pass ctx-capture-snapshot-mode
    else _rl_fail ctx-capture-snapshot-mode "snapshot mode $mode"; fi
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-capture-zero-held 21 1 present
    if _has "$l2" "of 872k"; then _rl_pass ctx-capture-zero-capacity
    else _rl_fail ctx-capture-zero-capacity "capacity not native: $l2"; fi
    _ctx_run "$(_ctx_json $S $M "$tr" $W pos21)"; _ctx_expect ctx-capture-recovered 21 0 present
    if _has "$raw" "${sage}21%"; then _rl_pass ctx-capture-recovered-color
    else _rl_fail ctx-capture-recovered-color "21% not in its normal color"; fi
    # Ordinary appended lines, including a parseable message that merely
    # mentions the marker text, keep the hold.
    printf '{"type":"user","message":{"content":"what is \\"subtype\\":\\"compact_boundary\\"?"}}\n' >>"$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-hold-after-append 21 1 present
    # Routed GPT spellings: the transcript records the served id, stdin may
    # carry the routed or [1m] form; either matches the provenance check.
    for i in 'gpt-6.1-sol[1m]' claude-ocx-native--gpt-6.1-sol clodex:openai-oauth:gpt-6.1-sol; do
        _ctx_case routed
        _ctx_asst "$tr" $M pos21
        _ctx_run "$(_ctx_json $S "$i" "$tr" $W pos21)"
        _ctx_run "$(_ctx_json $S "$i" "$tr" $W zero)"; _ctx_expect "ctx-hold-id-$i" 21 1 present
    done

    # 2. Phone layout (ctx fallback and with rate limits) and viewports that
    #    shed ctx entirely: the held value is dim wherever it is shown.
    _ctx_case phone
    _ctx_pos $S $M $W pos21
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)" COLUMNS=46; _ctx_expect ctx-phone-held 21 1 present
    if _has "$l2" "ctx 21%"; then _rl_pass ctx-phone-ctx-seg
    else _rl_fail ctx-phone-ctx-seg "phone ctx segment missing: $l2"; fi
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)" STATUSLINE_LAYOUT=phone STATUSLINE_GPT_LIMITS=1 \
        CC_STATUSLINE_GPT_CACHE="$d/gpt.cache" STATUSLINE_GPT_FETCH=0 COLUMNS=60
    _ctx_expect ctx-phone-gpt-limits 21 1 present
    for w in 30 24 20; do
        _ctx_run "$(_ctx_json $S $M "$tr" $W zero)" COLUMNS=$w
        lines=$(wc -l <"$out" | tr -d ' '); l2=$(sed -n 2p "$out" | _strip_ansi)
        raw=$(sed -n 2p "$out")
        if [ -s "$err" ] || [ "$lines" -ne 2 ] \
            || [ "$(sed -n 1p "$out" | vis_cols)" -gt "$((w - 1))" ] \
            || [ "$(sed -n 2p "$out" | vis_cols)" -gt "$((w - 1))" ]; then
            _rl_fail "ctx-phone-cols-$w" "bad render at COLUMNS=$w: $l2"
        elif _has "$l2" "21%" && ! _has "$raw" "${dim}21%"; then
            _rl_fail "ctx-phone-cols-$w" "held value shown but not dim: $l2"
        else _rl_pass "ctx-phone-cols-$w"; fi
    done

    # 3. Genuine decreases, including a real 0% with positive input, are shown
    #    natively and become the new snapshot.
    _ctx_case decrease
    _ctx_pos $S $M $W pos21
    _ctx_pos $S $M $W pos10; _ctx_expect ctx-decrease-shown 10 0 present
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-decrease-held 10 1 present
    _ctx_pos $S $M $W low0; _ctx_expect ctx-real-zero-shown 0 0 present
    if [ "$(cut -d'|' -f6 "$snap")" = "0" ]; then _rl_pass ctx-real-zero-snapshot
    else _rl_fail ctx-real-zero-snapshot "snapshot not updated to 0: $(cat "$snap")"; fi
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-real-zero-held 0 1 present
    # A new value the transcript does not show yet cannot be proven, and the
    # older snapshot is no longer the last value: dropped, not held.
    _ctx_case unproven
    _ctx_pos $S $M $W pos21
    _ctx_run "$(_ctx_json $S $M "$tr" $W pos10)"; _ctx_expect ctx-unproven-shown 10 0 absent
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-unproven-zero 0 0 absent
    # Provenance needs the matching model too.
    _ctx_case wrong-model-entry
    _ctx_asst "$tr" gpt-5.6-sol pos21
    _ctx_asst "$tr" $M pos10
    _ctx_run "$(_ctx_json $S $M "$tr" $W pos21)"; _ctx_expect ctx-provenance-model 21 0 absent

    # 4. Fresh session (no snapshot): all-zero renders natively, writes nothing.
    _ctx_case fresh
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-fresh-native 0 0 absent

    # 5. Null and absent usage reset the snapshot.
    for i in null absent; do
        _ctx_case "reset-$i"
        _ctx_pos $S $M $W pos21
        _ctx_run "$(_ctx_json $S $M "$tr" $W "$i")"; _ctx_expect "ctx-reset-$i" 0 0 absent
        _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect "ctx-reset-$i-then-zero" 0 0 absent
    done
    # Near-miss zero shapes are not the observed payload: native, and reset.
    for i in zero-totals zero-partial; do
        _ctx_case "$i"
        _ctx_pos $S $M $W pos21
        _ctx_run "$(_ctx_json $S $M "$tr" $W "$i")"; _ctx_expect "ctx-$i-native" 0 0 absent
    done

    # 6. Key mismatches invalidate: effective model, raw model (a /model switch
    #    the transcript has not caught up with), provider, transcript path,
    #    window, session id. W1 -> W2 zero -> W1 zero must not resurrect W1.
    _ctx_case key-model
    _ctx_pos $S $M $W pos21
    _ctx_asst "$tr" gpt-5.6-sol pos21
    _ctx_run "$(_ctx_json $S gpt-5.6-sol "$tr" $W zero)"; _ctx_expect ctx-key-model 0 0 absent
    _ctx_case key-raw-model
    _ctx_pos $S $M $W pos21
    _ctx_run "$(_ctx_json $S gpt-5.6-sol "$tr" $W zero)"; _ctx_expect ctx-key-raw-model 0 0 absent
    _ctx_case key-provider
    _ctx_pos $S $M $W pos21
    _ctx_asst "$tr" claude-opus-4-8 pos10
    _ctx_run "$(_ctx_json $S claude-opus-4-8 "$tr" $W zero)"; _ctx_expect ctx-key-provider 0 0 absent
    _ctx_case key-path
    _ctx_pos $S $M $W pos21
    cp "$tr" "$d/key-path-other.jsonl"
    _ctx_run "$(_ctx_json $S $M "$d/key-path-other.jsonl" $W zero)"; _ctx_expect ctx-key-path 0 0 absent
    _ctx_case key-window
    _ctx_pos $S $M $W pos21
    _ctx_run "$(_ctx_json $S $M "$tr" 1000000 zero)"; _ctx_expect ctx-key-window 0 0 absent
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-key-window-back 0 0 absent
    # A window that is not a bounded positive integer is defaulted later, so it
    # must not match a warm snapshot that happens to hold the default.
    for i in 200000.5 1e16 '"200000"' 0 -5; do
        _ctx_case "bad-window"
        _ctx_pos $S $M 200000 pos21
        _ctx_run "$(_ctx_json $S $M "$tr" "$i" zero)"; _ctx_expect "ctx-bad-window-$i" 0 0 absent
    done
    # Malformed positive frames (unchanged percentage, so no re-proof would
    # otherwise run) render natively and invalidate the snapshot.
    local bad n=0
    for bad in '"input_tokens":1000,"cache_creation_input_tokens":0,"cache_read_input_tokens":-5' \
               '"input_tokens":1000,"cache_read_input_tokens":180000' \
               '"input_tokens":1000.5,"cache_creation_input_tokens":0,"cache_read_input_tokens":180000' \
               '"input_tokens":"1000","cache_creation_input_tokens":0,"cache_read_input_tokens":180000' \
               '"input_tokens":1e16,"cache_creation_input_tokens":0,"cache_read_input_tokens":180000'; do
        n=$((n + 1)); _ctx_case malformed-positive
        _ctx_pos $S $M $W pos21
        _ctx_run "{\"model\":{\"display_name\":\"GPT 6.1 Sol\",\"id\":\"$M\"},\"cwd\":\"/home/test/ctx\",\"session_id\":\"$S\",\"transcript_path\":\"$tr\",\"context_window\":{\"context_window_size\":$W,\"used_percentage\":21,\"remaining_percentage\":79,\"total_input_tokens\":181000,\"total_output_tokens\":50,\"current_usage\":{$bad,\"output_tokens\":50}}}"
        _ctx_expect "ctx-malformed-positive-$n" 21 0 absent
        _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect "ctx-malformed-positive-$n-then-zero" 0 0 absent
    done
    _ctx_case key-session
    _ctx_pos $S $M $W pos21
    _ctx_run "$(_ctx_json ctx-sess-2 $M "$tr" $W zero)"; _ctx_expect ctx-key-session 0 0 absent
    # Default (non-seam) path: one file per session id in the runtime dir, so a
    # new session id (as after /clear) never sees the old snapshot.
    state="$d/state"; mkdir -p "$state"; uid=$(id -u)
    _ctx_case key-session-default
    _ctx_pos $S $M $W pos21 XDG_RUNTIME_DIR="$state" CC_STATUSLINE_CTX_CACHE=
    if [ -f "$state/cc-statusline-$uid/ctx-last-$S" ]; then _rl_pass ctx-default-path
    else _rl_fail ctx-default-path "no snapshot under the runtime dir"; fi
    _ctx_run "$(_ctx_json ctx-sess-2 $M "$tr" $W zero)" XDG_RUNTIME_DIR="$state" CC_STATUSLINE_CTX_CACHE=
    _ctx_expect ctx-default-new-session 0 0
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)" XDG_RUNTIME_DIR="$state" CC_STATUSLINE_CTX_CACHE=
    _ctx_expect ctx-default-same-session 21 1

    # 7. Compact epochs. A boundary with a new uuid after the snapshot cancels
    #    the hold; a value proven after a boundary is tagged with it and holds.
    _ctx_case compact
    _ctx_pos $S $M $W pos21
    _ctx_boundary "$tr" $U2
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-compact-boundary 0 0 absent
    _ctx_case compact-then-new
    _ctx_boundary "$tr" $U1
    _ctx_asst "$tr" $M pos21
    _ctx_boundary "$tr" $U2
    _ctx_pos $S $M $W pos10; _ctx_expect ctx-post-compact-seed 10 0 present
    if [ "$(cut -d'|' -f8 "$snap")" = "$U2" ]; then _rl_pass ctx-post-compact-epoch
    else _rl_fail ctx-post-compact-epoch "epoch not the latest uuid: $(cat "$snap")"; fi
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-post-compact-held 10 1 present
    # The race: a pre-compaction frame (its usage is before the boundary)
    # arrives after the boundary was written. Cold: never seeded.
    _ctx_case race-cold
    _ctx_asst "$tr" $M pos21
    _ctx_boundary "$tr" $U2
    _ctx_run "$(_ctx_json $S $M "$tr" $W pos21)"; _ctx_expect ctx-race-cold-seed 21 0 absent
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-race-cold-zero 0 0 absent
    # Warm, new value: the old-epoch snapshot is invalidated, not refreshed.
    _ctx_case race-warm
    _ctx_pos $S $M $W pos21
    _ctx_asst "$tr" $M pos22
    _ctx_boundary "$tr" $U2
    _ctx_run "$(_ctx_json $S $M "$tr" $W pos22)"; _ctx_expect ctx-race-warm-seed 22 0 absent
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-race-warm-zero 0 0 absent
    # Warm, same value (no re-proof): the hold pass sees the new epoch.
    _ctx_case race-warm-same
    _ctx_pos $S $M $W pos21
    _ctx_boundary "$tr" $U2
    _ctx_run "$(_ctx_json $S $M "$tr" $W pos21)"; _ctx_expect ctx-race-same-seed 21 0 present
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-race-same-zero 0 0 absent
    # A genuine post-compaction reading at the SAME percentage (new counters,
    # matching entry after the boundary) re-proves and moves to the new epoch.
    _ctx_case post-compact-same-pct
    _ctx_pos $S $M $W pos21
    _ctx_boundary "$tr" $U2
    _ctx_pos $S $M $W pos21b; _ctx_expect ctx-post-compact-same-pct 21 0 present
    if [ "$(cut -d'|' -f7-8 "$snap")" = "900.0.181000|$U2" ]; then _rl_pass ctx-post-compact-same-pct-epoch
    else _rl_fail ctx-post-compact-same-pct-epoch "not re-proven: $(cat "$snap")"; fi
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-post-compact-same-pct-held 21 1 present
    # Unknown evidence: malformed boundary candidate, boundary uuid not a
    # uuid, unterminated tail. Each declines the hold.
    _ctx_case compact-malformed
    _ctx_pos $S $M $W pos21
    printf '{"type":"system","subtype":"compact_boundary",\n' >>"$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-compact-malformed 0 0 absent
    _ctx_case compact-bad-uuid
    _ctx_pos $S $M $W pos21
    _ctx_boundary "$tr" not-a-uuid
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-compact-bad-uuid 0 0 absent
    _ctx_case unterminated
    _ctx_pos $S $M $W pos21
    printf '{"type":"system","subtype":"compact_bou' >>"$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-unterminated-tail 0 0 absent
    _ctx_case unterminated-write
    _ctx_asst "$tr" $M pos21
    printf '{"type":"user"' >>"$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W pos21)"; _ctx_expect ctx-no-snapshot-mid-line 21 0 absent

    # 8. File replacement, truncation, an edit inside the checked 4 KB tail,
    #    removal, and a directory in its place all cancel the hold.
    _ctx_case replaced
    _ctx_pos $S $M $W pos21
    cp "$tr" "$tr.new" && mv -f "$tr.new" "$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-replaced 0 0 absent
    _ctx_case truncated
    _ctx_pos $S $M $W pos21
    head -1 "$tr" >"$d/trunc.tmp" && cat "$d/trunc.tmp" >"$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-truncated 0 0 absent
    _ctx_case rewritten
    _ctx_pos $S $M $W pos21
    perl -pi -e 's/"hi"/"HI"/' "$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-rewritten 0 0 absent
    _ctx_case removed
    _ctx_pos $S $M $W pos21
    rm -f "$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-transcript-missing 0 0 absent
    _ctx_case directory
    _ctx_pos $S $M $W pos21
    rm -f "$tr"; mkdir "$tr"
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-transcript-directory 0 0 absent
    rmdir "$tr"

    # 9. Corrupt or out-of-range snapshots never hold and are removed.
    for i in garbage pct pct-08 pct-009 bad-md5 old-version bad-epoch bad-usage; do
        _ctx_case "corrupt-$i"
        _ctx_pos $S $M $W pos21
        case "$i" in
            garbage) printf 'not a snapshot\n' >"$snap" ;;
            pct) perl -pi -e 's/^((?:[^|]*\|){5})21\|/${1}999|/' "$snap" ;;
            pct-08) perl -pi -e 's/^((?:[^|]*\|){5})21\|/${1}08|/' "$snap" ;;
            pct-009) perl -pi -e 's/^((?:[^|]*\|){5})21\|/${1}009|/' "$snap" ;;
            bad-usage) perl -pi -e 's/\|1000\.0\.180000\|/|1000.0|/' "$snap" ;;
            bad-md5) perl -pi -e 's/\|[0-9a-f]{32}\|/|zzzz|/' "$snap" ;;
            old-version) perl -pi -e 's/^v3\|/v2|/' "$snap" ;;
            bad-epoch) perl -pi -e 's/\|none\|/|..|/' "$snap" ;;
        esac
        _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect "ctx-corrupt-$i" 0 0 absent
    done

    # 10. Claude renders never write a snapshot, never hold, and drop a GPT one
    #     (a /model switch away from GPT and back must not resurrect it).
    _ctx_case claude
    _ctx_pos $S claude-opus-4-8 $W pos21; _ctx_expect ctx-claude-no-write 21 0 absent
    _ctx_pos $S $M $W pos21
    _ctx_pos $S claude-opus-4-8 $W pos10; _ctx_expect ctx-claude-drops-gpt 10 0 absent
    _ctx_asst "$tr" $M pos10
    _ctx_run "$(_ctx_json $S $M "$tr" $W zero)"; _ctx_expect ctx-claude-then-gpt-zero 0 0 absent
}

if [ ! -d "$FIXTURES" ]; then
    printf 'error: fixtures dir not found: %s\n' "$FIXTURES" >&2
    exit 2
fi

printf 'cc-statusline test harness (SAFE_WIDTH=%s)\n' "$SAFE_WIDTH"
printf '%s\n' "------------------------------------------------------------"

shopt -s nullglob
for f in "$FIXTURES"/*.json; do
    run_one "$f"
done

rate_limit_cache_tests
gpt_rate_limit_tests
phone_layout_tests
phone_truncation_tests
phone_gap_tests
github_status_tests
session_name_tests
peer_tests
env_hardening_tests
effort_tests
update_check_tests
cache_timer_tests
context_hold_tests

printf '%s\n' "------------------------------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
