# CLAUDE.md

This file gives Claude Code (and any other agentic coding tool) the context it needs to work productively on **cc-statusline** without re-discovering the gotchas the maintainer has already hit.

The repo lives on GitHub: **github.com/vtmocanu/cc-statusline**. Use the `gh` CLI for all hosting operations (releases, CI runs, repo settings). It previously lived on Codeberg (codeberg.org/vtmocanu/cc-statusline, now archived as a pointer); historical CHANGELOG entries up to v2.2.1 reference Codeberg CI and Forgejo specifics.

## What this repo is

A two-line ANSI statusline for [Claude Code](https://claude.com/claude-code). It's a small bash-based tool, but the codebase has accumulated real lessons about portable shell, ANSI rendering, terminal width estimation, and Claude Code's undocumented statusline renderer behaviors. **Read `KNOWN_ISSUES.md` and the comments in `statusline.sh` before changing any width-related logic.**

The primary maintainer's machine has `~/.claude/settings.json` pointing `statusLine.command` directly at `~/stuff/gitrepos/gh/vtmocanu/cc-statusline/statusline.sh` (the working tree, not an installed copy). This means edits to `statusline.sh` are picked up immediately on the next render. Public users go through `install.sh`, which extracts a tag via `git archive` into `~/.local/share/cc-statusline/`.

Live blog post with design notes: https://hai.wxs.ro/ai-stuff/claude-statusline/

## Repo layout

```
cc-statusline/
├── statusline.sh                     Main script (called by Claude Code, reads JSON from stdin, outputs 2 lines of ANSI)
├── claude-status-fetch.sh            Background helper, polls status.claude.com every 60s, writes /tmp/claude-service-status
├── hooks/
│   └── session-topic-capture.sh      Optional UserPromptSubmit hook, calls Claude Haiku to label sessions
├── install.sh                        Installer for public users (--version vX.Y.Z, --uninstall, --help)
├── examples/
│   └── statusline-color-overrides.json  Template for ~/.claude/statusline-color-overrides.json
├── tests/
│   ├── run-tests.sh                  Test harness (perl-based ANSI-aware width measurement)
│   └── fixtures/*.json               5 mock JSON inputs (happy path, empty, no rate limits, near-full context, narrow width)
├── .github/workflows/ci.yml          GitHub Actions CI: shellcheck + bash -n + test harness (default + LC_ALL=C) on push/PR
├── images/screenshot.png             Hero image used by README
├── README.md                         Public-facing docs
├── CHANGELOG.md                      Keep-a-Changelog format, one section per tag
├── KNOWN_ISSUES.md                   Width estimation off-by-2, gsed dependency, /dev/tty no-op contexts
├── LICENSE                           MIT
└── CLAUDE.md                         This file
```

## Development workflow

### Edit
The script lives where it runs. Edit `statusline.sh` directly; the maintainer's live statusline reflects changes on the next render.

### Validate
**Always run all four checks before committing:**

```bash
# 1. Syntax check
bash -n statusline.sh
bash -n claude-status-fetch.sh
bash -n install.sh
bash -n hooks/session-topic-capture.sh
bash -n tests/run-tests.sh

# 2. Shellcheck (matches CI's -S warning level)
shellcheck -S warning statusline.sh claude-status-fetch.sh install.sh hooks/session-topic-capture.sh tests/run-tests.sh

# 3. Test harness
bash tests/run-tests.sh

# 4. Test harness under broken locale (catches wc-m / bash-string-length issues)
LC_ALL=C bash tests/run-tests.sh
```

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

# 2. Update CHANGELOG.md
#    Add a new ## [vX.Y.Z] section under [Unreleased] with ### Added / ### Changed / ### Fixed
#    Update the link references at the bottom (compare URL + new tag entry)

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
- Each visible column count within `SAFE_WIDTH + WIDTH_SLOP` (default 110 + 5)
- Empty stderr

### Why `WIDTH_SLOP=5`
The script's bash-based width estimation underestimates real visible columns by 1-3 characters in some paths (the recalculation paths after K8s/branch/topic truncation drop the documented "3-char icon safety margin"). See `KNOWN_ISSUES.md` for the full diagnosis. The proper fix is to rebuild width measurement with a single perl-based ANSI-aware pass during truncation, but that's a careful refactor. Until then, tests tolerate the slop.

### Why tests use `CC_STATUSLINE_SVC_CACHE` and `CC_STATUSLINE_SVC_FETCH`
The statusline normally writes to `/tmp/claude-service-status` and spawns `claude-status-fetch.sh` in the background when the cache is stale. In tests this would:
- Pollute `/tmp` on the maintainer's machine (and fight with their real Claude Code statusline)
- Cause cross-fixture contamination (test 01 spawns the fetcher, test 03 then sees the cache)

The script reads `CC_STATUSLINE_SVC_CACHE` and `CC_STATUSLINE_SVC_FETCH` env vars (added in v2.1.2) to override both paths. The test harness sets them to scratch-dir paths, so the real fetcher never runs.

### Adding a new fixture
1. Create `tests/fixtures/0N-name.json` with a JSON shape that exercises the case you care about
2. Use `"resets_at": 0` for rate limits (deterministic; non-zero values produce time-dependent output that breaks under `LC_ALL=C` and caps tests to a window)
3. Run `bash tests/run-tests.sh` and `LC_ALL=C bash tests/run-tests.sh`
4. If the fixture fails, fix the script (or the fixture if the failure is expected) before committing

## CI

`.github/workflows/ci.yml` runs on every push and PR. One job: `bash -n`, `shellcheck -S warning`, the test harness, and the test harness again under `LC_ALL=C` (guards the v2.1.3 locale regression).

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

## Width estimation off-by-2 (known issue)

The script estimates line widths in pure bash (`L1_EST`, `L2_BASE_W`) for speed. The estimate undercounts by 1-3 characters in some paths, so actual measured width can exceed `STATUSLINE_WIDTH` by a few columns. See `KNOWN_ISSUES.md` for the diagnosis. The test harness tolerates this with `WIDTH_SLOP=5`.

**Don't try to fix this with a quick patch.** The proper fix is a perl-based ANSI-aware width pass during truncation, replacing the bash estimate. That requires careful re-validation of all truncation paths (K8s, branch, topic) and the line-1-vs-line-2 padding logic. Probably worth a v2.2.0 minor bump.

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
- **Don't refactor the width calculation as a "quick fix".** It's a known issue with a documented workaround. Touch it only as a deliberate v2.2.0+ effort.
- **Don't push directly to `main` without CI green.** The maintainer pushed v2.1.0/v2.1.1 in quick succession and burned several CI cycles diagnosing failures. Always verify the test harness passes locally (including `LC_ALL=C`) before tagging.
- **Don't bypass `install.sh`'s `git archive` flow** by using `git checkout vX.Y.Z` again. v2.1.0's installer mutated the user's working tree; v2.1.0 → v2.1.0 (later commit) fixed it to use `git archive` so the working tree stays clean. Don't regress.
- **Don't commit the `images/` PNG without first checking it's the current screenshot.** The maintainer's blog post and the README share the same image. If you're updating one, update both.
