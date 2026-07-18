# Changelog

All notable changes to cc-statusline are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [v2.13.0] - 2026-07-18

### Added
- Native per-session cost on line 2, next to the clock (`⏱ 5m · $0.42`), read straight from Claude Code's stdin `cost.total_cost_usd` (no ccusage, no transcript parsing, no network). Shown in USD with 2 decimals (a real-but-tiny cost shows `$<0.01` rather than a misleading `$0.00`); fresh sessions with no cost yet show nothing. Hide it with `STATUSLINE_COST=0`.

### Changed
- The prompt-cache hit-rate segment (`⚡ NN%`) on line 2 is now off by default; enable it with `STATUSLINE_CACHE=1` (previously shown by default, hidden with `STATUSLINE_CACHE=0`).

## [v2.12.1] - 2026-07-15

### Fixed
- Token sessions (`CLAUDE_CODE_OAUTH_TOKEN`) no longer show the default keychain account's rate-limit bars. The stdin `rate_limits` come from Claude Code's account-agnostic shared `~/.claude.json` `.cachedUsageUtilization` cache, so on a multi-account machine they can carry a different account's numbers. Previously, once a fetched (authoritative) line aged past its TTL, the display fell back to comparing the per-account cache against stdin; because two accounts have different reset windows, that compare could pick the wrong account and even overwrite the token's own cache with the keychain numbers. An account-specific session (any session whose cache is keyed, i.e. `RL_KEY` set) now trusts ONLY its own per-account fetched line, shown even when stale, and never compares against or seeds from stdin. With no fetched line yet it shows no rate bars rather than the wrong account's; a bare 4-field line left by the old behavior is ignored and self-heals on the next successful fetch.

### Changed
- `STATUSLINE_RL_BACKOFF` default lowered from 900s to 300s, so a transient double failure (usage endpoint plus the Messages header-probe fallback) does not blank an account's bars for a quarter hour. The probe is cheap and already gated to one attempt per minute per account.

## [v2.12.0] - 2026-07-14

### Added
- Header-probe fallback for accounts the usage endpoint refuses. `/api/oauth/usage` returns 429 to a `CLAUDE_CODE_OAUTH_TOKEN` credential that the Messages API accepts (HTTP 200), which left token sessions with no way to learn their own limits. The same numbers ride on every Messages API response as `anthropic-ratelimit-unified-*` headers, so on a non-200 from the usage endpoint the fetcher now issues a minimal request (haiku, `max_tokens: 1`) and reads 5h/7d utilization (a 0-1 fraction, verified against the usage endpoint: `0.55` == 55%) and reset epochs off the headers. The probe only runs after the usage endpoint fails and costs a token or two of the account's quota; `STATUSLINE_RL_PROBE=0` disables it (the account then backs off and keeps Claude Code's numbers).

## [v2.11.2] - 2026-07-14

### Fixed
- The usage fetcher now backs off on HTTP errors instead of retrying every minute: a non-200 response (observed: the usage endpoint returns 429 to a `CLAUDE_CODE_OAUTH_TOKEN` credential while accepting the same account's requests on the Messages API) drops a `.backoff` marker, and the statusline stops spawning fetches for that account while it is fresh (`STATUSLINE_RL_BACKOFF`, default 900s). A later success clears the marker. Transport failures (no HTTP status) stay on the plain 60s gate.

## [v2.11.1] - 2026-07-14

### Fixed
- Usage-fetch attempts are now gated to one per minute per account (persistent `.fetching` marker, success or failure alike). Previously a FAILED fetch wrote no stamp, so every render retried within the 30s marker window; against an already rate-limited `/api/oauth/usage` (observed HTTP 429) the retry pressure never let the limit clear.

## [v2.11.0] - 2026-07-14

### Added
- Per-account authoritative usage fetcher (`claude-usage-fetch.sh`): the statusline now asks `/api/oauth/usage` directly with the SESSION'S OWN credential (the scanned `CLAUDE_CODE_OAUTH_TOKEN` for token sessions, the stored login otherwise) in the background, writing a stamped 5-field line into the per-account rate-limits cache. While the stamp is fresh (default 300s, `STATUSLINE_RL_AUTH_TTL`) the fetched snapshot is displayed unconditionally instead of the stdin `rate_limits`, which Claude Code serves from the account-agnostic shared `~/.claude.json` `.cachedUsageUtilization` cache (whichever account fetched last), so on multi-account machines every session's bars showed one account's numbers. Fetches are throttled (60s staleness + a 30s `.fetching` marker across sessions); `STATUSLINE_RL_FETCH=0` disables the fetcher.

### Security
- The fetcher receives the token via stdin (never argv or env) and sends the Authorization header through `curl --config -` on stdin, so the credential is never visible in the process list; it is only ever sent to `api.anthropic.com` over HTTPS with a `cc-statusline/x.y.z` User-Agent, and only its short cksum hash appears in cache filenames. Fetched payloads are validated field-by-field (typed, clamped, epoch-capped) and any failure leaves the cache untouched.

## [v2.10.0] - 2026-07-14

### Added
- Profile badge now labels token-launched sessions: when the rate-limits account scan detects a `CLAUDE_CODE_OAUTH_TOKEN` session, the badge is looked up in `~/.claude/profile-labels.json` by the token's cksum hash (same key as the per-account rate-limits cache) instead of the keychain account UUID from `~/.claude.json`, which token sessions never update. Unlabeled accounts show a `NNNNNN?` hint. Badge documented in the README (it previously wasn't).

## [v2.9.1] - 2026-07-14

### Fixed
- Shared rate-limits cache is now keyed per account: sessions launched with `CLAUDE_CODE_OAUTH_TOKEN=... claude` use their own cache file (`rate-limits-<cksum-of-token>`, the token itself is never stored), so a token session's bars no longer pollute the default keychain account's sessions (and vice versa). Token-less sessions keep the unsuffixed path. Claude Code consumes the token variable before spawning subprocesses and the statusline stdin JSON carries no account identifier, so the key is recovered from the exec-time environment of the ancestor `claude` process (`/proc/PID/environ` on Linux, `ps eww` on macOS/BSD, max 6 hops, owner-readable only). `CC_STATUSLINE_RL_KEY` overrides the detected key (manual account label / test seam; empty forces the shared unsuffixed cache). Covered by two new harness tests (cross-account isolation, ancestor env scan).

## [v2.9.0] - 2026-07-13

### Added
- Shared per-user rate-limits cache: every render compares its stdin `rate_limits` snapshot against a cached account-wide one (by resets_at/used% freshness, never file mtime) and displays whichever is fresher, writing the fresher snapshot back. Idle sessions on `statusLine.refreshInterval` now show fresh 5h/7d bars instead of values frozen at their last API call. `CC_STATUSLINE_RL_CACHE` overrides the cache path (test isolation); `STATUSLINE_RL_SHARE=0` disables the feature entirely.

### Security
- Rate-limits cache writes are atomic (tmp file + `mv`, mode 600, reaped on interrupted write) and every field, cached or from stdin, is length-capped, digit-validated, and re-clamped to its valid range before use, so a tampered or malformed cache line can never feed bad values into rendering.

## [v2.8.0] - 2026-07-10

### Added
- Homebrew tap distribution (issue #4): `brew install vtmocanu/tap/cc-statusline`, alongside `install.sh`. The formula (template in `Formula.rb.tmpl`) installs the three scripts plus `VERSION` into `libexec` and puts a `cc-statusline` wrapper on PATH; a bare symlink would break the script's sibling-fetcher and `VERSION` lookups. Declares `coreutils` (GNU `timeout`, not stock on macOS), `jq`, and `uses_from_macos` curl/perl. `caveats` prints the `settings.json` snippets.
- Dev-mode toggle in the brew wrapper: write a working-tree path to `~/.config/cc-statusline/dev-dir` (or set `CC_STATUSLINE_DEV_DIR`) and `cc-statusline` runs that copy instead of the brewed one; remove the file to switch back. Takes effect on the next render, no `settings.json` edit.
- `.github/workflows/release.yml`: on each `v*` tag (or `workflow_dispatch` for an existing tag), renders the formula and pushes it to `vtmocanu/homebrew-tap` via the reusable `homebrew-tap.yml` from `github.com/vtmocanu/task`. Requires the `HOMEBREW_TAP_TOKEN` repo secret. GitHub Releases stay manual (CHANGELOG-derived notes).

### Security
- Release pipeline hardening from the pre-release audit: the brew Taskfile include is pinned to a commit SHA in CI (the publish step holds a cross-repo PAT, so it must not track `task@main`), release.yml validates the tag against strict semver before it reaches Task templating, and the reusable publish task is now `silent:` so the tap-token-bearing clone URL is never echoed into public CI logs.

### Fixed
- `install.sh` dependency check now includes `timeout` (GNU coreutils), a real runtime dependency of `statusline.sh` on macOS that was never verified; README dependency table updated to match.

## [v2.7.1] - 2026-07-10

### Added
- Documented `statusLine.refreshInterval` (Claude Code setting, seconds): re-runs the statusline on a timer so idle sessions keep fresh rate-limit reset times, service health, and usage bars. Recommended snippet (installer output and README) now includes `"refreshInterval": 60`; remove the line to update only on activity. No script change: Claude Code fires the timer, the script is unchanged.

### Fixed
- Release hygiene: v2.7.0 was tagged without a CHANGELOG section, VERSION bump, or GitHub Release (installs of that tag report User-Agent `cc-statusline/2.6.0`). The section below is backfilled and VERSION is now 2.7.1.

## [v2.7.0] - 2026-07-10

### Added
- Teammate-model hint: when the session has in-process agent-team teammates served by a different model, the model segment gains a compact family hint (`Fable 5 +opus`), so a focused teammate view is not misread as running on the session model. Claude Code sends no focused-agent info in the statusline payload (verified on v2.1.206), so this is derived from recent subagent transcripts: newest 12 `agent-*.jsonl` active in the last 5 minutes, last 100KB of each, cached 60s per session, with strict charset gates on ids and cache content.

## [v2.6.0] - 2026-07-05

### Fixed
- Agent-pane statuslines showed the parent session's model because Claude Code's stdin JSON misreports `.model` for agent sessions; the model name is now derived from the most recent `"type":"assistant"` transcript entry (validated, prettified) when it differs from stdin. Main-session output is unchanged except for the one turn right after a `/model` switch, where the last assistant entry still carries the previous model until the next response and then self-heals.

## [v2.5.1] - 2026-06-30

### Changed
- CI: bump `actions/checkout` to v7 and `arduino/setup-task` to v3 (the latter clears the Node 20 deprecation warning on the CI runner). No change to the shipped statusline.

## [v2.5.0] - 2026-06-30

### Added
- Service-status incident filter: incidents (and components) whose name matches `CC_STATUSLINE_IGNORE_INCIDENTS` (case-insensitive regex, default `suspend.*(mythos|fable)`) are ignored, so a long-lived model-suspension notice no longer keeps the status icon lit. The default keys on the suspension sentence, not the bare model name, so a real future incident for those models (e.g. "Elevated error rates on Fable 5") is still reported.
- Fetcher test harness `tests/run-fetch-tests.sh` (13 cases, run in both locales via `task test-fetch` and CI): suspension filter, real-incident survival, severity ranking, fail-closed parsing, and injection safety.
- `CC_STATUSLINE_SVC_DATA` test seam: the fetcher reads a JSON fixture instead of hitting the network (same spirit as `CC_STATUSLINE_SVC_CACHE` / `CC_STATUSLINE_SVC_FETCH` / `CC_STATUSLINE_NOW`).

### Changed
- Service-status severity is now derived from the worst non-ignored, non-operational component, independent of the page-level indicator (`none/minor/major/critical`), which a persistent ignored incident keeps pinned.

### Fixed
- Degraded/partial/major service-status icons (`~` / `✗`) never rendered: the fetcher wrote the page-level indicator (`minor:...`), but the statusline only matches component-severity prefixes (`degraded_performance:` / `partial_outage:` / `major_outage:`). The fetcher now emits those prefixes.
- A non-empty non-JSON response (proxy or Cloudflare error page) or an invalid `CC_STATUSLINE_IGNORE_INCIDENTS` regex wrote a false `operational` (green check): `eval "$(jq ...)"` guarded eval's exit status, not jq's. The fetcher now leaves the existing cache untouched on any parse failure, matching the network-error path.

### Security
- Command injection (RCE) in the status fetcher: a JSON array in `.status.description` from the status endpoint reached `eval` through `@sh` (which emits multiple shell tokens for an array, not one quoted string) and executed arbitrary commands with the user's privileges, re-triggered roughly every 60s. Every field interpolated into the eval'd `@sh` output is now coerced with `tostring`; the name fields additionally sit behind jq `test()`, which fails the run closed on a non-string. Exploitation requires control of the TLS-validated `status.claude.com` response body.

## [v2.4.0] - 2026-06-21

### Added
- New env var `STATUSLINE_GLYPH_MARGIN` (default `3`): reserves columns for Nerd Font glyphs that render double-width in some terminals. Set to `0` on a known mono-width font to reclaim those columns.
- `VERSION` file at the repo root: single source of truth for the script version. The topic hook and status fetcher now send `User-Agent: cc-statusline/<version>` on every request (was a hardcoded stale `cc-statusline/2.0.1` in the hook and an off-convention `claude-code-statusline/1.0` in the fetcher).

### Changed
- **Width measurement rebuilt**: the bash character-count estimate (`L1_EST`/`L2_BASE_W`) is replaced by `measure_cols`-driven truncation run before truncation decisions. All truncation paths (K8s context, branch, topic, DIR, rate-detail tier) now use one ANSI-aware codepoint measurement, eliminating the documented off-by-2 between the estimate and post-truncation recalculations.
- **Rate-detail tier selection**: the compact/minimal fallback tier is now chosen from a real measurement of each candidate (full/compact/minimal) with the service icon reserved, not from a fixed character reserve. Fixes line 2 overflow at 116 visible columns (width 110) caused by 3-digit percentages, long reset countdowns, or a trailing service-status icon.
- **DIR truncation (new)**: a long single cwd path segment on line 1 is now truncatable (trimmed keeping the tail/leaf). Previously there was no DIR truncation, causing overflow at ~132 cols.
- Test harness `WIDTH_SLOP` now defaults to `0`: the script and harness measure identically, so no tolerance slop is needed.
- Runtime files (lock, counter, service-status cache) moved from predictable world-writable `/tmp` paths to a per-user mode-700 runtime directory (`XDG_RUNTIME_DIR` / `TMPDIR`, uid-scoped `/tmp` fallback).

### Fixed
- Line 2 could exceed the safe width and be dropped by Claude Code's `cli-truncate`: the rate-detail tier was chosen from a fixed reserve that ignored 3-digit percentages, long reset countdowns, and the trailing service-status icon. Now bounded. Reproduced at 116 cols (width 110).
- A long single cwd path segment overflowed line 1: no DIR truncation existed. Reproduced at 132 cols. DIR is now truncatable.
- Width off-by-2 between the initial bash estimate and post-truncation recalculations: all truncation now uses `measure_cols` (one ANSI-aware codepoint pass).
- Topic silently vanished on Linux: used `gsed` with no fallback on line 160. Now uses `perl` (already a hard dependency).
- `install.sh` dependency check incorrectly required `gsed` on macOS and was Linux-blind. Removed (perl covers the use case).
- Displayed percentages are clamped to 0-100: a malformed field could previously print `105%` or `-30%`.
- DIR mishandled a trailing slash in cwd.

### Security
- Session topic and profile label are sanitized of ANSI/OSC/control bytes before printing: a crafted or model-generated topic could otherwise spoof the terminal tab title or clear the screen. The hook also strips control bytes when writing the topic file.
- `session_id` is validated to a safe charset before use in any file path (path-traversal guard), in both the statusline and the hook.
- Runtime files moved out of predictable world-writable `/tmp` paths into a per-user mode-700 directory (see Changed above).

## [v2.3.1] - 2026-06-21

### Fixed
- **Profile badge `enabled: false` toggle never worked.** The gate read the flag with `jq -r '.enabled // true'`, but jq's `//` alternative operator treats `false` (not just `null`) as "absent", so `false // true` evaluates to `true` and the badge stayed on. Setting `"enabled": false` in `~/.claude/profile-labels.json` had no effect; the only way to hide the badge was `STATUSLINE_PROFILE=0` or deleting the file. Replaced with `jq -r '.enabled != false'`, which yields `false` only when the flag is explicitly `false` and `true` for both `true` and absent (default-on preserved).

## [v2.3.0] - 2026-06-19

### Added
- **Cache hit rate (line 2)**: a compact `⚡ NN%` readout tucked right after the context size (`of 1000k ⚡ 92%`), showing what fraction of the last API call's input tokens was served from the prompt cache (`cache_read_input_tokens / (input_tokens + cache_creation_input_tokens + cache_read_input_tokens)`, from `context_window.current_usage`). The percentage color is inverted relative to the context bar: green when most of the context is cached (good), coral when caching is cold. The segment is omitted when `current_usage` is `null` (before the first API call and after `/compact`) or when no input tokens are present. It is the lowest-priority line-2 element: the rate-limit detail claims width first (its tier is chosen from the base width excluding cache, so the reset countdowns are never squeezed out), and cache renders only in the measured leftover. Raise `STATUSLINE_WIDTH` to fit both comfortably. Opt out with `STATUSLINE_CACHE=0`. Fixture `06-cache.json` covers it.
- **Rate-limit pace arrows (line 2)**: each rate limit can show an arrow after its percentage projecting where usage is headed by the window reset (`projected% = used% × window_duration / elapsed`, integer math, no `bc`): `↑` coral when you'll exhaust the cap before reset (projected > 115%), `→` gold when roughly on pace (85-115%). Under-consuming (the common case) shows **no** arrow, so the glyph reads as an alert and reclaims its width. Suppressed during the first 2% of a window and whenever `resets_at` is missing/zero. Opt out with `STATUSLINE_PACE=0`. Fixture `07-pace.json` covers both directions deterministically via the new `CC_STATUSLINE_NOW` clock override; the harness also pins that clock and disables the profile badge so width is identical across machines and locales.
- `Taskfile.yml` with the validation suite (`task shell:syntax`, `task shell:lint`, `task test`, `task test-c-locale`, `task ci`). The `shell:` tasks are included from the reusable [`shell.yml` in vtmocanu/task](https://github.com/vtmocanu/task) (local checkout when developing, public raw URL in CI). CI installs [go-task](https://taskfile.dev) via `arduino/setup-task` and runs these tasks instead of inline shell, so local validation and CI are the same commands.

### Changed
- **Project moved from Codeberg to GitHub**: the repo now lives at [github.com/vtmocanu/cc-statusline](https://github.com/vtmocanu/cc-statusline). The Codeberg repo is archived and kept as a pointer. CI moved from Forgejo Actions (`.forgejo/workflows/ci.yml`) to GitHub Actions (`.github/workflows/ci.yml`), which now also runs the test harness under `LC_ALL=C` to guard the v2.1.3 locale regression.

## [v2.2.1] - 2026-05-13

### Changed
- **Profile badge: read account UUID from `~/.claude.json` instead of calling the OAuth API.** Claude Code itself maintains `.oauthAccount.accountUuid` (plus `.emailAddress` and `.organizationName`) in `~/.claude.json` on every login. Tools like [claude-account-switcher](https://github.com/Symbioose/claude-account-switcher) swap this field atomically when you switch accounts. By reading from this file directly, the statusline:
  - **Drops the network call** to `api.anthropic.com/api/oauth/profile` — instant render, no latency, works offline.
  - **Drops the Keychain dependency** — no more `security` CLI requirement, so the feature now works on **Linux as well as macOS**.
  - **Drops the access-token cache** — the local jq read is fast enough to do on every render.
- `~/.claude/label-current-profile.sh` helper now reads from `~/.claude.json` too (same single source of truth); no API call needed.

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

[v2.13.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.12.1...v2.13.0
[v2.12.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.12.0...v2.12.1
[v2.12.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.11.2...v2.12.0
[v2.11.2]: https://github.com/vtmocanu/cc-statusline/compare/v2.11.1...v2.11.2
[v2.11.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.11.0...v2.11.1
[v2.11.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.10.0...v2.11.0
[v2.10.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.9.1...v2.10.0
[v2.9.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.9.0...v2.9.1
[v2.9.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.8.0...v2.9.0
[v2.8.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.7.1...v2.8.0
[v2.7.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.7.0...v2.7.1
[v2.7.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.6.0...v2.7.0
[v2.6.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.5.1...v2.6.0
[v2.5.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.5.0...v2.5.1
[v2.5.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.4.0...v2.5.0
[v2.4.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.3.1...v2.4.0
[v2.3.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.3.0...v2.3.1
[v2.3.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.2.1...v2.3.0
[v2.2.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.2.0...v2.2.1
[v2.2.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.1.6...v2.2.0
[v2.1.3]: https://github.com/vtmocanu/cc-statusline/compare/v2.1.2...v2.1.3
[v2.1.2]: https://github.com/vtmocanu/cc-statusline/compare/v2.1.1...v2.1.2
[v2.1.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.1.0...v2.1.1
[v2.1.0]: https://github.com/vtmocanu/cc-statusline/compare/v2.0.1...v2.1.0
[v2.0.1]: https://github.com/vtmocanu/cc-statusline/compare/v2.0.0...v2.0.1
[v2.0.0]: https://github.com/vtmocanu/cc-statusline/releases/tag/v2.0.0
