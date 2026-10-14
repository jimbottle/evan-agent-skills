---
name: circle-back
argument-hint: <seconds|after [seconds]> <prompt>
description: Queue a follow-up prompt to be sent automatically once a delay has elapsed or once the previous task completes, without interrupting work in progress. Use this whenever the user says "circle around", "circle back", "queue this for later", "come back to this in X minutes", "after this is done, also...", "then do X" (right after queuing something else), or otherwise wants a prompt held and fired later rather than acted on now — including when the queued prompt is unrelated to whatever is currently in flight. Also covers "X minutes after this finishes" (`after <seconds>`), where the timer starts when the current work ends rather than now.
---

# circle-back

Hold a prompt and send it later. Every entry lives in one queue file, in the
order it should run, and the `circle-back.sh` Stop hook fires the next due
entry when a turn ends. There are three ways an entry comes due:

- **A clock (`<seconds>`).** The entry carries an absolute due time. Because
  the hook only runs when a turn *ends*, a session sitting idle at the prompt
  would never notice the due time passing, so a background Bash command is
  started that waits on the OS clock and exits at the due time. Its
  completion notice re-invokes the agent, which ends a turn; the hook sees
  the entry is due, and the real prompt goes out. If the session is busy at
  the due time, the entry fires at the next turn end anyway and the notice,
  arriving later, is a no-op.
- **The previous task finishing (`after`).** The entry has no due time. It
  waits for every entry ahead of it in the queue, timed or not, and fires at
  the end of the turn in which the last of them ran. With nothing ahead of it,
  that is the end of the work in flight right now, including any background
  work it is waiting on (see "Background work" below).
- **A clock that starts when the previous task finishes (`after <seconds>`).**
  An `after` entry carrying a delay. It waits like a plain `after`, and at the
  moment it would have fired, the hook starts its timer instead: the entry
  becomes a timed one due `<seconds>` from then, and the hook hands the agent
  the wake-up prompt for it as the next turn. `/circle-back after 120 run the
  smoke test` runs the smoke test two minutes after the current work ends,
  however long that takes.

Because timers and `after` entries share one queue, they stack: a timer with a
command, then an `after` behind it, runs the timer's prompt at its due time and
the `after` prompt when that turn ends.

## Adding an entry

Invocation looks like `/circle-back <seconds> <prompt>`. Claude Code hands the
arguments to you as a trailing `ARGUMENTS: <seconds|after> <prompt>` line.
The first token is either the delay in seconds or the word `after`; everything
after it is the prompt, verbatim. One exception: when the first token is
`after` and the second is a bare integer, that integer is a delay in seconds
that starts when the task ahead finishes (see "`after <seconds>`" below), and
the prompt is everything after it. A prompt that genuinely starts with a
number goes behind `after 0`, which is a plain `after`.

### Delay greater than 0: queue entry plus a wake-up on the OS clock

Every entry goes in the queue. Append it with its due time and, in the same
Bash call (shell variables do not survive between calls), print what the
wake-up needs: the due epoch and its clock time.

```bash
Q="${CIRCLE_BACK_QUEUE:-$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue}"
mkdir -p "$(dirname "$Q")"
DUE=$(( $(date +%s) + SECONDS_ARG ))
printf '%s\t%s\t%s\n' "$DUE" "${CLAUDE_CODE_SESSION_ID:?no session id}" "$PROMPT_ARG" >> "$Q"
T=$(( (SECONDS_ARG + 120) * 1000 )); [ "$T" -le 7200000 ] || T=7200000
echo "due=$DUE at $(date -r "$DUE" +%H:%M:%S); wake-up timeout $T ms"
```

The middle field of the entry ties it to THIS session (see `after` below).

Then start the wake-up: a second Bash call, run in the background
(`run_in_background: true`), that polls the OS clock and exits once the due
time has passed. Replace `DUE` with the literal due epoch that was printed
and `HH:MM:SS` with its clock time:

```bash
until [ "$(date +%s)" -ge DUE ]; do sleep 5; done; echo "circle-back: entry due at HH:MM:SS (epoch DUE) -- end the turn; the Stop hook delivers the prompt"
```

Pass the printed `timeout` (the delay plus two minutes, in milliseconds,
capped at 7200000: a background command may run for two hours at most, so a
longer wait is stopped at that limit and re-armed, see below) and this
`description`, with the same substitutions and a few words of the
queued prompt in the quotes:

> circle-back wake-up for 'first few words...' due at HH:MM:SS: when this
> completes, end the turn with one short line; the Stop hook delivers the
> queued prompt

When its completion notice arrives, first check the clock. If `date +%s` is
still before the due epoch, the wait was stopped at the two-hour background
limit, not finished: start the same background wake-up again (same command
and description; `timeout` the seconds remaining plus 120, in milliseconds,
capped at 7200000 again) and end the turn with one short line. Otherwise do
exactly that: one short line, then end the turn. Do not start on the queued
prompt yourself; the hook delivers it
(it shows up as "Stop hook feedback"). The wake-up carries no work of its
own, so it is harmless if the entry has already fired (the session ended a
turn after the due time) or was cancelled.

The wake-up polls `date +%s` instead of sleeping for the whole delay so that
a laptop that slept through the due time fires the entry within seconds of
waking. It is deliberately NOT a `CronCreate` job: Claude Code's scheduler
keeps the timezone the session started in, so after a system timezone change
(travel, or DST on a long-lived session) a cron one-shot lands an hour or
more off while the shell's clock is right. On 2026-10-12 a wake-up scheduled
for 12:07 would have fired at 13:07 for exactly this reason. The OS clock has
no such drift.

Confirm in one line: the due time (clock time, not just the delay) and a few
words of the prompt. Cancelling is done in the queue, see "Inspecting what's
pending".

If the Bash tool cannot run in the background in this session, use `Monitor`
with the same `until` loop as its command and `timeout_ms` of the delay plus
a minute, capped at 30 minutes: both its event and its expiry notice end a
turn, and on an expiry before the due time, re-arm it. With neither, queue
the entry anyway and say plainly that it fires at the first turn end after
the due time, not on the clock. A session that is kept continuously busy (a
`/goal` or `/loop` whose Stop hook keeps blocking) needs no special handling:
the entry fires at the first turn end after it is due, and the completion
notice, arriving later, is a no-op.

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
deploy' (due 11:00)" or "fires when the current work ends". If you have
background work running that the task is waiting on (a CI watch, a build, an
async subagent), name it: "fires once the CI watch finishes and that turn
ends". The user may have meant the other one.

#### Background work

A turn ending is not always the task ending. While you wait on a background
command, a `Monitor` or an async subagent, you end turns to wait, and each
completion notice starts another. So an `after` entry (plain or with a delay)
is also held while the session's transcript shows a background task started
with no final notice (completed, failed, killed or stopped) delivered yet.
It comes due at the Stop that ends the turn that handled the last notice,
and an `after <seconds>` timer starts only then. While it is held, the hook
says so at each Stop ("circle-back: holding '...' until 2 background task(s)
finish: ..."). Not counted: circle-back's own wake-ups, a persistent `Monitor`
(it never ends), and tasks older than `CIRCLE_BACK_BG_MAX_WAIT` seconds
(default 14400, 4 hours; `0` turns this wait off) or older than the running
Claude Code process. Timed entries are not held: a clock is a clock.

So a background task that is not something the work waits on, such as a dev
server left running, holds every `after` entry until it is stopped. If the
hook reports holding for a task like that, tell the user and offer to stop it
(`TaskStop`) rather than leaving the entry stuck.

### `after <seconds>`: a timer that starts when the task ahead finishes

```bash
Q="${CIRCLE_BACK_QUEUE:-$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue}"
mkdir -p "$(dirname "$Q")"
printf 'after+%s:%s\t%s\t%s\n' "$SECONDS_ARG" "$(date +%s)" "${CLAUDE_CODE_SESSION_ID:?no session id}" "$PROMPT_ARG" >> "$Q"
```

The first field is `after+<seconds>` plus the time it was queued. No
wake-up is started now: there is nothing to start it for, since the due
time is not known until the task ahead ends. The entry waits exactly like a
plain `after`, background work included: the clock does not start while a
CI watch or build the task is waiting on is still running. At the Stop where a plain `after` would fire, the hook instead
rewrites this entry in place as a timed entry due `<seconds>` from that
moment and blocks with the wake-up prompt for it, so the very next turn is
the wake-up turn: the agent starts the background wake-up the prompt spells
out (the same `until` loop as above), ends the turn, and the entry fires when
the wake-up's completion notice ends the turn after it. From then on it is an
ordinary timed entry, and cancelling it is dropping its queue line, as usual.

Confirm in one line: the delay, that it starts when the work ahead ends, what
that work is (as for `after`), and a few words of the prompt: "fires 2 min
after the current work ends: 'run the smoke test'" or "fires 10 min after
'check the deploy' (due 11:00) has run". Beyond a few hours, prefer a plain
timed entry or the `schedule` skill: the wake-up turn needs the session open.

### Delay 0: due now, ahead of anything pending

A `0` delay is a timed entry with the current time as its due time and no
wake-up (the current turn ending is the wake-up):

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
  this Claude Code session. The background wake-up is a child of the session
  and is gone when Claude exits (it does not survive a restart or
  `--resume`); the queue entry survives, but with no wake-up it fires only at
  the first turn end after its due time, and only once an attended session in
  this directory adopts it. If the machine sleeps, the wake-up fires within
  seconds of it waking, as long as the session is still open. For prompts
  that must run with no session open, use the `schedule` skill (cloud
  routines).
- **The wake-up lands within seconds of the due time.** It polls the clock
  every 5 s, so the entry fires at or just after its due second, plus the
  one-line wake-up turn.
- **Queue entries fire only when a turn ends.** Without a wake-up (no
  background Bash or `Monitor` in the session), say plainly that the entry
  waits for the next turn to end after the due time, not for the clock.
- **An `after` entry waits for everything ahead of it in the queue,** even an
  entry due hours from now, and for the session's running background tasks.
  Say what it is waiting on when you confirm.
- **The wake-up is a visible turn.** It shows in the transcript as a
  completion notice and a one-line reply before the queued prompt runs. For
  `after <seconds>` there are two such turns: the hook delivers the wake-up
  prompt directly as "Stop hook feedback" the moment the timer starts, the
  agent starts the background wake-up from there, and the notice turn follows
  at the due time. Like a plain `after`, the wake-up turn goes before
  anything queued behind the entry; a timed entry behind it that is already
  due fires when the wake-up turn ends.

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
- If the user gives a delay *and* ties it to the current work finishing ("two
  minutes after this is done", "once that lands, wait 5 min then..."), use
  `after <seconds>`. A bare delay is measured from now; `after <seconds>` is
  measured from the end of the task ahead.
- Beyond a few hours, prefer the `schedule` skill. The queue and its wake-up
  both need the session to still be open.

## Inspecting what's pending

The queue is the source of truth; the background wake-ups are only nudges.

Queue entries, in file order, with due times rendered (a legacy two-field
entry shows its prompt in the session column):

```bash
while IFS=$'\t' read -r due sid prompt; do
  case "$due" in
    after+*) d=${due#after+}; printf '%ss after the task ahead  [%s]  %s\n' "${d%%:*}" "${sid:0:8}" "$prompt" ;;
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
cancel: its wake-up, when it lands, is then a harmless no-op. `TaskStop` the
background wake-up if you want the transcript quiet. Stopping only the
wake-up does not cancel anything: the entry still fires at the next turn end
after its due time.

## How the queue fires

The `Stop` hook at `~/.claude/hooks/circle-back.sh` runs when a turn ends. It
picks the due entry with the earliest due time, removes it, and returns
`{"decision":"block","reason":"<prompt>"}`, which Claude Code delivers as the
next instruction (it shows up as "Stop hook feedback"). Nothing due — or an
empty queue — means it exits silently. Other Stop hooks that also block are
delivered alongside it, not instead of it.

An `after` entry has no due time. It is skipped while any entry ahead of it in
the file is one this session may fire; once none is left it counts as due, and
fires at that Stop, unless the session still has background work running
(see "Background work"), in which case it stays put and the hook's system
message names the tasks. An `after+<seconds>` entry is skipped the same way, but
once unblocked it is not fired: the hook rewrites it as a timed entry due
`<seconds>` from that Stop, retagged to the session that did the rewrite, and
blocks with its wake-up prompt instead (which spells out the background
wake-up command with the due epoch filled in). The timed entry then fires at
the first Stop after its due time, like any other. Since each fire removes
one line and the fired prompt runs
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
