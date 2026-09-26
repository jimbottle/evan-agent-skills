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
# Queue file format, one entry per line:
#   <due_epoch_seconds><TAB><session_id><TAB><prompt>   (current)
#   <due_epoch_seconds><TAB><prompt>                    (legacy, untagged)
#
# Entries belong to the session that queued them. The queue file is keyed by
# directory, and OTHER Claude Code sessions run in the same directory -- a
# roborev reviewer (`claude -p`) finishing its review is a Stop too, and it
# used to drain the entry and answer the queued prompt in its review output
# (2026-09-24, louisville-open-data roborev job 4799). A tagged entry now fires
# only in its own session; a legacy untagged one only in an attended session.

set -uo pipefail

QUEUE_DIR="${CIRCLE_BACK_DIR:-$HOME/.claude/circle-back}"

command -v jq >/dev/null 2>&1 || exit 0

INPUT=$(cat)
CWD=$(jq -r '.cwd // empty' <<<"$INPUT")
[ -n "$CWD" ] || CWD="$PWD"
SID=$(jq -r '.session_id // empty' <<<"$INPUT")
[ -n "$SID" ] || SID="${CLAUDE_CODE_SESSION_ID:-}"
ATTENDED="${CLAUDE_CODE_SESSION_ATTENDED:-0}"

# An attended session adopts another session's due entry once that session is
# gone (/clear starts a new id; a closed or crashed terminal never stops
# again) -- otherwise its entries would never fire and never leave the file.
# Liveness comes from Claude Code's live-session registry, one
# <pid>.json per running session carrying its current sessionId. If the
# registry is missing, fall back to adopting entries ADOPT_AFTER seconds overdue.
SESSIONS_DIR="${CIRCLE_BACK_SESSIONS_DIR:-$HOME/.claude/sessions}"
ADOPT_AFTER="${CIRCLE_BACK_ADOPT_AFTER:-3600}"
case "$ADOPT_AFTER" in ''|*[!0-9]*) ADOPT_AFTER=3600 ;; esac
NOW=$(date +%s)

UUID_RE='^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'

# Session tag of an entry (field 2 when it is a UUID session id), else "".
entry_sid() {
  local rest=${1#*$'\t'}
  [ "$rest" != "$1" ] || return 0
  local f2=${rest%%$'\t'*}
  if [ "$f2" != "$rest" ] && [[ "$f2" =~ $UUID_RE ]]; then printf '%s' "$f2"; fi
}

# Running sessions per the registry, one session id per line: only files whose
# pid is alive and (when procStart is recorded) whose process started when the
# registry says -- a crashed session's pid can be reused. Parsed with jq, not
# grepped, so formatting changes can't hide a live session. Loaded lazily:
# only a foreign tagged entry needs it.
LIVE_SIDS=""; REG_LOADED=0; REG_OK=0; REG_BAD=0
load_registry() {
  [ "$REG_LOADED" = 1 ] && return; REG_LOADED=1
  [ -d "$SESSIONS_DIR" ] || return
  local f row pid sid pstart actual
  for f in "$SESSIONS_DIR"/*.json; do
    [ -f "$f" ] || continue
    # A file that won't parse (maybe caught mid-rewrite) could be a live
    # session's; don't read its absence as "gone" -- distrust the registry.
    row=$(jq -r '[(.pid // "" | tostring), (.sessionId // ""), (.procStart // "")] | @tsv' "$f" 2>/dev/null) \
      || { REG_BAD=1; continue; }
    IFS=$'\t' read -r pid sid pstart <<<"$row"
    case "$pid" in ''|*[!0-9]*) REG_BAD=1; continue ;; esac
    [ -n "$sid" ] || { REG_BAD=1; continue; }
    kill -0 "$pid" 2>/dev/null || continue
    if [ -n "$pstart" ]; then
      actual=$(TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//')
      [ "$actual" = "$(printf '%s' "$pstart" | tr -s ' ')" ] || continue
    fi
    LIVE_SIDS="$LIVE_SIDS$sid"$'\n'
  done
  # The registry is trusted only if it knows this session; otherwise its
  # format may have changed and "not listed" can't be read as "gone".
  [ "$REG_BAD" = 0 ] && [ -n "$SID" ] && grep -qxF "$SID" <<<"$LIVE_SIDS" && REG_OK=1
}

# Is the session with this id still running?  0 = live, 1 = gone, 2 = unknown.
owner_live() {
  load_registry
  [ "$REG_OK" = 1 ] || return 2
  grep -qxF "$1" <<<"$LIVE_SIDS" && return 0
  return 1
}

# May THIS session fire the entry?  eligible <line> <due>
eligible() {
  local tag rc
  tag=$(entry_sid "$1")
  [ -n "$tag" ] && [ -n "$SID" ] && [ "$tag" = "$SID" ] && return 0
  if [ -z "$tag" ]; then [ "$ATTENDED" = "1" ]; return; fi
  [ "$ATTENDED" = "1" ] || return 1
  owner_live "$tag"; rc=$?
  [ "$rc" -eq 1 ] && return 0
  [ "$rc" -eq 2 ] && [ $(( NOW - $2 )) -ge "$ADOPT_AFTER" ]
}

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

# Serialize select-and-remove: with adoption, two sessions stopping at once
# could otherwise both fire the same entry. flock(2) on fd 9, held until this
# script exits, so a killed hook can't leave a stale lock behind. Never wait (a
# Stop hook must not block): if it's held, skip -- a due entry fires next Stop.
# Stock macOS has no flock(1); perl's flock locks the same open file, which
# stays locked while this shell keeps fd 9 open.
# With neither available, leave the queue untouched: the rewrite below is a
# read-modify-write that would race unlocked. Say so if anything is due.
exec 9>>"$QUEUE.lock" || exit 0
if command -v flock >/dev/null 2>&1; then
  flock -n 9 || exit 0
elif command -v perl >/dev/null 2>&1; then
  perl -MFcntl=:flock -e 'open(my $f, ">&=", 9) or exit 2; flock($f, LOCK_EX|LOCK_NB) or exit 1' || exit 0
else
  DUE_N=0
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    D=${LINE%%$'\t'*}; case "$D" in ''|*[!0-9]*) D=0 ;; esac
    # Count only entries this session would fire; others aren't its to report.
    [ -n "$LINE" ] && [ "$D" -le "$NOW" ] && eligible "$LINE" "$D" && DUE_N=$((DUE_N+1))
  done < "$QUEUE"
  [ "$DUE_N" -gt 0 ] && jq -n --arg n "$DUE_N" --arg q "$QUEUE" \
    '{systemMessage:("circle-back: " + $n + " due entr(y/ies) not fired -- needs flock or perl to lock " + $q)}'
  exit 0
fi

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
  eligible "$LINE" "$DUE" || continue        # another session's entry: leave it
  if [ "$DUE" -le "$NOW" ] && { [ "$TARGET" -eq 0 ] || [ "$DUE" -lt "$BEST" ]; }; then
    TARGET=$N; BEST=$DUE
  fi
done < "$QUEUE"

# Nothing due yet: end the turn normally. This is the common case and is what
# keeps the session interactive while long entries are pending.
[ "$TARGET" -gt 0 ] || exit 0

ENTRY=$(sed -n "${TARGET}p" "$QUEUE")
PROMPT=${ENTRY#*$'\t'}
[ -z "$(entry_sid "$ENTRY")" ] || PROMPT=${PROMPT#*$'\t'}   # drop the session tag

TMP=$(mktemp) && sed "${TARGET}d" "$QUEUE" > "$TMP" && mv "$TMP" "$QUEUE"

# NOTE: we deliberately do not exit on .stop_hook_active. The queue is the loop
# guard -- every fire removes a line, so an N-entry queue produces at most N
# continuations and then drains to empty.
REMAINING=$(grep -c . "$QUEUE" 2>/dev/null || true)
[ -n "$REMAINING" ] || REMAINING=0
jq -n --arg p "$PROMPT" --arg n "$REMAINING" \
  '{decision:"block", reason:$p, systemMessage:("circle-back: fired, " + $n + " left in queue")}'
exit 0
