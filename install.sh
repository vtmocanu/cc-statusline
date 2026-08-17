#!/usr/bin/env bash
# cc-statusline installer
#
# Usage:
#   ./install.sh                  install HEAD into ~/.local/share/cc-statusline
#   ./install.sh --version vX.Y.Z install a specific tag (without mutating your clone)
#   ./install.sh --uninstall      remove ~/.local/share/cc-statusline
#   ./install.sh --help           show this help
#
# Environment:
#   CC_STATUSLINE_PREFIX  override the install prefix (default: ~/.local/share/cc-statusline)
#
# After install, prints the JSON snippets to paste into ~/.claude/settings.json.

set -euo pipefail

INSTALL_DIR="${CC_STATUSLINE_PREFIX:-$HOME/.local/share/cc-statusline}"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION=""
UNINSTALL=0

err()  { printf 'error: %s\n' "$*" >&2; }
info() { printf '%s\n' "$*"; }

while [ $# -gt 0 ]; do
    case "$1" in
        --version)
            VERSION="${2:-}"
            [ -z "$VERSION" ] && { err "--version requires a tag (e.g. v2.0.0)"; exit 1; }
            shift 2
            ;;
        --uninstall)
            UNINSTALL=1
            shift
            ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            err "unknown argument: $1"
            exit 1
            ;;
    esac
done

if [ "$UNINSTALL" -eq 1 ]; then
    if [ -d "$INSTALL_DIR" ]; then
        rm -rf "$INSTALL_DIR"
        info "Removed $INSTALL_DIR"
    else
        info "Nothing to remove at $INSTALL_DIR"
    fi
    info ""
    info "Don't forget to remove the statusLine and hook entries from ~/.claude/settings.json"
    exit 0
fi

# Check we're in a git checkout
if ! git -C "$REPO_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    err "$REPO_DIR is not a git checkout. Clone the repo first:"
    err "  git clone https://github.com/vtmocanu/cc-statusline.git"
    exit 1
fi

# Sanity-check dependencies (statusline + hook). perl handles all ANSI/control
# stripping now, so there is no gsed/gnu-sed requirement on macOS anymore.
missing=()
for cmd in bash jq perl curl timeout; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
if [ ${#missing[@]} -gt 0 ]; then
    err "missing required commands: ${missing[*]}"
    err "  Install them and re-run the installer."
    exit 1
fi

# Resolve which ref we're installing without mutating the working tree:
#   --version vX.Y.Z  -> use that tag (must exist locally)
#   default           -> use current HEAD
if [ -n "$VERSION" ]; then
    if ! git -C "$REPO_DIR" rev-parse --verify "refs/tags/$VERSION" >/dev/null 2>&1; then
        err "tag $VERSION not found. Available tags:"
        git -C "$REPO_DIR" tag -l | sed 's/^/  /' >&2
        err "Run 'git fetch --tags' if you expect a newer tag."
        exit 1
    fi
    REF="$VERSION"
    INSTALLED_REF="$VERSION"
else
    REF="HEAD"
    INSTALLED_REF=$(git -C "$REPO_DIR" describe --tags --always --dirty 2>/dev/null || echo "HEAD")
fi

# Compare against any existing install for an idempotency hint
PREV_REF=""
[ -f "$INSTALL_DIR/.version" ] && PREV_REF=$(cat "$INSTALL_DIR/.version" 2>/dev/null || true)

# Stage the chosen ref into a temp dir via `git archive` (no working-tree mutation).
STAGE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/cc-statusline-install.XXXXXX")
trap 'rm -rf "$STAGE_DIR"' EXIT

if ! git -C "$REPO_DIR" archive --format=tar "$REF" | tar -x -C "$STAGE_DIR"; then
    err "git archive failed for ref $REF"
    exit 1
fi

# Sanity-check required files in the staged tree
for f in statusline.sh claude-status-fetch.sh claude-usage-fetch.sh; do
    if [ ! -f "$STAGE_DIR/$f" ]; then
        err "staged tree missing required file: $f"
        exit 1
    fi
done

# Install from the staged tree
mkdir -p "$INSTALL_DIR"
install -m 0755 "$STAGE_DIR/statusline.sh"          "$INSTALL_DIR/statusline.sh"
install -m 0755 "$STAGE_DIR/claude-status-fetch.sh" "$INSTALL_DIR/claude-status-fetch.sh"
install -m 0755 "$STAGE_DIR/claude-usage-fetch.sh"  "$INSTALL_DIR/claude-usage-fetch.sh"
# VERSION is the human semver used in the scripts' User-Agent. Absent in tags
# that predate it (the scripts then fall back to "dev"), so guard the copy.
[ -f "$STAGE_DIR/VERSION" ] && install -m 0644 "$STAGE_DIR/VERSION" "$INSTALL_DIR/VERSION"
printf '%s\n' "$INSTALLED_REF" > "$INSTALL_DIR/.version"

if [ -n "$PREV_REF" ] && [ "$PREV_REF" != "$INSTALLED_REF" ]; then
    info "Upgraded cc-statusline: $PREV_REF -> $INSTALLED_REF"
elif [ -n "$PREV_REF" ]; then
    info "Re-installed cc-statusline ($INSTALLED_REF, unchanged from previous)"
else
    info "Installed cc-statusline ($INSTALLED_REF) to: $INSTALL_DIR"
fi

cat <<EOF

Add the following to ~/.claude/settings.json:

  "statusLine": {
    "type": "command",
    "command": "bash $INSTALL_DIR/statusline.sh",
    "refreshInterval": 60
  }

refreshInterval re-runs the statusline every N seconds so idle sessions keep
fresh reset times, service health, and rate-limit bars (requires a recent
Claude Code). Remove the line to update only on activity.

The descriptive session title on line 1 comes from Claude Code's native session
name (its /rename value or auto-generated title). No hook or extra setup is
needed; hide it with STATUSLINE_TOPIC=0, and the @handle with
STATUSLINE_SESSION_NAME=0.

To roll back to a previous version: ./install.sh --version v2.0.0
To uninstall:                       ./install.sh --uninstall
EOF
