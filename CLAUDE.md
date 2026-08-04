# CLAUDE.md

This file gives Claude Code (and any other agentic coding tool) the context it needs to work productively on **cc-statusline** without re-discovering the gotchas the maintainer has already hit.

The repo lives on GitHub: **github.com/vtmocanu/cc-statusline**. Use the `gh` CLI for all hosting operations (releases, CI runs, repo settings). It previously lived on Codeberg (codeberg.org/vtmocanu/cc-statusline, now archived as a pointer); historical CHANGELOG entries up to v2.2.1 reference Codeberg CI and Forgejo specifics.

## What this repo is

A two-line ANSI statusline for [Claude Code](https://claude.com/claude-code). It's a small bash-based tool, but the codebase has accumulated real lessons about portable shell, ANSI rendering, terminal width estimation, and Claude Code's undocumented statusline renderer behaviors. **Read `KNOWN_ISSUES.md` and the comments in `statusline.sh` before changing any width-related logic.**

The primary maintainer's machine runs the brew-installed copy day-to-day (`statusLine.command` is `STATUSLINE_WIDTH=130 cc-statusline`). For development, the brew wrapper's dev override points at the working tree. **The dev-dir file lives under `$XDG_CONFIG_HOME`, not a hardcoded `~/.config`** — the wrapper resolves it as `"${XDG_CONFIG_HOME:-$HOME/.config}/cc-statusline/dev-dir"`. Always check where `XDG_CONFIG_HOME` actually points before writing it (on the maintainer's machine it is remapped to `~/stuff/gitrepos/wxs/mackup/.config`, so writing to a literal `~/.config/cc-statusline/dev-dir` is a silent no-op — the wrapper never reads it):

```bash
D="${XDG_CONFIG_HOME:-$HOME/.config}/cc-statusline"
mkdir -p "$D"
echo ~/stuff/gitrepos/gh/vtmocanu/cc-statusline > "$D/dev-dir"   # next render uses the working tree
rm "$D/dev-dir"                                                   # return to the brewed copy
```

Edits are picked up on the next render (no restart). **Remove dev-dir when a dev session ends**, otherwise the statusline silently tracks unreleased code (and, when `XDG_CONFIG_HOME` points into a synced repo like mackup, leaves a stray untracked file there). Public users go through `brew install vtmocanu/tap/cc-statusline` (formula auto-published on tag push, see release.yml) or `install.sh`, which extracts a tag via `git archive` into `~/.local/share/cc-statusline/`. The brew wrapper honors a dev override (the `$XDG_CONFIG_HOME/cc-statusline/dev-dir` file, or the `CC_STATUSLINE_DEV_DIR` env var which takes precedence) pointing at a working tree.

Live blog post with design notes: https://hai.wxs.ro/ai-stuff/claude-statusline/

## Repo layout

```
cc-statusline/
├── statusline.sh                     Main script (called by Claude Code, reads JSON from stdin, outputs 2 lines of ANSI)
├── claude-status-fetch.sh            Background helper, polls status.claude.com every 60s, writes the per-user service-status cache
├── claude-usage-fetch.sh             Background helper, fetches /api/oauth/usage with the session's own credential, writes the per-account rate-limits cache (authoritative 5-field line)
├── hooks/
│   └── session-topic-capture.sh      Optional UserPromptSubmit hook, calls Claude Haiku to label sessions
├── install.sh                        Installer for public users (--version vX.Y.Z, --uninstall, --help)
├── Formula.rb.tmpl                   Homebrew formula template (@@URL@@/@@SHA256@@ placeholders); rendered and pushed to vtmocanu/homebrew-tap by release.yml on each v* tag
├── examples/
│   └── statusline-color-overrides.json  Template for ~/.claude/statusline-color-overrides.json
├── tests/
│   ├── run-tests.sh                  Test harness (perl-based ANSI-aware width measurement)
│   └── fixtures/*.json               5 mock JSON inputs (happy path, empty, no rate limits, near-full context, narrow width)
├── Taskfile.yml                      Validation tasks (shell:* from vtmocanu/task, test, test-c-locale, ci); used locally and by CI
├── .github/workflows/ci.yml          GitHub Actions CI: runs the Taskfile tasks on push/PR
├── .github/workflows/release.yml     On v* tags: renders the formula and pushes it to the tap (HOMEBREW_TAP_TOKEN secret); does NOT create the GitHub Release, that stays manual
├── images/screenshot.png             Hero image used by README
├── README.md                         Public-facing docs
├── CHANGELOG.md                      Keep-a-Changelog format, one section per tag
├── KNOWN_ISSUES.md                   Wide-glyph width margin, perl dependency, /dev/tty no-op contexts
├── LICENSE                           MIT
└── CLAUDE.md                         This file
```

## Development workflow

### Edit
The script lives where it runs. Edit `statusline.sh` directly; the maintainer's live statusline reflects changes on the next render.

### Validate
**Always run all four checks before committing.** They live in `Taskfile.yml` (requires [go-task](https://taskfile.dev)); CI runs the exact same tasks:

```bash
task ci              # all four checks in order

# or individually:
task shell:syntax    # 1. bash -n on all scripts
task shell:lint      # 2. shellcheck -x -S warning (matches CI)
task test            # 3. test harness (tests/run-tests.sh)
task test-c-locale   # 4. test harness under LC_ALL=C (catches wc-m / bash-string-length issues)
```

The `shell:` tasks come from the reusable `shell.yml` in [github.com/vtmocanu/task](https://github.com/vtmocanu/task): the local checkout at `~/stuff/gitrepos/gh/vtmocanu/task` when developing, the public raw URL in CI (with `TASK_X_REMOTE_TASKFILES=1` and `task --yes`).

The fourth check is **mandatory** for any change that touches width calculation or string measurement. We've burned a CI cycle on this exact bug already (see `CHANGELOG.md` v2.1.3).

### Test ad-hoc with mock JSON
```bash
echo '{"model":{"display_name":"Claude Opus 4.6","id":"opus"},"cwd":"'$PWD'","context_window":{"remaining_percentage":75,"context_window_size":1000000},"cost":{"total_duration_ms":300000},"session_id":"test","rate_limits":{"five_hour":{"used_percentage":15,"resets_at":0},"seven_day":{"used_percentage":2,"resets_at":0}}}' \
  | bash statusline.sh
```

Expected: exactly 2 lines on stdout, exit 0, empty stderr.

## Versioning and releases

Semver: `vMAJOR.MINOR.PATCH`. The 2.x line is continuous with the script's pre-public history (it lived as `statusline-modern.sh` in a private mackup repo and was internally tagged through v2.0.0); there is no public v0/v1.

### Release process (recipe)

```bash
cd ~/stuff/gitrepos/gh/vtmocanu/cc-statusline

# 1. Make code changes, test (see Validate section above)

# 2. Update CHANGELOG.md and bump the VERSION file
#    Move [Unreleased] entries into a new ## [vX.Y.Z] section (### Added / Changed / Fixed / Security)
#    Update the link references at the bottom (compare URL + new tag entry)
#    Set VERSION to X.Y.Z (no leading "v"): it single-sources the User-Agent in
#    the hook + fetcher, so it must be bumped every release or the UA goes stale.

# 3. Commit
git add -A
git commit -m "fix: short imperative summary

Longer body explaining the why, the root cause if it's a fix,
and any non-obvious decisions. Reference CHANGELOG sections by
version tag if helpful."
# Do NOT add Co-Authored-By trailers; the maintainer prefers clean attribution.

# 4. Tag (annotated, never lightweight)
git tag -a vX.Y.Z -m "vX.Y.Z - short title matching the CHANGELOG"

# 5. Push
git push origin main --tags
#    The tag push also fires .github/workflows/release.yml, which renders
#    Formula/cc-statusline.rb and pushes it to vtmocanu/homebrew-tap (needs the
#    HOMEBREW_TAP_TOKEN repo secret; re-run via workflow_dispatch with the tag
#    if it was missing). Verify it too when watching CI.

# 6. Wait for CI to go green before creating the release entry.
gh run watch "$(gh run list --workflow=ci.yml --branch=main --limit 1 --json databaseId --jq '.[0].databaseId')" --exit-status

# 7. Create the GitHub Release entry from the CHANGELOG section
awk -v tag="vX.Y.Z" '
  /^## \[/ { if (in_section) exit; if ($0 ~ "## \\[" tag "\\]") { in_section = 1; next } }
  /^\[.*\]: / { if (in_section) exit }
  in_section { print }
' CHANGELOG.md > /tmp/release-notes.md

gh release create vX.Y.Z --title "vX.Y.Z: short title" --notes-file /tmp/release-notes.md

rm -f /tmp/release-notes.md
```

### Patch release for a single fix
For an urgent patch (CI broken, security issue): follow the same recipe but bump only PATCH. We've shipped six releases in fast succession (v2.0.0 → v2.1.3) using exactly this process.

## Testing

### What the harness checks
For each fixture in `tests/fixtures/`:
- Exit code 0
- Exactly 2 stdout lines
- Each visible column count within `SAFE_WIDTH + WIDTH_SLOP` (default 110 + 0)
- Empty stderr

### Why `WIDTH_SLOP=0`
Width measurement was rebuilt around a single ANSI-aware `measure_cols` (perl) pass: the script truncates against the exact same codepoint count the harness measures, so it never exceeds `SAFE_WIDTH` and the slop is gone. The script still keeps a small real-terminal cushion via `WIDE_GLYPH_MARGIN` (truncating to `SAFE_WIDTH - 3`), but that is invisible to the harness (it only makes lines shorter). See `KNOWN_ISSUES.md`. `WIDTH_SLOP` stays overridable for debugging.

### Why tests use `CC_STATUSLINE_SVC_CACHE` and `CC_STATUSLINE_SVC_FETCH`
The statusline normally writes the service-status cache under a per-user mode-700 runtime dir (`$XDG_RUNTIME_DIR`/`$TMPDIR`, uid-scoped) and spawns `claude-status-fetch.sh` in the background when the cache is stale. In tests this would:
- Pollute the real service-status cache on the maintainer's machine (and fight with their real Claude Code statusline)
- Cause cross-fixture contamination (test 01 spawns the fetcher, test 03 then sees the cache)

The script reads `CC_STATUSLINE_SVC_CACHE` and `CC_STATUSLINE_SVC_FETCH` env vars (added in v2.1.2) to override both paths. The test harness sets them to scratch-dir paths, so the real fetcher never runs.

### Adding a new fixture
1. Create `tests/fixtures/0N-name.json` with a JSON shape that exercises the case you care about
2. Use `"resets_at": 0` for rate limits (deterministic; non-zero values produce time-dependent output that breaks under `LC_ALL=C` and caps tests to a window)
3. Run `bash tests/run-tests.sh` and `LC_ALL=C bash tests/run-tests.sh`
4. If the fixture fails, fix the script (or the fixture if the failure is expected) before committing

## CI

`.github/workflows/ci.yml` runs on every push and PR. One job, four steps, each calling the matching Taskfile task (`shell:syntax`, `shell:lint`, `test`, `test-c-locale`); the `LC_ALL=C` run guards the v2.1.3 locale regression. `task` itself is installed via `arduino/setup-task` (SHA-pinned), and the `shell:` tasks are fetched from the public raw URL of github.com/vtmocanu/task (`TASK_X_REMOTE_TASKFILES=1` + `task --yes`).

House CI baseline (keep these when editing the workflow):
- Top-level `permissions: contents: read` (least privilege)
- `persist-credentials: false` on checkout (test-only workflow, never pushes)
- Every action SHA-pinned with a trailing `# vX.Y.Z` comment; Renovate bumps the SHA + comment
- `timeout-minutes` on the job, `concurrency` group with `cancel-in-progress: true` keyed on `github.ref`
- Triggers: `push` to main + tags, `pull_request` (never `pull_request_target`)

`ubuntu-latest` ships `shellcheck`, `jq`, `perl`, and `bash` preinstalled; no apt-get step needed.

## Portability gotchas

The script started life on macOS and accumulated portability fixes for Linux CI. The pattern: **for any system command, check both BSD and GNU**.

Helpers in `statusline.sh` (defined near the top, after the initial guards):
- `_file_mtime "$file"`: uses `date -r FILE +%s`, portable across BSD and GNU. Don't use `stat -f %m` (BSD-only) or `stat -c %Y` (GNU-only).
- `_reverse_file "$file"`: tries `tac` (GNU), then `tail -r` (BSD), then `cat` as last resort.

Other portable patterns we use:
- `perl` for ANSI-stripping and character counting (not `wc -m`, which falls back to byte-counting in `C` locale)
- `printf '%b'` (not `echo -e`) for escape handling
- Explicit `2>/dev/null` and `|| true` on every external command, since `set -uo pipefail` (no `-e`) means external failures shouldn't crash the script

## Width measurement (rebuilt)

Line widths are measured with a single ANSI-aware `measure_cols` (perl) helper, run **before** truncation decisions, not estimated in bash. One batched call measures line 1, line 2's base, every rate-detail tier candidate, the cache segment, and the service icon; truncation (priority K8s > branch > agent > mode > topic > dir) re-measures only when a line actually overflows. Line 2 picks the widest rate-detail tier that fits, reserving the service icon's real width. This replaced the old bash `L1_EST`/`L2_BASE_W` estimate and its off-by-2. Common-case cost is ~2 perl invocations per render.

Two paths cost more, both bounded and both off the common path. A viewport that cannot fit line 2's wide base re-runs the whole batch once after switching to the phone layout (one extra call). And the truncation ladder's length/slice helpers (`_clen`, `_head_cp`, `_tail_cp`) take a pure-bash path for ASCII but shell out to perl for a non-ASCII value, so truncating a multibyte directory or branch name costs a few more: the helpers exist because bash counts bytes rather than codepoints outside a UTF-8 locale, which silently under-sheds and cuts characters in half. An ASCII render at any width still costs ~2.

`WIDE_GLYPH_MARGIN` (env `STATUSLINE_GLYPH_MARGIN`, default 3) keeps a small real-terminal cushion for Nerd Font glyphs that render double-width; see `KNOWN_ISSUES.md`.

## Hook security note

`hooks/session-topic-capture.sh` calls the Anthropic API with the user's Claude Code OAuth token (read from macOS Keychain or `~/.claude/.credentials.json`). It sends excerpts of the conversation transcript to Claude Haiku for topic generation.

If you're modifying the hook:
- **Never log the token**, even with `STATUSLINE_DEBUG=1`. Redact it in any error path.
- **Don't change the User-Agent** to something that impersonates the official Claude Code client. Use `cc-statusline/X.Y.Z`. We had `claude-code/2.1.4` in v2.0.0 and removed it in v2.0.1 specifically because the public repo shouldn't ship UA spoofing.
- **Keep the rate limit** (currently: prompt 1 + every 10 prompts). Removing it would burn the user's API quota and is rude.

## GitHub interaction notes

- Use the **`gh` CLI** for everything (releases, runs, settings). Never `tea`/`fj-ex`; those are Forgejo-only and the Codeberg repo is archived.
- Repo settings baseline (applied at migration, keep intact): `GITHUB_TOKEN` default read-only, SHA-pinning required for actions, secret scanning + push protection on, private vulnerability reporting on, branch protection on `main` blocking force-pushes and deletion (direct pushes still allowed).
- Renovate handles dependency/action bumps; do not also enable Dependabot version updates.

## What NOT to do

- **Don't add `Co-Authored-By: Claude` trailers** to commits. The maintainer prefers clean attribution.
- **Don't use em dashes** in commit messages, code comments, or docs. Prefer commas, colons, or hyphens.
- **Don't reintroduce a bash width *estimate*.** Width is now measured with `measure_cols` before truncation (the deliberate v2.4.0 rebuild). If you touch truncation, keep it measurement-driven, re-validate every path in both locales, and keep `WIDTH_SLOP=0`. Don't paper over an overflow by bumping `WIDTH_SLOP` or `WIDE_GLYPH_MARGIN`.
- **Don't push directly to `main` without CI green.** The maintainer pushed v2.1.0/v2.1.1 in quick succession and burned several CI cycles diagnosing failures. Always verify the test harness passes locally (including `LC_ALL=C`) before tagging.
- **Don't bypass `install.sh`'s `git archive` flow** by using `git checkout vX.Y.Z` again. v2.1.0's installer mutated the user's working tree; v2.1.0 → v2.1.0 (later commit) fixed it to use `git archive` so the working tree stays clean. Don't regress.
- **Don't commit the `images/` PNG without first checking it's the current screenshot.** The maintainer's blog post and the README share the same image. If you're updating one, update both.
