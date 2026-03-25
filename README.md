# claude-usage-monitor

Check your Claude Max/Pro usage programmatically from the command line.

Uses the undocumented OAuth usage endpoint (`api.anthropic.com/api/oauth/usage`) with the `anthropic-beta: oauth-2025-04-20` header to get real-time utilization percentages for your 5-hour and 7-day rolling windows.

## Requirements

- Claude Code installed and logged in (`~/.claude/.credentials.json` must exist)
- Python 3
- curl
- bash

## Installation

```bash
git clone https://github.com/npezarro/claude-usage-monitor.git
chmod +x claude-usage-monitor/check-usage.sh
```

Or just copy `check-usage.sh` anywhere on your `$PATH`.

## Usage

```bash
# Basic usage — shows current utilization
./check-usage.sh
# 5h: 63.0% (resets 2026-03-26T02:00) | 7d: 71.0% (resets 2026-03-27T20:00) | Status: OK

# Raw JSON output
./check-usage.sh --json

# Gate mode — exits 1 if any bucket >= threshold (default 75%)
./check-usage.sh --gate

# Force fresh fetch (bypass 5-min cache)
./check-usage.sh --force

# Quiet mode — only outputs if over threshold
./check-usage.sh --quiet
```

## Gate Mode (for automation)

Use `--gate` to block operations when usage is high:

```bash
if ./check-usage.sh --gate; then
  echo "Usage OK, proceeding..."
  # spawn agents, run tasks, etc.
else
  echo "Usage too high, pausing."
fi
```

## Configuration

All configuration is via environment variables (all optional):

| Variable | Default | Description |
|----------|---------|-------------|
| `CLAUDE_USAGE_THRESHOLD` | `75` | Percentage to trigger warnings/gate blocks |
| `CLAUDE_USAGE_CACHE_TTL` | `300` | Cache TTL in seconds |
| `CLAUDE_CREDS_PATH` | `~/.claude/.credentials.json` | Path to Claude Code credentials |
| `CLAUDE_USAGE_STATE_FILE` | `~/.cache/claude-usage-state.json` | Path to cache file |

## API Response

The endpoint returns:

```json
{
  "five_hour": {
    "utilization": 63.0,
    "resets_at": "2026-03-26T02:00:00.000000+00:00"
  },
  "seven_day": {
    "utilization": 71.0,
    "resets_at": "2026-03-27T20:00:00.000000+00:00"
  },
  "seven_day_sonnet": {
    "utilization": 2.0,
    "resets_at": "2026-03-28T20:00:00.000000+00:00"
  }
}
```

## Rate Limits

The OAuth usage endpoint has a hard rate limit of ~5 requests per access token window. The script caches results for 5 minutes by default to avoid hitting this. Don't poll more frequently than every few minutes.

## Integration Examples

### Claude Code Hook (SessionStart)

Show usage at the start of every Claude Code session:

```json
{
  "hooks": {
    "SessionStart": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "/path/to/check-usage.sh --quiet",
            "timeout": 12000
          }
        ]
      }
    ]
  }
}
```

### Cron-based monitoring

```bash
# Check every 15 minutes, log warnings
*/15 * * * * /path/to/check-usage.sh --quiet >> /var/log/claude-usage.log 2>&1
```

### Pre-flight check for agent teams

```bash
# In your agent orchestration script
if ! /path/to/check-usage.sh --gate 2>/dev/null; then
  echo "Usage too high, skipping this run"
  exit 0
fi
```

## How It Works

1. Reads the OAuth access token from `~/.claude/.credentials.json` (created when you log into Claude Code)
2. Calls `GET https://api.anthropic.com/api/oauth/usage` with `Authorization: Bearer <token>` and the required `anthropic-beta: oauth-2025-04-20` header
3. Caches the response to `~/.cache/claude-usage-state.json`
4. Parses and displays utilization percentages

## Troubleshooting

**"OAuth authentication is currently not supported"** — You're missing the `anthropic-beta: oauth-2025-04-20` header. The script includes this automatically.

**"429 Too Many Requests"** — You've hit the rate limit. Wait a few minutes. Increase `CLAUDE_USAGE_CACHE_TTL` to poll less frequently.

**"No credentials file"** — Run `claude` and log in first. The credentials file is created automatically.

## License

MIT
