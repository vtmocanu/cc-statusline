#!/usr/bin/env bash
# Fetches Claude service status from status.claude.com and writes a cache file.
# Called by the statusline in the background when the cache is >60s old.
# Output file: per-user state dir (see _state_dir / CC_STATUSLINE_SVC_CACHE).
# Format: one line, one of:
#   operational
#   degraded_performance:<description>:<affected_components>
#   partial_outage:<description>:<affected_components>
#   major_outage:<description>:<affected_components>
#   incident:<incident_title>
# On a network or parse failure the cache is left untouched (no line written),
# so a transient error page never overwrites the last known-good status.
#
# The first token is what the statusline maps to an icon, so it must be one of
# the component severities above (degraded_performance/partial_outage/
# major_outage), NOT the page-level indicator (none/minor/major/critical) which
# the statusline cannot match. Severity is derived from the worst non-ignored
# component, independent of the page-level indicator (which a persistent
# always-on incident, e.g. a model suspension, keeps pinned to "minor").
#
# Incidents (and components) whose name matches CC_STATUSLINE_IGNORE_INCIDENTS
# (default "suspend.*(mythos|fable)", case-insensitive regex) are dropped before
# counting, so a long-lived suspension notice does not keep the alert icon lit
# forever. The default keys on the *suspension sentence*, not the bare model
# name, so a real future incident ("Elevated error rates on Fable 5") is still
# reported.

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

# CC_STATUSLINE_SVC_DATA points at a JSON fixture to use instead of hitting the
# network. Test-only seam (same spirit as CC_STATUSLINE_SVC_CACHE/FETCH/NOW); a
# missing/empty/unreadable file falls through to the empty-data guard below.
if [ -n "${CC_STATUSLINE_SVC_DATA:-}" ]; then
    data=$(cat "$CC_STATUSLINE_SVC_DATA" 2>/dev/null) || exit 0
else
    data=$(curl -s --max-time 8 \
        -H "Accept: application/json" \
        -H "User-Agent: cc-statusline/${VERSION}" \
        "https://status.claude.com/api/v2/summary.json" 2>/dev/null) || {
        # On network error, leave existing cache intact
        exit 0
    }
fi

[ -z "$data" ] && exit 0

# Incidents and components whose name matches this regex are ignored (see the
# header comment). Default keys on the suspension sentence, not the bare model
# name, so real future incidents for those models are still reported.
IGNORE_RE="${CC_STATUSLINE_IGNORE_INCIDENTS:-suspend.*(mythos|fable)}"

# Extract everything in a single jq call. The decision is derived from the
# *filtered* incidents and the worst *non-ignored* non-operational component,
# never from the page-level indicator (which a persistent ignored incident keeps
# pinned). Initialise first so a jq failure leaves the variables defined (and so
# SC2154 doesn't trip).
incident_count=0
incident_name="Incident"
worst=""
description=""
affected=""
# Capture jq's output (and exit status) BEFORE eval: `eval "$(...)"` reports
# eval's status, not jq's, so a jq failure here (non-JSON error page, or an
# invalid CC_STATUSLINE_IGNORE_INCIDENTS regex) must be detected on this line.
# On any failure or empty output we leave the existing cache intact and exit 0,
# exactly like the network-error path above, rather than writing a false
# "operational". jq always emits the @sh assignments for valid JSON, so empty
# output means a parse/regex failure.
#
# SECURITY: every value interpolated into an @sh string that is later eval'd
# MUST be a string scalar. @sh quotes a string safely, but for a JSON *array*
# it emits multiple space-separated shell tokens, so `eval` would run the tail
# as a command (RCE) on an attacker-controlled response body. `| tostring`
# collapses any non-string (array/number/object) to a single quoted token;
# `affected` is already coerced by `join`, and the name fields additionally sit
# behind `test()` (which throws on non-strings, failing the whole run closed).
parsed=$(echo "$data" | jq -r --arg ignore "$IGNORE_RE" '
    ( [ .incidents[]? | select((.name // "") | test($ignore; "i") | not) ] ) as $inc
  | ( [ .components[]?
        | select(.status != "operational")
        | select((.name // "") | test($ignore; "i") | not) ] ) as $comp
  | ( ["major_outage","partial_outage","degraded_performance"]
      | map(select(. as $s | $comp | any(.status == $s)))
      | first // "" ) as $worst
  | @sh "incident_count=\($inc | length)",
    @sh "incident_name=\(($inc[0].name // "Incident") | tostring)",
    @sh "worst=\($worst)",
    @sh "description=\((.status.description // "") | tostring)",
    @sh "affected=\([ $comp[].name ] | join(", "))"
' 2>/dev/null) || exit 0
[ -z "$parsed" ] && exit 0
eval "$parsed"

if [ "${incident_count:-0}" -gt 0 ] 2>/dev/null; then
    # Named, non-ignored incident takes priority over component severity.
    incident_name=$(printf '%s' "${incident_name:-Incident}" | cut -c1-50)
    echo "incident:${incident_name}" > "$TMP_FILE"
elif [ -n "${worst:-}" ]; then
    # Degraded/outage without a (non-ignored) named incident.
    affected=$(printf '%s' "${affected:-}" | cut -c1-60)
    echo "${worst}:${description}:${affected}" > "$TMP_FILE"
else
    echo "operational" > "$TMP_FILE"
fi

mv "$TMP_FILE" "$CACHE_FILE"
trap - EXIT  # disarm cleanup since mv succeeded
