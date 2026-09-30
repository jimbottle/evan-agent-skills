---
name: circle-back
argument-hint: <seconds|after> <prompt>
description: Queue a follow-up prompt to be sent automatically once a delay has elapsed or once the previous task completes, without interrupting work in progress. Use this whenever the user says "circle around", "circle back", "queue this for later", "come back to this in X minutes", "after this is done, also...", "then do X" (right after queuing something else), or otherwise wants a prompt held and fired later rather than acted on now — including when the queued prompt is unrelated to whatever is currently in flight.
---

# circle-back

Hold a prompt and send it later. There are two triggers, and the choice
matters:

- **A clock (`<seconds>`): the built-in `CronCreate` tool.** Claude Code's
  own scheduler sends the prompt at the due minute, as long as the session is
  open and at the prompt. If the session is busy then, it goes out as soon as
  the current work finishes. It shows up in the terminal like any prompt you
  typed.
- **The previous task finishing (`after`): the Stop-hook queue.** A queue file
  that the `circle-back.sh` Stop hook reads when a turn ends. An `after` entry
  fires at the end of the turn in which the task ahead of it ran: the entry
  queued before it if one is still pending, otherwise the work in flight right
  now. No guessing how long the current work will take.

  The queue has no timer, so it only fires when a turn *ends*. A session left
  at the prompt never ends another turn, so a timed entry here can sit unfired
  for hours. Don't use it for timed delays, except in the case below.

## Adding an entry

Invocation looks like `/circle-back <seconds> <prompt>`. Claude Code hands the
arguments to you as a trailing `ARGUMENTS: <seconds|after> <prompt>` line.
The first token is either the delay in seconds or the word `after`; everything
after it is the prompt, verbatim.

### Delay greater than 0: schedule it with `CronCreate`

Load `CronCreate` with ToolSearch if it's deferred. Round the due time **up**
to the next whole minute and build a one-shot cron expression:

```bash
T=$(( $(date +%s) + SECONDS_ARG + 59 ))
date -r "$T" '+%M %H %d %m' | awk '{print $1+0, $2+0, $3+0, $4+0, "*"}'
```

Call `CronCreate` with that expression as `cron`, the prompt as `prompt`, and
`recurring: false`. Then confirm in one line: the due time (clock time, not
just the delay) and a few words of the prompt. Keep the returned job ID in that
line, since `CronDelete` needs it to cancel.

Use the queue instead only when:

- `CronCreate` isn't available in this session, or
- the session will be kept continuously busy past the due time (a `/goal` or
  `/loop` whose Stop hook keeps blocking). Cron only fires at idle moments, so
  it won't fire until that loop stops. The queue fires at every turn end, so it
  keeps working.

### `after`, "after this is done", "then...": append to the queue

```bash
Q="${CIRCLE_BACK_QUEUE:-$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue}"
mkdir -p "$(dirname "$Q")"
printf 'after\t%s\t%s\n' "${CLAUDE_CODE_SESSION_ID:?no session id}" "$PROMPT_ARG" >> "$Q"
```

The middle field ties the entry to THIS session: the hook fires it only here,
never in another Claude Code session that stops in the same directory (a
roborev reviewer, a subagent, a second terminal).

An `after` entry waits for every entry ahead of it in this session's queue,
due or not, and fires at the end of the turn the last of them ran in. With
nothing ahead of it, that is the end of the current turn. Several `after`
entries in a row run in order, one per turn.

Before confirming, look at what is ahead of it (the listing under "Inspecting
what's pending", filtered to this session) and say so: "fires after 'check the
deploy' (due 11:00)" or "fires when the current work ends". The user may have
meant the other one.

A `CronCreate` job is not in the queue, so nothing can chain onto it. When the
user wants B after a task A that is scheduled with cron, `CronDelete` A and
`CronCreate` it again with both prompts in one: "A. When that is done, B."

### Delay 0: due now, ahead of anything pending

A `0` delay writes a queue entry with the current time as its due time:

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

- **The session has to stay open.** Both mechanisms live in this Claude Code
  session. `CronCreate` jobs are in memory only and are gone when Claude exits
  (they do not survive a restart or `--resume`). If the machine sleeps, the job
  fires when it wakes, as long as the session is still open. For prompts that
  must run with no session open, use the `schedule` skill (cloud routines).
- **Cron granularity is one minute.** One-shots due at :00 or :30 can fire up
  to 90 s early. For an approximate delay, a minute off the :00/:30 marks is
  fine.
- **Queue entries fire only when a turn ends.** If you did use the queue for a
  timed entry, say plainly that it waits for the next turn to end after the
  due time, not for the clock.
- **An `after` entry waits for everything ahead of it in the queue,** even an
  entry due hours from now. Say what it is waiting on when you confirm.

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
- Beyond a few hours, prefer the `schedule` skill. Both mechanisms need the
  session to still be open.

## Inspecting what's pending

Scheduled cron jobs: `CronList`; cancel one with `CronDelete <id>`.

Queue entries, in file order, with due times rendered (a legacy two-field
entry shows its prompt in the session column):

```bash
while IFS=$'\t' read -r due sid prompt; do
  case "$due" in
    after) printf 'after the task ahead    [%s]  %s\n' "${sid:0:8}" "$prompt" ;;
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
turn has ended" are the same moment.

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
