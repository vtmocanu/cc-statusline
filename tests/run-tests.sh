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

# Isolate the service-status cache and fetcher from the host. The
# statusline reads CC_STATUSLINE_SVC_CACHE / CC_STATUSLINE_SVC_FETCH env
# vars (added in v2.1.x) to avoid touching /tmp/claude-service-status or
# spawning a real curl in the background during tests.
export CC_STATUSLINE_SVC_CACHE="$SCRATCH/svc-cache"
export CC_STATUSLINE_SVC_FETCH="$SCRATCH/no-such-fetcher.sh"

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

printf '%s\n' "------------------------------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
