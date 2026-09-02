#!/usr/bin/env bash
# Checks GitHub for the latest cc-statusline release and writes its tag to a
# cache file the statusline compares against its own VERSION (the line-1
# "⇡ X.Y.Z" update indicator, STATUSLINE_UPDATE_CHECK). Called by the
# statusline in the background, at most once an hour per user.
# Output file: per-user state dir (see _state_dir / CC_STATUSLINE_UPDATE_CACHE).
# Format: one line, the release tag exactly as GitHub reports it (e.g. v3.3.0).
#
# Source: the GitHub REST "latest release" endpoint (drafts and pre-releases are
# excluded by the API itself). It is unauthenticated (60 requests/hour/IP), which
# an hourly poll never approaches. The GitHub Release is created AFTER the tag
# push publishes the Homebrew formula (see CLAUDE.md's release recipe), so the
# indicator can never light up before `brew upgrade` can actually deliver.
#
# Fail closed: on a network error, a non-JSON body (rate-limit page, outage), a
# missing tag, or a tag that is not a plain v?MAJOR.MINOR.PATCH, the cache is
# left untouched and nothing is written. The tag ends up inside an OSC 8
# hyperlink on line 1, so the strict shape check here (repeated in the
# statusline) is what keeps an attacker-controlled response body from smuggling
# escape sequences into the terminal.

set -uo pipefail  # no -e: jq failures shouldn't leave orphan tmp files

# Per-user runtime dir (mode 700); matches the statusline's _state_dir so the
# default cache path agrees on both sides. The statusline also passes the
# resolved path via CC_STATUSLINE_UPDATE_CACHE when it spawns this fetcher,
# which takes precedence (and lets the test harness redirect it).
_state_dir() {
    local base="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}"
    local uid d
    uid=$(id -u 2>/dev/null || echo 0)
    d="${base%/}/cc-statusline-${uid}"
    mkdir -p "$d" 2>/dev/null && chmod 700 "$d" 2>/dev/null
    printf '%s' "$d"
}
# Single-sourced version for the User-Agent. Reads the tracked VERSION file
# shipped next to the install; "dev" if absent.
_cc_version() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
    { cat "$d/VERSION" "$d/../VERSION"; } 2>/dev/null | head -1
}
VERSION="$(_cc_version)"; VERSION="${VERSION:-dev}"

CACHE_FILE="${CC_STATUSLINE_UPDATE_CACHE:-$(_state_dir)/update-check}"
TMP_FILE="${CACHE_FILE}.tmp"

# Clean up tmp file on any exit (crash, signal, normal)
trap 'rm -f "$TMP_FILE"' EXIT

# CC_STATUSLINE_UPDATE_DATA points at a JSON fixture to use instead of hitting
# the network. Test-only seam (same spirit as CC_STATUSLINE_SVC_DATA); a
# missing/empty/unreadable file falls through to the empty-data guard below.
if [ -n "${CC_STATUSLINE_UPDATE_DATA:-}" ]; then
    data=$(cat "$CC_STATUSLINE_UPDATE_DATA" 2>/dev/null) || exit 0
else
    data=$(curl -s --max-time 8 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        -H "User-Agent: cc-statusline/${VERSION}" \
        "${CC_STATUSLINE_UPDATE_URL:-https://api.github.com/repos/vtmocanu/cc-statusline/releases/latest}" 2>/dev/null) || {
        # On network error, leave existing cache intact
        exit 0
    }
fi

[ -z "$data" ] && exit 0

# `// empty` turns a missing/null tag into no output; `tostring` collapses a
# non-string (array/object/number) into one token that the shape check below
# rejects, so nothing but a plain semver string ever reaches the cache.
tag=$(printf '%s' "$data" | jq -r '.tag_name // empty | tostring' 2>/dev/null) || exit 0
[ -z "$tag" ] && exit 0

# Strict shape: optional "v", three dot-separated numbers, nothing else (no
# pre-release suffix, no build metadata, no whitespace, no control bytes).
VER_RE='^v?[0-9]{1,4}\.[0-9]{1,4}\.[0-9]{1,4}$'
[[ "$tag" =~ $VER_RE ]] || exit 0

printf '%s\n' "$tag" > "$TMP_FILE" || exit 0
mv "$TMP_FILE" "$CACHE_FILE"
trap - EXIT  # disarm cleanup since mv succeeded
