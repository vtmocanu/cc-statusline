# Changelog

All notable changes to cc-statusline are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.1.0...HEAD
[v2.1.0]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.0.1...v2.1.0
[v2.0.1]: https://codeberg.org/vtmocanu/cc-statusline/compare/v2.0.0...v2.0.1
[v2.0.0]: https://codeberg.org/vtmocanu/cc-statusline/releases/tag/v2.0.0
