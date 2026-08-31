#!/usr/bin/env bash
# circle-back: Stop hook that fires queued prompts once they come due.
#
# Reads the Stop event JSON on stdin, finds the oldest entry whose due time has
# passed, and hands its prompt back to Claude as the next instruction via
# {"decision":"block","reason":"<prompt>"}.
#
# This hook NEVER sleeps, and must not be changed to. Stop hooks run
# synchronously -- Claude Code blocks the session until they return -- so a
# hook that sleeps for the delay freezes the entire session for that long. An
# earlier version did exactly that and made `/circle-back 1800` a 30-minute
# lockup. Instead each entry carries an absolute due timestamp; when nothing is
# due the hook exits in milliseconds and the turn ends normally.
#
# Queue file format, one entry per line:  <due_epoch_seconds><TAB><prompt>

set -uo pipefail

QUEUE_DIR="${CIRCLE_BACK_DIR:-$HOME/.claude/circle-back}"

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CWD=$(jq -r '.cwd // empty' <<<"$INPUT")
[ -n "$CWD" ] || CWD="$PWD"

# Queue is scoped per working directory so parallel sessions in different
# repos don't drain each other's prompts. Override with CIRCLE_BACK_QUEUE.
if [ -n "${CIRCLE_BACK_QUEUE:-}" ]; then
  QUEUE="$CIRCLE_BACK_QUEUE"
else
  KEY=$(printf '%s' "$CWD" | shasum -a 256 2>/dev/null | cut -c1-12) \
    || KEY=$(printf '%s' "$CWD" | sha256sum | cut -c1-12)
  QUEUE="$QUEUE_DIR/$KEY.queue"
fi

# Nothing queued: allow the turn to end normally.
[ -s "$QUEUE" ] || exit 0

NOW=$(date +%s)

# Find the due entry with the earliest due time (ties: earliest in file). A
# not-yet-due entry does not block a later one that is due, so a 30s follow-up
# queued behind a 2h one still fires on time -- and a due entry queued *after*
# a later-due one does not jump ahead of it.
TARGET=0
BEST=0
N=0
while IFS= read -r LINE || [ -n "$LINE" ]; do
  N=$((N+1))
  [ -n "$LINE" ] || continue
  DUE=${LINE%%$'\t'*}
  case "$DUE" in ''|*[!0-9]*) DUE=0 ;; esac   # malformed -> due immediately
  if [ "$DUE" -le "$NOW" ] && { [ "$TARGET" -eq 0 ] || [ "$DUE" -lt "$BEST" ]; }; then
    TARGET=$N; BEST=$DUE
  fi
done < "$QUEUE"

# Nothing due yet: end the turn normally. This is the common case and is what
# keeps the session interactive while long entries are pending.
[ "$TARGET" -gt 0 ] || exit 0

ENTRY=$(sed -n "${TARGET}p" "$QUEUE")
PROMPT=${ENTRY#*$'\t'}

TMP=$(mktemp) && sed "${TARGET}d" "$QUEUE" > "$TMP" && mv "$TMP" "$QUEUE"

# NOTE: we deliberately do not exit on .stop_hook_active. The queue is the loop
# guard -- every fire removes a line, so an N-entry queue produces at most N
# continuations and then drains to empty.
REMAINING=$(grep -c . "$QUEUE" 2>/dev/null || true)
[ -n "$REMAINING" ] || REMAINING=0
jq -n --arg p "$PROMPT" --arg n "$REMAINING" \
  '{decision:"block", reason:$p, systemMessage:("circle-back: fired, " + $n + " left in queue")}'
exit 0
