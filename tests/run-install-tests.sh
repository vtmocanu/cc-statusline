#!/usr/bin/env bash
# Keep the archive producer separate from tar: tar may close a valid stream
# before Git finishes its trailing padding, yielding SIGPIPE under pipefail.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-install-test.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/bin" "$SCRATCH/tree" "$SCRATCH/extracted"
for file in statusline.sh claude-status-fetch.sh claude-usage-fetch.sh codex-usage-fetch.sh gpt-credits-fetch.sh cc-statusline-update-fetch.sh; do
    printf 'fixture\n' > "$SCRATCH/tree/$file"
done
tar -c -f "$SCRATCH/source.tar" -C "$SCRATCH/tree" .
cat > "$SCRATCH/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = -C ] && shift 2
case "${1:-}" in
    rev-parse) printf 'true\n' ;;
    describe) printf 'fixture\n' ;;
    archive)
        [ "${INSTALL_TEST_FAIL:-0}" = 0 ] || exit 17
        output=""
        for arg in "$@"; do
            case "$arg" in --output=*) output="${arg#--output=}" ;; esac
        done
        if [ -n "$output" ]; then
            cat "$INSTALL_TEST_ARCHIVE" > "$output"
            dd if=/dev/zero bs=1048576 count=1 >> "$output" 2>/dev/null
        else
            cat "$INSTALL_TEST_ARCHIVE"
            dd if=/dev/zero bs=1048576 count=1 2>/dev/null
        fi
        ;;
    *) exit 99 ;;
esac
GIT
chmod +x "$SCRATCH/bin/git"
export PATH="$SCRATCH/bin:$PATH" INSTALL_TEST_ARCHIVE="$SCRATCH/source.tar"
# First prove the fixture triggers the original streaming failure while tar
# succeeds. A producer failure unrelated to early pipe closure cannot pass.
set +e
git archive HEAD | tar -x -f - -C "$SCRATCH/extracted"
pipe_status=("${PIPESTATUS[@]}")
set -e
[ "${pipe_status[0]}" = 141 ] && [ "${pipe_status[1]}" = 0 ]
printf '  PASS  valid archive with trailing padding reproduces producer SIGPIPE\n'
CC_STATUSLINE_PREFIX="$SCRATCH/install" bash "$REPO_DIR/install.sh" > "$SCRATCH/out" 2> "$SCRATCH/err"
[ ! -s "$SCRATCH/err" ]
cmp "$SCRATCH/tree/statusline.sh" "$SCRATCH/install/statusline.sh"
printf '  PASS  file staging installs the same padded archive\n'
printf 'sentinel\n' > "$SCRATCH/install/statusline.sh"
if INSTALL_TEST_FAIL=1 CC_STATUSLINE_PREFIX="$SCRATCH/install" bash "$REPO_DIR/install.sh" --version vfixture > "$SCRATCH/out" 2> "$SCRATCH/err"; then
    printf '  FAIL  archive producer failure was accepted\n' >&2
    exit 1
fi
[ "$(cat "$SCRATCH/install/statusline.sh")" = sentinel ]
[ "$(cat "$SCRATCH/err")" = 'error: git archive failed for ref vfixture' ]
printf '  PASS  archive failure remains fatal, names the ref and preserves install\n'
printf '\n3 passed, 0 failed\n'
