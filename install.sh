#!/usr/bin/env bash
# cc-statusline installer
#
# Usage:
#   ./install.sh                  # install current working tree (HEAD) into ~/.local/share/cc-statusline
#   ./install.sh --version vX.Y.Z # check out a specific tag, then install
#   ./install.sh --uninstall      # remove ~/.local/share/cc-statusline
#
# After install, prints the snippets to paste into ~/.claude/settings.json.

set -euo pipefail

INSTALL_DIR="${CC_STATUSLINE_PREFIX:-$HOME/.local/share/cc-statusline}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=""
UNINSTALL=0

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            [ -z "$VERSION" ] && { echo "error: --version requires a tag (e.g. v2.0.0)" >&2; exit 1; }
            shift 2
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [ "$UNINSTALL" -eq 1 ]; then
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        echo "Removed $INSTALL_DIR"
    else
        echo "Nothing to remove at $INSTALL_DIR"
    fi
    echo
    echo "Don't forget to remove the statusLine and hook entries from ~/.claude/settings.json"
    exit 0
fi

# Check we're in a git repo (so --version can work)
if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: $REPO_DIR is not a git checkout. Clone the repo first:" >&2
    echo "  git clone https://codeberg.org/vtmocanu/cc-statusline.git" >&2
    exit 1
fi

# Optional: check out a specific tag
if [ -n "$VERSION" ]; then
    if ! git -C "$REPO_DIR" rev-parse --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
        echo "error: tag $VERSION not found. Available tags:" >&2
        git -C "$REPO_DIR" tag -l | sed 's/^/  /' >&2
        exit 1
    fi
    echo "Checking out $VERSION..."
    git -C "$REPO_DIR" checkout "$VERSION"
fi

# Sanity-check required files
for f in statusline.sh claude-status-fetch.sh hooks/session-topic-capture.sh; do
    if [ ! -f "$REPO_DIR/$f" ]; then
        echo "error: missing required file: $f" >&2
        exit 1
    fi
done

# Sanity-check dependencies
missing=()
for cmd in bash jq perl; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
    echo "error: missing required commands: ${missing[*]}" >&2
    echo "  Install them and re-run the installer." >&2
    exit 1
fi

# Install
mkdir -p "$INSTALL_DIR/hooks"
install -m 0755 "$REPO_DIR/statusline.sh"               "$INSTALL_DIR/statusline.sh"
install -m 0755 "$REPO_DIR/claude-status-fetch.sh"      "$INSTALL_DIR/claude-status-fetch.sh"
install -m 0755 "$REPO_DIR/hooks/session-topic-capture.sh" "$INSTALL_DIR/hooks/session-topic-capture.sh"

# Record the installed version (best-effort)
INSTALLED_REF=$(git -C "$REPO_DIR" describe --tags --always 2>/dev/null || echo "unknown")
echo "$INSTALLED_REF" > "$INSTALL_DIR/.version"

cat <<EOF

Installed cc-statusline ($INSTALLED_REF) to: $INSTALL_DIR

Add the following to ~/.claude/settings.json:

  "statusLine": {
    "type": "command",
    "command": "bash $INSTALL_DIR/statusline.sh"
  }

To enable AI-generated session topics, also add this UserPromptSubmit hook:

  "hooks": {
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "$INSTALL_DIR/hooks/session-topic-capture.sh"
          }
        ]
      }
    ]
  }

To roll back to a previous version: ./install.sh --version v2.0.0
To uninstall:                       ./install.sh --uninstall
EOF
