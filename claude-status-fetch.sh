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

CACHE_FILE="/tmp/claude-service-status"
TMP_FILE="${CACHE_FILE}.tmp"

# Clean up tmp file on any exit (crash, signal, normal)
trap 'rm -f "$TMP_FILE"' EXIT

data=$(curl -s --max-time 8 \
    -H "Accept: application/json" \
    -H "User-Agent: claude-code-statusline/1.0" \
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
