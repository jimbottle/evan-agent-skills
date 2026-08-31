#!/usr/bin/env bash
# Installs the circle-back skill + Stop hook into ~/.claude
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude"
SETTINGS="$DEST/settings.json"

command -v jq >/dev/null 2>&1 || { echo "jq is required" >&2; exit 1; }

mkdir -p "$DEST/skills/circle-back" "$DEST/hooks" "$DEST/circle-back"
cp "$SRC/SKILL.md" "$DEST/skills/circle-back/SKILL.md"
cp "$SRC/hooks/circle-back.sh" "$DEST/hooks/circle-back.sh"
chmod +x "$DEST/hooks/circle-back.sh"

[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

if jq -e '[.hooks.Stop[]?.hooks[]?.command] | any(. == "~/.claude/hooks/circle-back.sh")' "$SETTINGS" >/dev/null; then
  echo "Stop hook already registered; settings.json left untouched (no backup written)."
else
  # Back up only when we are about to change settings, so the newest backup is
  # always the pre-install state and rollback can restore it safely.
  cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"
  jq '
    .hooks //= {} |
    .hooks.Stop //= [] |
    .hooks.Stop += [{
      hooks: [{
        type: "command",
        command: "~/.claude/hooks/circle-back.sh",
        timeout: 10
      }]
    }]
  ' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"
fi

echo "installed. hooks hot-reload in running sessions (check with /hooks); then try:"
echo "  /circle-back 60 summarize what we just changed"
