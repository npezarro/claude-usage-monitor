#!/usr/bin/env bash
# check-usage.sh — Query Claude Max/Pro usage via the OAuth API.
#
# Reads your OAuth token from ~/.claude/.credentials.json (created by Claude Code)
# and queries the undocumented usage endpoint to get 5-hour and 7-day utilization.
#
# Usage:
#   ./check-usage.sh              # Check and output summary (uses cache if fresh)
#   ./check-usage.sh --json       # Output raw JSON
#   ./check-usage.sh --gate       # Exit 1 if any bucket >= threshold (for automation)
#   ./check-usage.sh --force      # Bypass cache and fetch fresh data
#   ./check-usage.sh --quiet      # Only output if over threshold
#
# Environment variables (all optional):
#   CLAUDE_USAGE_THRESHOLD  — Percentage to trigger warnings (default: 75)
#   CLAUDE_USAGE_CACHE_TTL  — Cache TTL in seconds (default: 300)
#   CLAUDE_CREDS_PATH       — Path to credentials file (default: ~/.claude/.credentials.json)
#   CLAUDE_USAGE_STATE_FILE — Path to cache file (default: ~/.cache/claude-usage-state.json)
#
# Exit codes:
#   0 — Usage is below threshold (or non-gate mode)
#   1 — Usage is at or above threshold (gate mode only)
#   2 — Error (no credentials, API failure, etc.)

set -uo pipefail

# ── Configuration ────────────────────────────────────────────────────

CREDS_PATH="${CLAUDE_CREDS_PATH:-$HOME/.claude/.credentials.json}"
STATE_FILE="${CLAUDE_USAGE_STATE_FILE:-$HOME/.cache/claude-usage-state.json}"
THRESHOLD="${CLAUDE_USAGE_THRESHOLD:-75}"
CACHE_TTL="${CLAUDE_USAGE_CACHE_TTL:-300}"
API_URL="https://api.anthropic.com/api/oauth/usage"
BETA_HEADER="oauth-2025-04-20"

mkdir -p "$(dirname "$STATE_FILE")"

# ── Parse flags ──────────────────────────────────────────────────────

MODE="summary"
FORCE=false
QUIET=false

for arg in "$@"; do
  case "$arg" in
    --json)   MODE="json" ;;
    --gate)   MODE="gate" ;;
    --force)  FORCE=true ;;
    --quiet)  QUIET=true ;;
    --help|-h)
      sed -n '2,/^$/p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
  esac
done

# ── Extract OAuth token ──────────────────────────────────────────────

if [ ! -f "$CREDS_PATH" ]; then
  echo "ERROR: No credentials file at $CREDS_PATH" >&2
  echo "Run 'claude' and log in first to create credentials." >&2
  exit 2
fi

ACCESS_TOKEN=$(python3 -c "
import json, sys
try:
    d = json.load(open('$CREDS_PATH'))
    token = d.get('claudeAiOauth', {}).get('accessToken', '')
    if not token:
        # Try flat structure
        token = d.get('accessToken', '')
    print(token)
except Exception as e:
    print('', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)

if [ -z "$ACCESS_TOKEN" ]; then
  echo "ERROR: Could not extract accessToken from $CREDS_PATH" >&2
  exit 2
fi

# ── Cache check ──────────────────────────────────────────────────────

use_cache() {
  [ "$FORCE" = true ] && return 1
  [ ! -f "$STATE_FILE" ] && return 1

  local cache_age
  cache_age=$(python3 -c "
import time, os
try:
    print(int(time.time() - os.path.getmtime('$STATE_FILE')))
except:
    print(9999)
" 2>/dev/null)

  [ "${cache_age:-9999}" -lt "$CACHE_TTL" ]
}

format_output() {
  local data="$1"
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
fh = d.get('five_hour', {})
sd = d.get('seven_day', {})
fh_pct = fh.get('utilization', 0) or 0
sd_pct = sd.get('utilization', 0) or 0
fh_reset = (fh.get('resets_at') or 'unknown')[:16]
sd_reset = (sd.get('resets_at') or 'unknown')[:16]
max_pct = max(fh_pct, sd_pct)
status = 'OK' if max_pct < $THRESHOLD else 'WARNING'
print(f'5h: {fh_pct}% (resets {fh_reset}) | 7d: {sd_pct}% (resets {sd_reset}) | Status: {status}')
" <<< "$data"
}

gate_check() {
  local data="$1"
  python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
fh = d.get('five_hour', {}).get('utilization', 0) or 0
sd = d.get('seven_day', {}).get('utilization', 0) or 0
max_pct = max(fh, sd)
if max_pct >= $THRESHOLD:
    bucket = '5h' if fh >= sd else '7d'
    reset = d.get('five_hour' if fh >= sd else 'seven_day', {}).get('resets_at', 'unknown')[:16]
    print(f'GATE BLOCKED: {bucket} at {max_pct}% (threshold {$THRESHOLD}%). Resets {reset}')
    sys.exit(1)
else:
    print(f'GATE OK: {max_pct}% (threshold {$THRESHOLD}%)')
    sys.exit(0)
" <<< "$data"
}

# ── Serve from cache if fresh ────────────────────────────────────────

if use_cache; then
  CACHED=$(cat "$STATE_FILE")
  case "$MODE" in
    json) echo "$CACHED" ;;
    gate)
      [ "$QUIET" = false ] && format_output "$CACHED"
      gate_check "$CACHED"
      exit $?
      ;;
    summary)
      if [ "$QUIET" = false ]; then
        format_output "$CACHED"
      else
        # In quiet mode, only output if over threshold
        python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
fh = d.get('five_hour', {}).get('utilization', 0) or 0
sd = d.get('seven_day', {}).get('utilization', 0) or 0
if max(fh, sd) >= $THRESHOLD:
    print(f'WARNING: Usage at {max(fh,sd)}%')
" <<< "$CACHED"
      fi
      ;;
  esac
  exit 0
fi

# ── Fetch from API ───────────────────────────────────────────────────

RESPONSE=$(curl -sf --max-time 10 \
  "$API_URL" \
  -H "Authorization: Bearer ${ACCESS_TOKEN}" \
  -H "anthropic-beta: ${BETA_HEADER}" 2>/dev/null)

if [ -z "$RESPONSE" ]; then
  echo "ERROR: Failed to fetch usage data (empty response)" >&2
  # Fall back to stale cache if available
  if [ -f "$STATE_FILE" ]; then
    echo "Using stale cache:" >&2
    format_output "$(cat "$STATE_FILE")"
  fi
  exit 2
fi

# Check for error in response
HAS_ERROR=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print('error' if 'error' in d else 'ok')
" <<< "$RESPONSE" 2>/dev/null)

if [ "$HAS_ERROR" = "error" ]; then
  ERROR_MSG=$(python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
print(d.get('error', {}).get('message', 'Unknown error'))
" <<< "$RESPONSE" 2>/dev/null)
  echo "ERROR: API returned: $ERROR_MSG" >&2
  exit 2
fi

# ── Write cache ──────────────────────────────────────────────────────

echo "$RESPONSE" > "$STATE_FILE"

# ── Output ───────────────────────────────────────────────────────────

case "$MODE" in
  json) echo "$RESPONSE" ;;
  gate)
    [ "$QUIET" = false ] && format_output "$RESPONSE"
    gate_check "$RESPONSE"
    exit $?
    ;;
  summary)
    if [ "$QUIET" = false ]; then
      format_output "$RESPONSE"
    else
      python3 -c "
import json, sys
d = json.loads(sys.stdin.read())
fh = d.get('five_hour', {}).get('utilization', 0) or 0
sd = d.get('seven_day', {}).get('utilization', 0) or 0
if max(fh, sd) >= $THRESHOLD:
    print(f'WARNING: Usage at {max(fh,sd)}%')
" <<< "$RESPONSE"
    fi
    ;;
esac
