#!/usr/bin/env bash
# Installs the amelignment skill by symlinking ~/.claude/skills/amelignment -> this dir
set -euo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LINK="$HOME/.claude/skills/amelignment"

mkdir -p "$HOME/.claude/skills"
if [ -L "$LINK" ]; then
  ln -sfn "$SRC" "$LINK"
elif [ -e "$LINK" ]; then
  echo "$LINK exists and is not a symlink; move it aside first" >&2
  exit 1
else
  ln -s "$SRC" "$LINK"
fi
echo "amelignment -> $LINK"
