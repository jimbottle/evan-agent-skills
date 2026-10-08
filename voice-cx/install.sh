#!/usr/bin/env bash
# Installs the voice-cx skill by SYMLINK, so ~/.claude/skills/voice-cx always
# runs this checkout: edits here are live in every repo that uses the skill,
# and consuming repos can call ~/.claude/skills/voice-cx/cx.py by a fixed path.
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST="$HOME/.claude/skills/voice-cx"

mkdir -p "$HOME/.claude/skills"
if [ -L "$DEST" ]; then
  ln -sfn "$SRC" "$DEST"
elif [ -e "$DEST" ]; then
  echo "$DEST exists and is not a symlink; move it aside first" >&2
  exit 1
else
  ln -s "$SRC" "$DEST"
fi
echo "installed: $DEST -> $SRC"
echo "try: python3 $DEST/cx.py --help"
