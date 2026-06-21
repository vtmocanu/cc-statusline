#!/usr/bin/env bash
# Fetches Claude service status from status.claude.com and writes a cache file.
# Called by the statusline in the background when the cache is >60s old.
# Output file: /tmp/claude-service-status
# Format: one line, either:
#   operational
#   degraded_performance:<indicator>:<affected_components>
#   partial_outage:<indicator>:<affected_components>
#   major_outage:<indicator>:<affected_components>
#   incident:<incident_title>
#   unknown

set -uo pipefail  # no -e: jq failures shouldn't leave orphan tmp files

# Per-user runtime dir (mode 700); matches the statusline's _state_dir so the
# default cache path agrees on both sides. The statusline also passes the
# resolved path via CC_STATUSLINE_SVC_CACHE when it spawns this fetcher, which
# takes precedence (and lets the test harness redirect it to a scratch dir).
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

CACHE_FILE="${CC_STATUSLINE_SVC_CACHE:-$(_state_dir)/service-status}"
TMP_FILE="${CACHE_FILE}.tmp"

# Clean up tmp file on any exit (crash, signal, normal)
trap 'rm -f "$TMP_FILE"' EXIT

data=$(curl -s --max-time 8 \
    -H "Accept: application/json" \
    -H "User-Agent: cc-statusline/${VERSION}" \
    "https://status.claude.com/api/v2/summary.json" 2>/dev/null) || {
    # On network error, leave existing cache intact
    exit 0
}

[ -z "$data" ] && exit 0

# Extract all fields in a single jq call. Initialise first so a jq failure
# leaves the variables defined (and so shellcheck SC2154 doesn't trip).
indicator="unknown"
description=""
incident_count=0
incident_name="Incident"
eval "$(echo "$data" | jq -r '
    @sh "indicator=\(.status.indicator // "unknown")",
    @sh "description=\(.status.description // "")",
    @sh "incident_count=\(.incidents | length)",
    @sh "incident_name=\(.incidents[0].name // "Incident")"
' 2>/dev/null)" || exit 0

if [ "${indicator:-unknown}" = "none" ] && [ "${incident_count:-0}" -eq 0 ] 2>/dev/null; then
    echo "operational" > "$TMP_FILE"
else
    if [ "${incident_count:-0}" -gt 0 ] 2>/dev/null; then
        # Truncate long names
        incident_name=$(echo "${incident_name:-Incident}" | cut -c1-50)
        echo "incident:${incident_name}" > "$TMP_FILE"
    else
        # Degraded or outage without a named incident
        affected=$(echo "$data" | jq -r '
            [.components[]
             | select(.status != "operational")
             | .name
            ] | join(", ")' 2>/dev/null || echo "")
        affected=$(echo "$affected" | cut -c1-60)
        echo "${indicator}:${description}:${affected}" > "$TMP_FILE"
    fi
fi

mv "$TMP_FILE" "$CACHE_FILE"
trap - EXIT  # disarm cleanup since mv succeeded
