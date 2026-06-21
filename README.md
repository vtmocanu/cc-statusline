# cc-statusline

[![ci](https://github.com/vtmocanu/cc-statusline/actions/workflows/ci.yml/badge.svg?branch=main)](https://github.com/vtmocanu/cc-statusline/actions)
[![release](https://img.shields.io/github/v/release/vtmocanu/cc-statusline?label=release)](https://github.com/vtmocanu/cc-statusline/releases)
[![license](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A two-line, ANSI-colored statusline for [Claude Code](https://claude.com/claude-code) with project-aware colors, git status, Kubernetes context, rate-limit bars, Claude service health, and AI-generated session topics.

![cc-statusline screenshot](images/screenshot.png)

> Design notes, screenshots, and the story behind the script: **[Custom Claude Code Status Line on hai.wxs.ro](https://hai.wxs.ro/ai-stuff/claude-statusline/)**

## Features

- **Two-line layout** with project-colored top line and dark bottom line
- **Per-project background color** (12-color palette, hashed from session/cwd, manually overridable)
- **Git info**: branch, staged/modified/untracked counts
- **Kubernetes context**: current `kubectl` context (with timeout to avoid exec-auth hangs)
- **Session metrics**: model name, effort level (low/medium/high/max), elapsed time
- **Context window**: colored bar and percentage
- **Cache hit rate**: prompt-cache efficiency of the last API call (green when most of the context is cached, coral when cold); hidden before the first call and after `/compact`
- **Rate limits**: 5h and 7d bars with reset countdowns, progressively compacted to fit available width
- **Pace arrows**: optional `↑`/`→` after a rate-limit % projecting whether you'll exhaust the window before it resets (coral = will overshoot, gold = on pace, nothing = safe)
- **Claude service status**: auto-refreshed every 60s from `status.claude.com`
- **Session topic**: optional hook calls Claude Haiku to label each session with `Project: Focus`
- **Tab title**: sets the terminal tab title from the topic or directory
- **Width-aware truncation**: K8s context, branch, and topic shrink first to keep line 1 under the soft limit before Claude Code's `cli-truncate` drops line 2

## Requirements

- macOS or Linux
- `bash` 4 or newer
- `jq`
- `perl` (for ANSI-aware width measurement)
- `curl` (for service status and the optional session-topic hook)
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal for the icons

### Per-OS dependency install

| OS | Command |
|---|---|
| macOS (Homebrew) | `brew install bash jq perl curl` |
| Debian/Ubuntu | `sudo apt install bash jq perl curl` |
| Fedora/RHEL | `sudo dnf install bash jq perl curl` |
| Arch | `sudo pacman -S bash jq perl curl` |
| Alpine | `apk add bash jq perl curl coreutils` |

## Install

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
    "command": "bash /absolute/path/to/cc-statusline/statusline.sh"
  }
}
```

To enable the optional session-topic feature, also add the hook:

```json
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "/absolute/path/to/cc-statusline/hooks/session-topic-capture.sh"
          }
        ]
      }
    ]
  }
}
```

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
| `STATUSLINE_WIDTH` | `110` | Maximum visible columns per line. Lower this if you see line 2 disappearing. |
| `STATUSLINE_CACHE` | `1` | Set to `0` to hide the prompt-cache hit-rate readout (`⚡ NN%`) on line 2. |
| `STATUSLINE_PACE` | `1` | Set to `0` to hide the rate-limit pace arrows (`↑`/`→`) on line 2. |
| `STATUSLINE_GLYPH_MARGIN` | `3` | Columns reserved for Nerd Font glyphs that render double-width in some terminals. Set to `0` on a known mono-width font to reclaim them. |
| `STATUSLINE_DEBUG` | unset | Set to `1` to write stderr to `/tmp/statusline-debug.log`. |
| `CC_STATUSLINE_PREFIX` | `~/.local/share/cc-statusline` | Install prefix for `install.sh`. |

### Session-topic hook

The hook (`hooks/session-topic-capture.sh`) calls the Anthropic API with your locally stored Claude Code OAuth credentials (read from the macOS Keychain entry `Claude Code-credentials`, or `~/.claude/.credentials.json` on Linux) to generate a `Project: Focus` label for each session. It runs at most once per 10 prompts and writes to `~/.claude/session-topics/{session_id}.txt`.

> **Security note**: this hook reads your OAuth token and sends excerpts of your Claude Code transcript to the Anthropic API. If you'd rather not, simply don't register the hook in `settings.json`; the statusline will skip the topic block entirely.

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
| Topic field empty | Hook hasn't run yet (first 1-2 prompts) or OAuth token not found | Send a few prompts; check `~/.claude/session-topics/{session_id}.txt` |
| Boxes/squares instead of icons | Terminal font is not a Nerd Font | Install one from [nerdfonts.com](https://www.nerdfonts.com/) and configure your terminal |

See [KNOWN_ISSUES.md](KNOWN_ISSUES.md) for known limitations.

## Why two lines?

Claude Code's `cli-truncate` silently drops subsequent lines if line 1 exceeds the container width. This script estimates visible columns and truncates content (in priority order: K8s context, branch, topic) before that happens. See the comments in [statusline.sh](statusline.sh) for the full set of undocumented rendering quirks discovered through testing.

## License

MIT, see [LICENSE](LICENSE).
