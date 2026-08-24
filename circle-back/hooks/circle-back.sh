#!/usr/bin/env bash
# circle-back: Stop hook that fires queued prompts after a delay.
#
# Reads the Stop event JSON on stdin, pops the oldest queue entry, waits its
# delay, then hands the prompt back to Claude as the next instruction via
# {"decision":"block","reason":"<prompt>"}.
#
# Queue file format, one entry per line:  <delay_seconds><TAB><prompt>

set -uo pipefail

MAX_WAIT="${CIRCLE_BACK_MAX_WAIT:-1800}"   # clamp; must stay under the hook timeout
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

# NOTE: we deliberately do not exit on .stop_hook_active. The queue itself is
# the loop guard -- every fire removes a line, so an N-entry queue can produce
# at most N continuations and then drains to empty.

ENTRY=$(head -n 1 "$QUEUE")
DELAY=${ENTRY%%$'\t'*}
PROMPT=${ENTRY#*$'\t'}

case "$DELAY" in
  ''|*[!0-9]*) DELAY=0 ;;
esac
[ "$DELAY" -gt "$MAX_WAIT" ] && DELAY="$MAX_WAIT"

[ "$DELAY" -gt 0 ] && sleep "$DELAY"

# Pop after the wait, not before: if the hook is killed mid-sleep the entry
# survives and fires on the next turn instead of vanishing.
TMP=$(mktemp) && tail -n +2 "$QUEUE" > "$TMP" && mv "$TMP" "$QUEUE"

REMAINING=$(grep -c . "$QUEUE" 2>/dev/null || true)
[ -n "$REMAINING" ] || REMAINING=0
jq -n --arg p "$PROMPT" --arg d "$DELAY" --arg n "$REMAINING" \
  '{decision:"block", reason:$p, systemMessage:("circle-back: fired after " + $d + "s, " + $n + " left in queue")}'
exit 0
