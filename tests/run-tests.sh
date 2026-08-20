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
# Same isolation for the per-account usage fetcher: a non-executable path so a
# render can never hit /api/oauth/usage with real credentials during tests.
export CC_STATUSLINE_RL_FETCH="$SCRATCH/no-such-usage-fetcher.sh"

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
phone_layout_tests
phone_truncation_tests
phone_gap_tests
github_status_tests
session_name_tests
env_hardening_tests

printf '%s\n' "------------------------------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
