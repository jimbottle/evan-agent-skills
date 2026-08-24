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
cp "$SETTINGS" "$SETTINGS.bak.$(date +%s)"

# Append the Stop hook without disturbing existing hooks.
jq '
  .hooks //= {} |
  .hooks.Stop //= [] |
  if [.hooks.Stop[]?.hooks[]?.command] | any(. == "~/.claude/hooks/circle-back.sh")
  then .
  else .hooks.Stop += [{
    hooks: [{
      type: "command",
      command: "~/.claude/hooks/circle-back.sh",
      timeout: 1810
    }]
  }]
  end
' "$SETTINGS" > "$SETTINGS.tmp" && mv "$SETTINGS.tmp" "$SETTINGS"

echo "installed. restart Claude Code, then try:"
echo "  /circle-back 60 summarize what we just changed"
