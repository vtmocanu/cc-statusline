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
_strip_ansi() { perl -pe 's/\e\[[0-9;]*m//g' 2>/dev/null; }
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

    # 6b. The layout FILE flips a wide viewport to phone (the path that works
    #     when the session is being viewed from a phone, since COLUMNS reports
    #     the host terminal). Env var still wins over the file.
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

    name="phone-layout-file-env-wins"; out="$SCRATCH/ph8.out"; err="$SCRATCH/ph8.err"
    _phone_run "$out" "$err" COLUMNS=200 XDG_CONFIG_HOME="$SCRATCH/xdg" \
        STATUSLINE_LAYOUT=wide CC_STATUSLINE_RL_CACHE="$SCRATCH/ph8.cache"
    l2=$(_rl_l2 "$out")
    if [ -s "$err" ]; then _phone_fail "$name" "non-empty stderr: $(head -1 "$err")"
    elif ! _has "$l2" "of 1000k"; then
        _phone_fail "$name" "env var did not override the layout file: $l2"
    else _phone_pass "$name"; fi

    # 6. Phone layout with no rate limits at all -> context fallback, not an
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

printf '%s\n' "------------------------------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
