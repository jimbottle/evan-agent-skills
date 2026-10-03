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
#   after:<queued_epoch><TAB><session_id><TAB><prompt>  (fires after the task ahead of it)
#   after+<delay>:<queued_epoch><TAB><session_id><TAB><prompt>
#                                                       (timer of <delay> seconds that starts
#                                                        when the task ahead of it finishes)
#   <due_epoch_seconds><TAB><prompt>                    (legacy, untagged)
#
# An `after` entry has no due time. It waits for every entry ahead of it in
# the file that this session may fire -- due or not -- and comes due the
# moment none is left, i.e. at the Stop that ends the turn the last of them
# ran in. With nothing ahead of it, that is the end of the current turn. The
# epoch after the colon is when it was queued; it only matters for adopting an
# orphan when the owner's liveness is unknown (a bare `after` is also accepted,
# and is then never adopted).
#
# An `after+<delay>` entry is an `after` entry whose timer has not started
# yet. The moment it would otherwise fire, the hook instead rewrites it in
# place as a timed entry due <delay> seconds from now and blocks with the
# wake-up prompt for it (the same prompt the skill gives CronCreate), so the
# agent's next turn is the wake-up: it waits out the delay or schedules a cron
# wake-up, ends the turn, and the entry fires like any other timed one. The
# wake-up turn goes before anything queued behind the entry, as a plain
# `after` would.
#
# A timed entry's clock is the built-in CronCreate scheduler: the skill also
# schedules a one-shot wake-up prompt at the due minute, whose only job is to
# end a turn so this hook runs. The hook knows nothing about cron; if a turn
# ends after the due time before the wake-up arrives, the entry fires then and
# the wake-up is a no-op. Keeping timers in the queue is what lets an `after`
# entry chain onto one.
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

# Format an epoch: BSD `date -r`, else GNU `date -d @`.
fmt_date() { date -r "$1" "$2" 2>/dev/null || date -d "@$1" "$2"; }

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

# May THIS session fire the entry?  eligible <line> <ref_epoch>
# ref_epoch is the due time, or for an `after` entry the time it was queued
# (empty when unknown).
eligible() {
  local tag rc
  tag=$(entry_sid "$1")
  [ -n "$tag" ] && [ -n "$SID" ] && [ "$tag" = "$SID" ] && return 0
  if [ -z "$tag" ]; then [ "$ATTENDED" = "1" ]; return; fi
  [ "$ATTENDED" = "1" ] || return 1
  owner_live "$tag"; rc=$?
  [ "$rc" -eq 1 ] && return 0
  # Unknown liveness: adopt only once ADOPT_AFTER has passed since the reference time.
  [ "$rc" -eq 2 ] && [ -n "$2" ] && [ $(( NOW - $2 )) -ge "$ADOPT_AFTER" ]
}

# Scan the queue once. Sets TARGET (line number of the entry to fire, 0 if
# none), BEST (its due time) and DUE_N (how many entries this session could
# fire right now). Picks the due entry with the earliest due time (ties:
# earliest in file). A not-yet-due entry does not block a later one that is
# due, so a 30s follow-up queued behind a 2h one still fires on time -- and a
# due entry queued *after* a later-due one does not jump ahead of it. The one
# exception is an `after` entry: it waits for everything ahead of it that this
# session may fire, and once unblocked counts as due since forever (due 0), so
# it goes before anything queued behind it.
scan() {
  local LINE DUE AFTER REF DELAY AHEAD=0
  TARGET=0; BEST=0; DUE_N=0; N=0; CONVERT=0; CONV_DELAY=0
  while IFS= read -r LINE || [ -n "$LINE" ]; do
    N=$((N+1))
    [ -n "$LINE" ] || continue
    DUE=${LINE%%$'\t'*}
    AFTER=0; DELAY=0
    case "$DUE" in
      after|after:*|after+*)
        AFTER=1; REF=${DUE#after}; DUE=0
        case "$REF" in
          +*) DELAY=${REF#+}; DELAY=${DELAY%%:*}
              case "$REF" in *:*) REF=${REF#*:} ;; *) REF= ;; esac   # ":<queued>" is optional
              case "$DELAY" in ''|*[!0-9]*) DELAY=0 ;; esac ;;
        esac
        REF=${REF#:}
        case "$REF" in *[!0-9]*) REF= ;; esac ;;
      ''|*[!0-9]*) DUE=0; REF=0 ;;              # malformed -> due immediately
      *) REF=$DUE ;;
    esac
    eligible "$LINE" "$REF" || continue          # another session's entry: leave it
    if [ "$AFTER" = 1 ] && [ "$AHEAD" = 1 ]; then continue; fi  # waits for what is ahead
    AHEAD=1
    # An after+<delay> entry that just came unblocked: its timer starts now.
    # Not due yet -- it is rewritten as a timed entry below, after the scan.
    if [ "$AFTER" = 1 ] && [ "$DELAY" -gt 0 ]; then CONVERT=$N; CONV_DELAY=$DELAY; continue; fi
    [ "$DUE" -le "$NOW" ] || continue
    DUE_N=$((DUE_N+1))
    if [ "$TARGET" -eq 0 ] || [ "$DUE" -lt "$BEST" ]; then TARGET=$N; BEST=$DUE; fi
  done < "$QUEUE"
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
  # Count only entries this session would fire; others aren't its to report.
  scan
  [ "$CONVERT" -gt 0 ] && DUE_N=$((DUE_N+1))   # its timer can't start without the lock either
  [ "$DUE_N" -gt 0 ] && jq -n --arg n "$DUE_N" --arg q "$QUEUE" \
    '{systemMessage:("circle-back: " + $n + " due entr(y/ies) not fired -- needs flock or perl to lock " + $q)}'
  exit 0
fi

scan

# An after+<delay> entry came unblocked at this Stop: start its timer. Rewrite
# it in place as a timed entry due <delay> seconds from now, tagged to this
# session (it owns the wake-up from here on), and make the next turn the
# wake-up turn by blocking with the same wake-up prompt the skill hands to
# CronCreate. This goes before any other due entry, as a plain `after` would;
# that entry fires at the end of the wake-up turn.
if [ "$CONVERT" -gt 0 ]; then
  ENTRY=$(sed -n "${CONVERT}p" "$QUEUE")
  TAG=$(entry_sid "$ENTRY")
  PROMPT=${ENTRY#*$'\t'}
  [ -z "$TAG" ] || PROMPT=${PROMPT#*$'\t'}
  [ -n "$SID" ] && TAG=$SID
  DUE=$(( NOW + CONV_DELAY ))
  TMP=$(mktemp) && {
    [ "$CONVERT" -le 1 ] || head -n $((CONVERT-1)) "$QUEUE"
    if [ -n "$TAG" ]; then printf '%s\t%s\t%s\n' "$DUE" "$TAG" "$PROMPT"
    else printf '%s\t%s\n' "$DUE" "$PROMPT"; fi
    tail -n +$((CONVERT+1)) "$QUEUE"
  } > "$TMP" && mv "$TMP" "$QUEUE"
  # Wake-up minute: the due time rounded up to a whole minute, at least a
  # minute out (the agent needs time to schedule it), and never :00 or :30,
  # where one-shots can arrive up to 90 s early.
  T=$(( NOW + 60 )); [ "$T" -ge "$DUE" ] || T=$DUE
  T=$(( (T + 59) / 60 * 60 ))
  case "$(fmt_date "$T" +%M)" in 00|30) T=$(( T + 60 )) ;; esac
  CRON=$(fmt_date "$T" '+%M %H %d %m' | awk '{print $1+0, $2+0, $3+0, $4+0, "*"}')
  FEW=$(printf '%s' "$PROMPT" | awk '{n=(NF>6?6:NF); s=$1; for(i=2;i<=n;i++) s=s" "$i; if(NF>6) s=s"..."; print s}')
  WAKE="circle-back wake-up for the entry due at $(fmt_date "$DUE" +%H:%M:%S) (epoch $DUE): \"$FEW\". Its ${CONV_DELAY}s timer started just now, when the work ahead of it finished. Do nothing else this turn. If \`date +%s\` is still before $DUE, wait out the remaining seconds (a Bash \`sleep\`, or a Monitor until-loop on \`date +%s\`). If you cannot wait, CronCreate this same prompt (\`recurring: false\`) at \`$CRON\`, or once that minute has passed, at the expression printed by \`N=\$(date +%s); T=\$(( ((N+60>$DUE?N+60:$DUE)+59)/60*60 )); case \$(date -r \$T +%M) in 00|30) T=\$((T+60));; esac; date -r \$T '+%M %H %d %m' | awk '{print \$1+0,\$2+0,\$3+0,\$4+0,\"*\"}'\`. Then end the turn with one short line. The Stop hook delivers the queued prompt."
  REMAINING=$(grep -c . "$QUEUE" 2>/dev/null || true)
  [ -n "$REMAINING" ] || REMAINING=0
  jq -n --arg p "$WAKE" --arg t "$(fmt_date "$DUE" +%H:%M:%S)" --arg n "$REMAINING" \
    '{decision:"block", reason:$p, systemMessage:("circle-back: timer started, entry due at " + $t + "; " + $n + " in queue")}'
  exit 0
fi

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
