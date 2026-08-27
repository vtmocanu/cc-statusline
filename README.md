# cc-statusline

[![ci](https://github.com/vtmocanu/cc-statusline/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/vtmocanu/cc-statusline/actions)
[![release](https://img.shields.io/github/v/release/vtmocanu/cc-statusline?label=release)](https://github.com/vtmocanu/cc-statusline/releases)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A two-line, ANSI-colored statusline for [Claude Code](https://claude.com/claude-code) with project-aware colors, git status, Kubernetes context, rate-limit bars, Claude service health, and the session's name and title.

![cc-statusline screenshot](images/screenshot.png)

> Design notes, screenshots, and the story behind the script: **[Custom Claude Code Status Line on hai.wxs.ro](https://hai.wxs.ro/ai-stuff/claude-statusline/)**

## Features

- **Two-line layout** with project-colored top line and dark bottom line
- **Per-project background color** (12-color palette, hashed from session/cwd, manually overridable)
- **Git info**: branch, staged/modified/untracked counts
- **Kubernetes context**: current `kubectl` context (with timeout to avoid exec-auth hangs)
- **Session metrics**: model name, effort level (low/medium/high/max), elapsed time, session cost in USD (from Claude Code's `cost.total_cost_usd`; hide with `STATUSLINE_COST=0`)
- **Context window**: colored bar and percentage
- **Cache hit rate**: prompt-cache efficiency of the last API call (green when most of the context is cached, coral when cold); off by default, enable with `STATUSLINE_CACHE=1` (hidden anyway before the first call and after `/compact`)
- **Context fill on phone**: the phone/slim layout shows `ctx NN%` (context-window usage, same color thresholds as the rate limits) before the 5h/7d windows; on by default, hide with `STATUSLINE_CTX=0`. The wide layout already shows context as `NN% of NNNk`.
- **Rate limits**: 5h and 7d bars with reset countdowns, progressively compacted to fit available width; shared across your sessions via a small per-user cache, so an idle session never shows numbers staler than your account's latest known state
- **Pace arrows**: optional `↑`/`→` after a rate-limit % projecting whether you'll exhaust the window before it resets (coral = will overshoot, gold = on pace, nothing = safe)
- **Claude service status**: auto-refreshed every 60s from `status.claude.com`
- **GitHub service status**: line-1 icon (same glyphs/colors as the Claude one), shown on repos with a `github.com` remote; on by default, disable with `STATUSLINE_GITHUB_STATUS=0`
- **Clickable status icons**: both service-status icons are OSC 8 hyperlinks (GitHub icon to `githubstatus.com`, Claude icon to `status.claude.com`), so Cmd+click (macOS) / Ctrl+click opens the status page in a supporting terminal; on by default, disable with `STATUSLINE_HYPERLINKS=0`
- **Session name (`@handle`)**: the addressable name other Claude sessions use to message this one (Claude Code's per-session registry), shown first on line 1; on by default, hide with `STATUSLINE_SESSION_NAME=0`
- **Session title**: Claude Code's native session name (its `/rename` value or auto-generated title, from `.session_name`) as a descriptive label after the handle; hide with `STATUSLINE_TOPIC=0`
- **Tab title**: sets the terminal tab title from the session title or directory
- **Width-aware truncation**: K8s context, branch, title, and name shrink first to keep line 1 under the soft limit before Claude Code's `cli-truncate` drops line 2

## Requirements

- macOS or Linux
- `bash` 4 or newer
- `jq`
- `perl` (for ANSI-aware width measurement)
- `curl` (for service status)
- GNU `timeout` (coreutils; not stock on macOS)
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal for the icons

### Per-OS dependency install

| OS | Command |
|---|---|
| macOS (Homebrew) | `brew install bash jq perl curl coreutils` |
| Debian/Ubuntu | `sudo apt install bash jq perl curl` |
| Fedora/RHEL | `sudo dnf install bash jq perl curl` |
| Arch | `sudo pacman -S bash jq perl curl` |
| Alpine | `apk add bash jq perl curl coreutils` |

The Homebrew install below pulls these in automatically, except `bash` (your system's copy works; the scripts avoid bash-4-only features) and the font.

## Install

### Homebrew (recommended)

```bash
brew tap vtmocanu/tap
brew trust vtmocanu/tap    # Homebrew 6.0+ requires trusting third-party taps
brew install cc-statusline
```

On Homebrew older than 6.0 the `brew trust` line doesn't exist; skip it (`brew install vtmocanu/tap/cc-statusline` also works there as a one-liner). If you'd rather not trust the whole tap, `brew trust --formula vtmocanu/tap/cc-statusline` scopes it to this formula.

The install puts `cc-statusline` on your PATH, declares the dependencies, and prints the `settings.json` snippets to paste (also shown by `brew info cc-statusline`). Point Claude Code at it:

```json
{
  "statusLine": {
    "type": "command",
    "command": "cc-statusline",
    "refreshInterval": 60
  }
}
```

Upgrades are just `brew upgrade cc-statusline`; no settings change across versions.

Hacking on a clone while keeping the brew setup? Write your working-tree path to `~/.config/cc-statusline/dev-dir` and the `cc-statusline` wrapper runs that copy instead (delete the file to switch back):

```bash
mkdir -p ~/.config/cc-statusline
echo ~/src/cc-statusline > ~/.config/cc-statusline/dev-dir
```

### install.sh (any platform, no Homebrew)

```bash
git clone https://github.com/vtmocanu/cc-statusline.git
cd cc-statusline
./install.sh
```

The installer extracts the chosen ref via `git archive` (so it never mutates your working tree), copies the scripts into `~/.local/share/cc-statusline/`, and prints the JSON snippets you need to paste into `~/.claude/settings.json`.

To pin a specific release:

```bash
./install.sh --version v2.1.0
```

To uninstall:

```bash
./install.sh --uninstall
```

To install into a custom prefix:

```bash
CC_STATUSLINE_PREFIX=/opt/cc-statusline ./install.sh
```

## Manual install

If you'd rather skip `install.sh`, point `statusLine.command` directly at your clone:

```json
{
  "statusLine": {
    "type": "command",
    "command": "bash /absolute/path/to/cc-statusline/statusline.sh",
    "refreshInterval": 60
  }
}
```

`refreshInterval` (seconds) re-runs the statusline on a timer in addition to activity-driven updates, so idle sessions keep fresh rate-limit reset times, service health, and usage bars. It requires a recent Claude Code version; remove the line to update only on activity. Rate-limit bars specifically stay fresh across *all* your sessions, not just the one being refreshed: each render shares the freshest known account-wide values with the others via a small per-user cache (`STATUSLINE_RL_SHARE=0` to disable). The cache is keyed per account: sessions launched with `CLAUDE_CODE_OAUTH_TOKEN=... claude` get their own cache file (keyed by a hash of the token, never the token itself), so different accounts never see each other's bars.

No hook is needed for the session name or title: line 1 reads both from Claude Code directly (the `@handle` from its per-session registry, the descriptive title from the `.session_name` payload field).

## Configuration

### Color overrides

By default each project gets a hashed color from a 12-color palette. To pin a project to a specific color, create `~/.claude/statusline-color-overrides.json`:

```json
{
  "/Users/me/code/important-project": 3,
  "/Users/me/code/other-project": 7
}
```

The key is the project root (resolved via `git rev-parse --show-toplevel`); the value is a palette index `0-11`. See `examples/statusline-color-overrides.json` for the full palette mapping.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `STATUSLINE_WIDTH` | `110` | Maximum visible columns per line, and a hard cap: when Claude Code reports a narrower viewport (see below), the render follows the viewport instead. Lower this if you see line 2 disappearing. |
| `STATUSLINE_LAYOUT` | `auto` | `phone` or `wide` forces a layout; `auto` picks from the reported viewport width. |
| `STATUSLINE_PHONE_COLS` | `60` | Viewport width below which `auto` always selects the phone layout. Above it, `auto` still falls back to phone when the wide line 2 measurably does not fit (see below). |
| `STATUSLINE_CACHE` | `0` | Set to `1` to show the prompt-cache hit-rate readout (`⚡ NN%`) on line 2 (off by default). |
| `STATUSLINE_CTX` | `1` | Set to `0` to hide the context-fill segment (`ctx NN%`) on the phone/slim layout's line 2. Shown before the rate limits with the same color thresholds; the first line-2 segment to shed as the viewport tightens. The wide layout's context readout is unaffected. |
| `STATUSLINE_SESSION_NAME` | `1` | Set to `0` to hide the `@handle` (the addressable session name peers message, read from Claude Code's per-session registry) at the start of line 1. |
| `STATUSLINE_TOPIC` | `1` | Set to `0` to hide the descriptive session title on line 1 (Claude Code's `/rename` value or auto-generated title, from the `.session_name` payload field). |
| `STATUSLINE_GITHUB_STATUS` | `1` | Set to `0` to hide the GitHub service-status icon on line 1 after the branch (same glyphs/colors as the Claude icon). Shown only when the current repo has a `github.com` remote; polls `githubstatus.com` every 60s in the background. |
| `STATUSLINE_HYPERLINKS` | `1` | Set to `0` to disable the OSC 8 hyperlinks on the service-status icons (GitHub icon to `githubstatus.com`, Claude icon to `status.claude.com`). Needs a terminal that supports OSC 8 (Ghostty, iTerm2, Kitty, WezTerm); elsewhere the escape is swallowed and the icon shows as plain text. |
| `STATUSLINE_PACE` | `1` | Set to `0` to hide the rate-limit pace arrows (`↑`/`→`) on line 2. |
| `STATUSLINE_COST` | `1` | Set to `0` to hide the session-cost readout (`· $N.NN`, sub-cent shown as `$<0.01`) on line 2, read from Claude Code's `cost.total_cost_usd`. |
| `STATUSLINE_RL_SHARE` | `1` | Set to `0` to disable the shared per-user rate-limits cache (no read, no write). |
| `STATUSLINE_RL_FETCH` | `1` | Set to `0` to disable the background per-account usage fetcher (`claude-usage-fetch.sh`), which asks `api.anthropic.com/api/oauth/usage` with the session's own credential so multi-account machines show each account's true bars instead of Claude Code's shared (account-agnostic) numbers. |
| `STATUSLINE_RL_AUTH_TTL` | `300` | Seconds a fetched usage snapshot stays authoritative (displayed over the stdin `rate_limits`). |
| `STATUSLINE_RL_BACKOFF` | `300` | Seconds to stop fetching for an account after the usage endpoint returns an HTTP error (e.g. 429) with no usable fallback. |
| `STATUSLINE_RL_PROBE` | `1` | Set to `0` to disable the Messages-API header probe used when the usage endpoint refuses the credential (the probe costs a token or two of quota). |
| `CC_STATUSLINE_RL_KEY` | auto | Override the rate-limits cache account key (a label like `work`). Normally auto-detected from the session's `CLAUDE_CODE_OAUTH_TOKEN` (hashed, read from the parent `claude` process's exec-time environment since Claude Code consumes the variable). Set empty to force the shared unsuffixed cache. |
| `STATUSLINE_GLYPH_MARGIN` | `3` | Columns reserved for Nerd Font glyphs that render double-width in some terminals. Set to `0` on a known mono-width font to reclaim them. |
| `STATUSLINE_PROFILE` | `1` | Set to `0` to hide the account/profile badge (see below). |
| `STATUSLINE_DEBUG` | unset | Set to `1` to write stderr to `/tmp/statusline-debug.log`. |
| `CC_STATUSLINE_PREFIX` | `~/.local/share/cc-statusline` | Install prefix for `install.sh`. |

### Phone layout (narrow viewports)

Claude Code exports `COLUMNS`/`LINES` to the statusline process (v2.1.153+), and it
reports the viewport of the client doing the viewing: the same session rendered
from the Claude mobile app arrives with `COLUMNS=52` while the desk terminal
renders it at `COLUMNS=324`. Each attached client gets its own render, so both can
be right at once. Below `STATUSLINE_PHONE_COLS` (60) the script switches to a
layout built for that width, and above it the switch still happens whenever the
wide render measurably will not fit: line 2's wide base (model, effort, clock,
cost, context) cannot be truncated, so the tier is re-decided after measuring it.
That threshold therefore moves with your own line: a long model display name or a
5-figure cost can select the phone layout as high as the low 90s, and a lean
session stays wide down to 60. `STATUSLINE_LAYOUT=wide` overrides this if you
would rather have the wide render and accept the truncation.

The phone layout:

```
 󰉋 phone │  devmetaminds/phone !1 ?1
 wxs │ ctx 46% │ 5h 77%↑ ↻2h28m │ 7d 81%↑ ↻4d8h │ ✓
```

Line 1 keeps the folder, branch and dirty markers; line 2 keeps the account badge,
the context fill (`ctx NN%`), and both rate-limit windows with their pace arrows and
reset countdowns (`↻`). The session name and title, model, effort, elapsed, cost and
cache are dropped: at 50 columns they cost more room than they earn. As the viewport
narrows further, each line sheds independently. Line 2 drops the reset countdowns
first (keeping `ctx` and the bare percentages), then drops `ctx` so the rate limits
themselves always survive (`STATUSLINE_CTX=0` removes `ctx` entirely). Line 1
collapses the folder to its leaf, trims
the branch (keeping its tail, since worktree branches share long prefixes), drops
the dirty markers, trims the folder, and at the very narrowest drops the branch
entirely so the leaf folder survives: at that width, which session this is
matters more than which branch it is on.

No configuration is needed. `STATUSLINE_LAYOUT=phone|wide` forces a layout, and a
one-line `$XDG_CONFIG_HOME/cc-statusline/layout` file holding `phone` or `wide`
does the same for a running session (useful for clients that report no viewport);
the environment variable wins over the file, and the file wins over auto-detection.

Note that the tier follows the *effective* width, which is `STATUSLINE_WIDTH`
capped by the reported viewport. So an explicit `STATUSLINE_WIDTH` below
`STATUSLINE_PHONE_COLS` selects the phone layout even on a wide terminal. That is
deliberate (the layout should match the width the line is being fitted to), but
if you set a narrow `STATUSLINE_WIDTH` as a truncation workaround and want the
full render anyway, pin it with `STATUSLINE_LAYOUT=wide`.

### Account/profile badge (multi-account setups)

Opt-in: create `~/.claude/profile-labels.json` with a `profiles` map and the badge shows which account a session is on (`· MM`), colored per profile. Entries are keyed by the account UUID from `~/.claude.json` (`.oauthAccount.accountUuid`, keychain logins), or, for sessions launched with `CLAUDE_CODE_OAUTH_TOKEN=... claude`, by the `cksum` hash of that token (the same key the per-account rate-limits cache uses; an unlabeled account shows `NNNNNN?` so you know what to add):

```json
{
  "enabled": true,
  "profiles": {
    "ed3f1226-c7fe-45ef-af44-6d7fb62175d0": { "label": "home", "color": "orange" },
    "4258859386":                            { "label": "work", "color": "red" }
  }
}
```

### Session name and title

Line 1 leads with two identifiers Claude Code provides natively, so neither needs a hook or an API call:

- **`@handle`** (the session name): the short, addressable name other Claude sessions use to message this one (`SendMessage({to: "<handle>"})`), for example `@uzi-60`. It is read from Claude Code's per-session registry under `~/.claude/sessions/*.json` (the `.name` field, matched to the session by its id), which reflects both the auto-derived default and a `/rename`. Hide it with `STATUSLINE_SESSION_NAME=0`. This registry is an internal Claude Code file, so the read is best-effort: if its shape changes in a future release, the handle simply doesn't show.
- **Title** (the descriptive label): Claude Code's native session name, from the `.session_name` field of the statusline payload, which is your `/rename` value or the auto-generated session title (for example `Add session names to status line`). Hide it with `STATUSLINE_TOPIC=0`. It is absent until Claude Code has named the session, so a brand-new session may show no title for its first moments.

Earlier versions synthesized the title with an opt-in `UserPromptSubmit` hook that called Claude Haiku; that hook has been removed in favor of the native field, which needs no credential, transcript excerpt, or quota. If you registered that hook in `settings.json` before upgrading, remove its `UserPromptSubmit` entry: otherwise Claude Code prints `session-topic-capture.sh: No such file or directory` on every prompt (harmless but noisy). The stale `~/.claude/session-topics/` cache it wrote is safe to delete.

### Per-account usage fetcher

`claude-usage-fetch.sh` runs in the background (spawned by the statusline, throttled to once a minute across all your sessions per account) and asks `api.anthropic.com/api/oauth/usage` for the account's true 5h/7d usage, authenticated as the session itself: the session's `CLAUDE_CODE_OAUTH_TOKEN` when it was launched with one, your stored login otherwise. This exists because Claude Code feeds every session the same cached rate-limit numbers regardless of which account the session bills (shared `~/.claude.json` state), so on multi-account machines the bars were whichever account fetched last. The credential is never logged, never put in argv/env, and is only sent to `api.anthropic.com` over HTTPS. Set `STATUSLINE_RL_FETCH=0` to disable (the statusline then falls back to whatever Claude Code reports).

If the usage endpoint refuses a credential (it answers 429 to `CLAUDE_CODE_OAUTH_TOKEN` credentials that the Messages API accepts), the fetcher falls back to a minimal Messages request (haiku, `max_tokens: 1`) and reads the account's limits off the `anthropic-ratelimit-unified-*` response headers. That probe costs a token or two of the account's quota; `STATUSLINE_RL_PROBE=0` turns it off, and after a failure with no usable fallback the account backs off for `STATUSLINE_RL_BACKOFF` seconds.

## Versioning

Releases are tagged with semantic version tags (`v2.0.0`, `v2.0.1`, `v2.1.0`, ...). The `main` branch is always the latest tested state. The `2.x` line is continuous with the script's pre-public history (it lived in a private dotfiles repo as `statusline-modern.sh`); see [CHANGELOG.md](CHANGELOG.md) for details.

To roll back:

```bash
# Reinstall a specific version (does not touch your clone)
./install.sh --version v2.0.0
```

## Testing

```bash
bash tests/run-tests.sh

# or, with go-task installed, the full validation suite (syntax + shellcheck + tests):
task ci
```

Runs the harness against the JSON fixtures in `tests/fixtures/`. Each fixture is piped through `statusline.sh` and asserted on:

- exit code 0
- exactly 2 stdout lines
- visible columns within `SAFE_WIDTH + WIDTH_SLOP` (default 110 + 0)
- empty stderr

CI runs the same harness on every push and pull request via `.github/workflows/ci.yml`, both under the default locale and under `LC_ALL=C`.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Line 2 missing in Claude Code | Line 1 exceeds the container width and `cli-truncate` drops subsequent lines | Lower `STATUSLINE_WIDTH` (e.g. `STATUSLINE_WIDTH=100`) |
| Statusline not showing at all | Script crash; `set -uo pipefail` exits silently | Run `STATUSLINE_DEBUG=1 bash statusline.sh < /tmp/test.json` and check `/tmp/statusline-debug.log` |
| Wrong project color | Color hash collision or stale override | Add the project root to `~/.claude/statusline-color-overrides.json` |
| Service status icon missing | `claude-status-fetch.sh` not yet run, or `curl` failed | Wait 60s, or run the fetcher manually: `bash claude-status-fetch.sh` |
| Session title empty | Claude Code hasn't named the session yet (brand-new session), or you're on a Claude Code without `.session_name` | Send a few prompts so a title is generated, or set one with `/rename`; upgrade Claude Code if the field is absent |
| `@handle` missing | Registry file absent (older Claude Code), or its shape changed | Upgrade Claude Code; the handle reads `~/.claude/sessions/*.json` best-effort |
| Boxes/squares instead of icons | Terminal font is not a Nerd Font | Install one from [nerdfonts.com](https://www.nerdfonts.com/) and configure your terminal |

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for known limitations.

## Why two lines?

Claude Code's `cli-truncate` silently drops line 2 when a line exceeds the container width. This script measures visible columns with an ANSI-aware helper (it does not estimate) and truncates content (in priority order: K8s context, branch, agent, mode, title, session name, directory) before that happens. See the comments in [statusline.sh](statusline.sh) for the full set of undocumented rendering quirks discovered through testing.

## License

MIT, see [LICENSE](LICENSE).
