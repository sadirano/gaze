#!/usr/bin/env bash
# Render a representative payload through the built binary, so a change to the
# line can be looked at rather than reasoned about. Prints once in colour and
# once stripped, since the stripped form is what parity tests compare.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
exe="$here/zig-out/bin/gaze.exe"
[[ -x "$exe" ]] || { echo "not built: $exe" >&2; exit 1; }

payload=$(cat <<'JSON'
{
  "session_id": "6f1d99af-97e6-4490-beb3-2b40d6429a1e",
  "cwd": "REPLACED",
  "model": { "display_name": "Opus 5" },
  "rate_limits": {
    "five_hour": { "used_percentage": 42, "resets_at": 0 },
    "seven_day": { "used_percentage": 88, "resets_at": 0 }
  },
  "context_window": {
    "used_percentage": 37,
    "current_usage": {
      "cache_read_input_tokens": 1240000,
      "cache_creation_input_tokens": 31000
    }
  },
  "cost": {
    "total_cost_usd": 1.4237,
    "total_lines_added": 142,
    "total_lines_removed": 37,
    "total_duration_ms": 4530000
  }
}
JSON
)
payload=${payload/REPLACED/$(echo "$here" | sed 's#/#\\\\#g')}

echo "--- as rendered ---"
printf '%s' "$payload" | "$exe"
echo "--- stripped ---"
printf '%s' "$payload" | "$exe" | sed 's/\x1b\[[0-9;]*m//g'
