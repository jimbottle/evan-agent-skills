---
name: circle-back
argument-hint: <seconds|after> <prompt>
description: Queue a follow-up prompt to be sent automatically once a delay has elapsed or once the previous task completes, without interrupting work in progress. Use this whenever the user says "circle around", "circle back", "queue this for later", "come back to this in X minutes", "after this is done, also...", "then do X" (right after queuing something else), or otherwise wants a prompt held and fired later rather than acted on now — including when the queued prompt is unrelated to whatever is currently in flight.
---

# circle-back

Hold a prompt and send it later. Every entry lives in one queue file, in the
order it should run, and the `circle-back.sh` Stop hook fires the next due
entry when a turn ends. There are two ways an entry comes due:

- **A clock (`<seconds>`).** The entry carries an absolute due time. Because
  the hook only runs when a turn *ends*, a session sitting idle at the prompt
  would never notice the due time passing, so a one-shot `CronCreate` job is
  scheduled for the due minute whose only job is to send a short wake-up
  prompt. That wake-up ends a turn, the hook sees the entry is due, and the
  real prompt goes out. If the session is busy at the due time, the entry
  fires at the next turn end anyway and the wake-up, arriving later, is a
  no-op.
- **The previous task finishing (`after`).** The entry has no due time. It
  waits for every entry ahead of it in the queue, timed or not, and fires at
  the end of the turn in which the last of them ran. With nothing ahead of it,
  that is the end of the work in flight right now.

Because timers and `after` entries share one queue, they stack: a timer with a
command, then an `after` behind it, runs the timer's prompt at its due time and
the `after` prompt when that turn ends.

## Adding an entry

Invocation looks like `/circle-back <seconds> <prompt>`. Claude Code hands the
arguments to you as a trailing `ARGUMENTS: <seconds|after> <prompt>` line.
The first token is either the delay in seconds or the word `after`; everything
after it is the prompt, verbatim.

### Delay greater than 0: queue entry plus a cron wake-up

Every entry goes in the queue. Append it with its due time and, in the same
Bash call (shell variables do not survive between calls), print what the
wake-up needs: the due epoch, its clock time, and the cron expression. The
wake-up minute is the due time rounded **up** to a whole minute, pushed one
more minute when that lands on :00 or :30, since one-shots at those marks can
arrive up to 90 s early.

```bash
Q="${CIRCLE_BACK_QUEUE:-$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue}"
mkdir -p "$(dirname "$Q")"
DUE=$(( $(date +%s) + SECONDS_ARG ))
printf '%s\t%s\t%s\n' "$DUE" "${CLAUDE_CODE_SESSION_ID:?no session id}" "$PROMPT_ARG" >> "$Q"
T=$(( (DUE + 59) / 60 * 60 ))
case $(date -r "$T" +%M) in 00|30) T=$(( T + 60 )) ;; esac
echo "due=$DUE at $(date -r "$DUE" +%H:%M:%S); wake-up $(date -r "$T" +%H:%M)"
echo "cron: $(date -r "$T" '+%M %H %d %m' | awk '{print $1+0, $2+0, $3+0, $4+0, "*"}')"
```

The middle field of the entry ties it to THIS session (see `after` below).

Then schedule the wake-up. Load `CronCreate` with ToolSearch if it's deferred.
Call it with the printed cron expression as `cron`, `recurring: false`, and
this as `prompt`, filled in from the printed output and a few words of the
queued prompt:

> circle-back wake-up for the entry due at HH:MM:SS (epoch DUE): "first few
> words...". Do nothing else this turn. If `date +%s` is still before DUE,
> wait out the remaining seconds (a Bash `sleep`, or a Monitor until-loop on
> `date +%s`). If you cannot wait, CronCreate this same prompt again
> (`recurring: false`) at the expression printed by
> `T=$(( ($(date +%s)/60+1)*60 )); case $(date -r $T +%M) in 00|30) T=$((T+60));; esac; date -r $T '+%M %H %d %m' | awk '{print $1+0,$2+0,$3+0,$4+0,"*"}'`.
> Then end the turn with one short line. The Stop hook delivers the queued
> prompt.

The wake-up carries no work of its own, so it is harmless if the entry has
already fired (the session ended a turn after the due time) or was cancelled.

Confirm in one line: the due time (clock time, not just the delay), a few
words of the prompt, and the cron job ID (`CronDelete` needs it to cancel).

If `CronCreate` isn't available in this session, queue the entry anyway and
say plainly that it fires at the first turn end after the due time, not on
the clock. A session that is kept continuously busy (a `/goal` or `/loop`
whose Stop hook keeps blocking) needs no special handling: the entry fires at
the first turn end after it is due, and the wake-up, which cron only sends at
an idle moment, arrives later as a no-op.

### `after`, "after this is done", "then...": append to the queue

```bash
Q="${CIRCLE_BACK_QUEUE:-$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue}"
mkdir -p "$(dirname "$Q")"
printf 'after:%s\t%s\t%s\n' "$(date +%s)" "${CLAUDE_CODE_SESSION_ID:?no session id}" "$PROMPT_ARG" >> "$Q"
```

The first field is the word `after` plus the time it was queued. The hook
never uses that time to fire it; it is only there so an orphaned entry can be
adopted later (see "How the queue fires").

The middle field ties the entry to THIS session: the hook fires it only here,
never in another Claude Code session that stops in the same directory (a
roborev reviewer, a subagent, a second terminal).

An `after` entry waits for every entry ahead of it in this session's queue,
timed or not, due or not, and fires at the end of the turn the last of them
ran in. With nothing ahead of it, that is the end of the current turn. Several
`after` entries in a row run in order, one per turn. A timed entry ahead of it
is what makes stacking work: `/circle-back 600 check the deploy` followed by
`/circle-back after tell me if it passed` runs the check at its due time and
the report when the check's turn ends.

Before confirming, look at what is ahead of it (the listing under "Inspecting
what's pending", filtered to this session) and say so: "fires after 'check the
deploy' (due 11:00)" or "fires when the current work ends". The user may have
meant the other one.

### Delay 0: due now, ahead of anything pending

A `0` delay is a timed entry with the current time as its due time and no
cron wake-up (the current turn ending is the wake-up):

```bash
printf '%s\t%s\t%s\n' "$(date +%s)" "${CLAUDE_CODE_SESSION_ID:?no session id}" "$PROMPT_ARG" >> "$Q"
```

It fires when the current turn ends, even if other entries are pending ahead
of it. Use it when the user wants something at the end of *this* turn and has
an unrelated `after` chain or timed entry already queued; otherwise `after`
says what they mean.

In every case, stop after confirming. Do not start on the queued work, do not
elaborate on it, do not ask whether the user wants it done now instead.
Scheduling is the whole job.

## Limits to tell the user about

- **The session has to stay open.** The queue and the wake-up both live in
  this Claude Code session. `CronCreate` jobs are in memory only and are gone
  when Claude exits (they do not survive a restart or `--resume`); the queue
  entry survives, but with no wake-up it fires only at the first turn end
  after its due time, and only once an attended session in this directory
  adopts it. If the machine sleeps, the wake-up fires when it wakes, as long
  as the session is still open. For prompts that must run with no session
  open, use the `schedule` skill (cloud routines).
- **Cron granularity is one minute.** The wake-up lands at the due time
  rounded up to the minute, or one minute later when that is :00 or :30
  (one-shots at those marks can arrive up to 90 s early). The wake-up prompt
  also tells the agent to sleep off any remainder, so the entry fires at or
  after its due second; the cost is up to two minutes of slop.
- **Queue entries fire only when a turn ends.** Without the wake-up (no
  `CronCreate` in the session), say plainly that the entry waits for the next
  turn to end after the due time, not for the clock.
- **An `after` entry waits for everything ahead of it in the queue,** even an
  entry due hours from now. Say what it is waiting on when you confirm.
- **The wake-up is a visible turn.** It shows in the transcript as a prompt
  and a one-line reply before the queued prompt runs.

## Rules

- Write the prompt so it stands alone. It arrives after the current turn is
  gone from view, so "fix that" or "now the other one" will land with no
  referent. Expand pronouns into nouns before writing the entry.
- One line per entry. Collapse any newlines in the prompt to spaces.
- The delay is measured from when you schedule it.
- Queue entries fire by due time, earliest first, one per turn, regardless of
  the order they were queued in. An entry that isn't due yet does not hold up a
  later one that is. The exception is an `after` entry, which waits for
  everything ahead of it and, once free, goes before anything queued behind it.
- If the user gives a delay in minutes or hours, convert to seconds yourself
  rather than asking.
- If the user gives no delay, use `after`. It goes in the queue and fires when
  the previous task completes.
- Beyond a few hours, prefer the `schedule` skill. The queue and its wake-up
  both need the session to still be open.

## Inspecting what's pending

The queue is the source of truth. `CronList` shows only the wake-ups.

Queue entries, in file order, with due times rendered (a legacy two-field
entry shows its prompt in the session column):

```bash
while IFS=$'\t' read -r due sid prompt; do
  case "$due" in
    after*) printf 'after the task ahead    [%s]  %s\n' "${sid:0:8}" "$prompt" ;;
    *) printf '%s  (in %ss)  [%s]  %s\n' "$(date -r "$due" '+%H:%M:%S')" "$(( due - $(date +%s) ))" "${sid:0:8}" "$prompt" ;;
  esac
done < "$Q"
```

Clear it:

```bash
: > "$Q"
```

Drop a single entry by line number:

```bash
sed "${N}d" "$Q" > "$Q.tmp" && mv "$Q.tmp" "$Q"
```

Cancelling a timed entry means dropping its queue line. That is the whole
cancel: every wake-up for it, including any a wake-up rescheduled for itself
under a new job ID, is then a harmless no-op. `CronDelete` what `CronList`
shows for it if you want the transcript quiet, but the ID from the original
confirmation may be stale. Deleting only the cron job does not cancel
anything: the entry still fires at the next turn end after its due time.

## How the queue fires

The `Stop` hook at `~/.claude/hooks/circle-back.sh` runs when a turn ends. It
picks the due entry with the earliest due time, removes it, and returns
`{"decision":"block","reason":"<prompt>"}`, which Claude Code delivers as the
next instruction (it shows up as "Stop hook feedback"). Nothing due — or an
empty queue — means it exits silently. Other Stop hooks that also block are
delivered alongside it, not instead of it.

An `after` entry has no due time. It is skipped while any entry ahead of it in
the file is one this session may fire; once none is left it counts as due, and
fires at that Stop. Since each fire removes one line and the fired prompt runs
in the next turn, "the entry ahead of it is gone" and "the previous task's
turn has ended" are the same moment. When the registry can't say whether an
`after` entry's owner is still running, the hour-overdue fallback measures
from the time it was queued instead.

The hook never sleeps. Stop hooks run synchronously and Claude Code blocks on
them, so a hook that slept for the delay would freeze the whole session for that
long. If you are tempted to add a `sleep` to make timing exact, don't: that was
the original design and it made a 30-minute delay a 30-minute lockup.

The queue file is scoped per working directory, and each entry is scoped to the
session that queued it: the hook fires only entries tagged with its own
session id, so another session stopping in the same directory (a roborev
reviewer running `claude -p`, a subagent, a second terminal) leaves them alone
while their owner is still running. Before this, a reviewer drained a queued
`/roborev-fix` and answered it in its review output (2026-09-24). Legacy
untagged entries fire only in an attended session. `CIRCLE_BACK_QUEUE` still
overrides the file location.

The one exception is an entry whose session is gone: `/clear` starts a new
session id, and a closed or crashed terminal never stops again. The hook checks
Claude Code's live-session registry (`~/.claude/sessions/<pid>.json`, which
records each running session's pid, start time and current id). Once a due
entry's owner is no longer running, the next attended session that stops in the
directory takes it over and fires it. Headless sessions never do. If the
registry is missing, or doesn't list the session doing the check (a sign its
format changed), it falls back to adopting entries more than an hour overdue
(`CIRCLE_BACK_ADOPT_AFTER` seconds).
