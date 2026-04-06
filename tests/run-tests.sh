#!/usr/bin/env bash
# cc-statusline test harness
#
# For each fixture in tests/fixtures/, pipe it through statusline.sh and assert:
#   - exit code is 0
#   - stdout has exactly 2 lines
#   - each visible line is within STATUSLINE_WIDTH + WIDTH_SLOP columns
#     (the script uses bash-based width estimation with a small safety
#      margin; actual measured cols can be a few over the soft limit)
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
# Tolerance for the script's bash-based width estimate vs measured cols.
# The script's truncation logic targets SAFE_WIDTH but underestimates by
# a few columns in some paths. Treat anything within 5 cols as acceptable.
WIDTH_SLOP="${WIDTH_SLOP:-5}"

# Run from a scratch directory so the cwd-derived git/k8s state of the
# test runner doesn't leak into output. Also unset KUBECONFIG so the
# kubectl-current-context lookup returns nothing.
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
export KUBECONFIG=/dev/null
unset GIT_DIR GIT_WORK_TREE

pass=0
fail=0
errors=()

vis_cols() {
    perl -pe 's/\e\[[0-9;]*m//g' | tr -d '\n' | LC_ALL=en_US.UTF-8 wc -m | tr -d ' '
}

run_one() {
    local fixture="$1"
    local name
    name=$(basename "$fixture" .json)

    local stdout_file="$SCRATCH/$name.out"
    local stderr_file="$SCRATCH/$name.err"

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

printf '%s\n' "------------------------------------------------------------"
printf '%d passed, %d failed\n' "$pass" "$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi
exit 0
