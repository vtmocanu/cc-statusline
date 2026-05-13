# Changelog

All notable changes to cc-statusline are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [v2.2.0] - 2026-05-13

### Added
- **Opt-in account profile badge** (line 2): for users who switch between multiple Claude Code logins (work/personal), the statusline can now show a colored chip after the effort level identifying the active account. Reads the access token from the macOS Keychain, calls `https://api.anthropic.com/api/oauth/profile`, and looks up the returned `account.uuid` in `~/.claude/profile-labels.json` for a user-defined label + color. Result is cached in `/tmp/claude-profile-label` keyed by the access token, so the network call only fires on token rotation (every few hours) or when you switch accounts. Disabled by default — feature is off unless the JSON file exists with `enabled: true`. Also disabled when `STATUSLINE_PROFILE=0`. macOS-only (uses the `security` CLI); silently no-ops on other platforms. Named colors: `red`, `orange`, `yellow`, `green`, `blue`, `purple`, `cyan`, `gray`. Unknown UUIDs render as a `XXXXXX?` hint in gray so users know to add a mapping.

## [v2.1.3]

### Fixed
- **Test harness locale dependency**: `tests/run-tests.sh` `vis_cols` was using `LC_ALL=en_US.UTF-8 wc -m` to count visible columns. On CI containers (notably `ghcr.io/catthehacker/ubuntu:act-latest`) the `en_US.UTF-8` locale isn't generated, glibc silently falls back to `C`, and `wc -m` then counts **bytes** instead of characters. Each multi-byte char on line 2 (`▰▱│·` plus the powerline corners and Nerd Font icons) inflated the count by 2-3, pushing measured width from ~111 to ~143 cols and failing fixtures 01/04/05. Replaced with a perl one-liner using `Encode::decode("UTF-8", ...)` and `length()`, matching the script's own `measure_cols` helper. Locale-independent.

## [v2.1.2]

### Fixed
- **Linux portability**: `statusline.sh` and `hooks/session-topic-capture.sh` no longer call BSD-only `stat -f %m`. Replaced with `date -r FILE +%s`, which works on both BSD/macOS and GNU/Linux. The previous form crashed on Linux with `line 350: File: unbound variable` because GNU stat's `-f` is filesystem-stat mode, whose default output contains a `File:` line that bash arithmetic then tried to evaluate as a variable name.
- **`tail -r` portability**: replaced with a `_reverse_file` helper that tries `tac` (GNU) first, then `tail -r` (BSD), then `cat` as a last resort. This affected the effort-level detection in `statusline.sh`.
- **`format_reset` runaway output**: rate-limit reset times more than 99 days in the future now display as `99d+` instead of `95191d2h`. A garbage `resets_at` value can no longer blow out line 2.

### Added
- **`CC_STATUSLINE_SVC_CACHE` and `CC_STATUSLINE_SVC_FETCH` env vars**: override the service-status cache file path and the fetcher script path. Used by the test harness for isolation; defaults preserve existing behaviour.

### Tests
- The harness now sets the new env vars to scratch-dir paths so tests don't pollute `/tmp/claude-service-status` or spawn the real `curl`-driven fetcher in the background.
- Fixtures use `resets_at: 0` so the time display is deterministic regardless of when CI runs.

## [v2.1.1]

### Fixed
- `.forgejo/workflows/ci.yml` no longer uses `runs-on: docker`, which is not a valid label on Codeberg's hosted Forgejo Actions runners. The workflow now targets `codeberg-small` and consolidates the previous three jobs (shellcheck, bash-syntax, tests) into one job using the default `ghcr.io/catthehacker/ubuntu:act-latest` image, with apt-installed dependencies. See [codeberg.org/actions/meta](https://codeberg.org/actions/meta) for the runner labels.

## [v2.1.0]

### Added
- Forgejo Actions CI workflow (`.forgejo/workflows/ci.yml`) running `shellcheck`, `bash -n`, and the test harness on every push and pull request.
- `tests/` directory with a runnable test harness (`tests/run-tests.sh`) and 5 mock JSON fixtures covering happy path, empty input, missing rate limits, near-full context, and a long project name.
- `KNOWN_ISSUES.md` documenting the bash-based width estimation off-by-a-few-cols bug and its `WIDTH_SLOP` workaround.
- `images/screenshot.png` and a screenshot in the README.
- Per-OS dependency install commands and a troubleshooting section in the README.

### Changed
- `install.sh` now uses `git archive` to extract the chosen ref into a temp directory, instead of `git checkout`. The user's working tree is no longer mutated when running `--version vX.Y.Z`.
- `install.sh` reports upgrade/reinstall transitions when re-run (`upgraded vA.B.C -> vX.Y.Z`).
- `install.sh` checks for `curl` and (on macOS) `gsed` in addition to `bash`/`jq`/`perl`.

## [v2.0.1]

### Fixed
- `hooks/session-topic-capture.sh` no longer sends `User-Agent: claude-code/2.1.4`. The hook now identifies itself as `cc-statusline/2.0.1`. The user's OAuth token (with the `oauth-2025-04-20` beta header) is what authorises the request; the previous UA value impersonated the official client and shouldn't have shipped publicly.
- `statusline.sh` now wraps the tab-title `printf` to `/dev/tty` in a brace block so the bash redirection-setup error (`/dev/tty: Device not configured` in non-tty contexts like CI or piped tests) is caught by `2>/dev/null` instead of leaking to stderr.

## [v2.0.0]

Initial public release. Imported from a private mackup repo where the script lived as `statusline-modern.sh` and was previously versioned by file copies (`statusline-modern-vX.Y.Z.sh`). The 2.x version line is continuous with that internal history; there is no public v0/v1.

### Features
- Two-line ANSI statusline with project-aware background color (12-color hashed palette + manual override).
- Git info (branch, staged/modified/untracked counts).
- Kubernetes context with timeout to avoid exec-auth hangs.
- Session metrics: model name, effort level (low/medium/high/max), elapsed time.
- Context window bar and percentage.
- 5h and 7d rate-limit bars with reset countdowns, progressively compacted to fit available width.
- Claude service health indicator, refreshed every 60s from `status.claude.com` via `claude-status-fetch.sh`.
- Optional `UserPromptSubmit` hook (`hooks/session-topic-capture.sh`) that calls Claude Haiku to generate a `Project: Focus` label per session.
- Terminal tab title set from the topic or directory.
- Width-aware truncation of K8s context, branch, and topic to keep line 1 under the soft limit before Claude Code's `cli-truncate` drops line 2.

[Unreleased]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.2.0...HEAD
[v2.2.0]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.1.6...v2.2.0
[v2.1.3]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.1.2...v2.1.3
[v2.1.2]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.1.1...v2.1.2
[v2.1.1]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.1.0...v2.1.1
[v2.1.0]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.0.1...v2.1.0
[v2.0.1]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.0.0...v2.0.1
[v2.0.0]: https://codeberg.org/vtmocanu/cc-statusline/releases/tag/v2.0.0
