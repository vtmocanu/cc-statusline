# cc-statusline

A two-line, ANSI-colored statusline for [Claude Code](https://claude.com/claude-code) with project-aware colors, git status, Kubernetes context, rate-limit bars, Claude service health, and AI-generated session topics.

## Features

- **Two-line layout** with project-colored top line and dark bottom line
- **Per-project background color** (12-color palette, hashed from session/cwd, manually overridable)
- **Git info** — branch, staged/modified/untracked counts
- **Kubernetes context** — current `kubectl` context (with timeout to avoid exec-auth hangs)
- **Session metrics** — model name, effort level (low/medium/high/max), elapsed time
- **Context window** — colored bar + percentage
- **Rate limits** — 5h and 7d bars with reset countdowns, progressively compacted to fit available width
- **Claude service status** — auto-refreshed every 60s from `status.claude.com`
- **Session topic** — optional hook calls Claude Haiku to label each session with `Project: Focus`
- **Tab title** — sets the terminal tab title from the topic or directory
- **Width-aware** — measures visible columns (ANSI-stripped) and truncates K8s/branch/topic before Claude Code's `cli-truncate` drops line 2

## Requirements

- macOS or Linux
- `bash` 4+
- `jq`
- `perl` (for ANSI-aware width measurement)
- `gsed` on macOS (`brew install gnu-sed`) — only used by the optional session-topic hook
- `curl` (for service status and the optional session-topic hook)
- A [Nerd Font](https://www.nerdfonts.com/) in your terminal for the icons

## Install

```bash
git clone https://codeberg.org/vtmocanu/cc-statusline.git
cd cc-statusline
./install.sh
```

The installer copies the scripts into `~/.local/share/cc-statusline/` and prints the snippets you need to paste into `~/.claude/settings.json`.

To pin a specific release:

```bash
./install.sh --version v2.0.0
```

To uninstall:

```bash
./install.sh --uninstall
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

The key is the project root (resolved via `git rev-parse --show-toplevel`), and the value is a palette index `0-11`. See `examples/statusline-color-overrides.json` for the full palette mapping.

### Environment variables

| Variable | Default | Purpose |
|---|---|---|
| `STATUSLINE_WIDTH` | `110` | Maximum visible columns per line. Lower this if you see line 2 disappearing. |
| `STATUSLINE_DEBUG` | unset | Set to `1` to write stderr to `/tmp/statusline-debug.log`. |

### Session-topic hook

The hook (`hooks/session-topic-capture.sh`) calls the Anthropic API with your locally stored OAuth credentials (read from macOS Keychain or `~/.claude/.credentials.json`) to generate a `Project: Focus` label for each session. It runs at most once per 10 prompts and writes to `~/.claude/session-topics/{session_id}.txt`.

If you don't want this feature, just don't register the hook — the statusline will skip the topic block.

## Versioning

Releases are tagged with semantic version tags (`v2.0.0`, `v2.1.0`, ...). The `main` branch is always the latest tested state. To roll back, either:

```bash
# In your clone
git checkout v2.0.0
```

or, if you used `install.sh`:

```bash
./install.sh --version v2.0.0
```

## Why two lines?

Claude Code's `cli-truncate` silently drops subsequent lines if line 1 exceeds the container width. This script measures visible columns ANSI-aware and truncates content (in priority order: K8s context, branch, topic) before that happens. See [the discussion in the script](statusline.sh) for the full set of undocumented rendering quirks discovered through testing.

## License

MIT — see [LICENSE](LICENSE).
