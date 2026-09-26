---
name: circle-back
argument-hint: <seconds> <prompt>
description: Queue a follow-up prompt to be sent automatically once a delay has elapsed, without interrupting work in progress. Use this whenever the user says "circle around", "circle back", "queue this for later", "come back to this in X minutes", "after this is done, also...", or otherwise wants a prompt held and fired later rather than acted on now — including when the queued prompt is unrelated to whatever is currently in flight.
---

# circle-back

Hold a prompt and send it later. There are two ways to hold it, and the choice
matters:

- **Timed delay (the default): the built-in `CronCreate` tool.** Claude Code's
  own scheduler sends the prompt at the due minute, as long as the session is
  open and at the prompt. If the session is busy then, it goes out as soon as
  the current work finishes. It shows up in the terminal like any prompt you
  typed.
- **"After this is done" (delay 0): the Stop-hook queue.** A queue file that
  the `circle-back.sh` Stop hook reads when a turn ends. It has no timer, so it
  only fires when a turn *ends*. A session left at the prompt never ends
  another turn, so a timed entry here can sit unfired for hours. Don't use it
  for timed delays, except in the case below.

## Adding an entry

Invocation looks like `/circle-back <seconds> <prompt>`. Claude Code hands the
arguments to you as a trailing `ARGUMENTS: <seconds> <prompt>` line. The first
token is the delay in seconds; everything after it is the prompt, verbatim.

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

### Delay 0, or "after this is done": append to the queue

```bash
Q="${CIRCLE_BACK_QUEUE:-$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue}"
mkdir -p "$(dirname "$Q")"
printf '%s\t%s\t%s\n' "$(( $(date +%s) + SECONDS_ARG ))" "${CLAUDE_CODE_SESSION_ID:?no session id}" "$PROMPT_ARG" >> "$Q"
```

The middle field ties the entry to THIS session: the hook fires it only here,
never in another Claude Code session that stops in the same directory (a
roborev reviewer, a subagent, a second terminal).

It fires when the current turn ends.

Either way, stop after confirming. Do not start on the queued work, do not
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

## Rules

- Write the prompt so it stands alone. It arrives after the current turn is
  gone from view, so "fix that" or "now the other one" will land with no
  referent. Expand pronouns into nouns before writing the entry.
- One line per entry. Collapse any newlines in the prompt to spaces.
- The delay is measured from when you schedule it.
- Queue entries fire by due time, earliest first, one per turn, regardless of
  the order they were queued in. An entry that isn't due yet does not hold up a
  later one that is.
- If the user gives a delay in minutes or hours, convert to seconds yourself
  rather than asking.
- If the user gives no delay, use 0. It goes in the queue and fires at the end
  of the current turn.
- Beyond a few hours, prefer the `schedule` skill. Both mechanisms need the
  session to still be open.

## Inspecting what's pending

Scheduled cron jobs: `CronList`; cancel one with `CronDelete <id>`.

Queue entries, with due times rendered (a legacy two-field entry shows its
prompt in the session column):

```bash
while IFS=$'\t' read -r due sid prompt; do
  printf '%s  (in %ss)  [%s]  %s\n' "$(date -r "$due" '+%H:%M:%S')" "$(( due - $(date +%s) ))" "${sid:0:8}" "$prompt"
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

The hook never sleeps. Stop hooks run synchronously and Claude Code blocks on
them, so a hook that slept for the delay would freeze the whole session for that
long. If you are tempted to add a `sleep` to make timing exact, don't: that was
the original design and it made a 30-minute delay a 30-minute lockup.

The queue file is scoped per working directory, and each entry is scoped to the
session that queued it: the hook fires only entries tagged with its own
session id, so another session stopping in the same directory (a roborev
reviewer running `claude -p`, a subagent, a second terminal) leaves them alone.
Before this, a reviewer drained a queued `/roborev-fix` and answered it in its
review output (2026-09-24). Legacy untagged entries fire only in an attended
session. `CIRCLE_BACK_QUEUE` still overrides the file location.

`/clear` starts a new session id, and a closed or crashed terminal never stops
again, so an entry can outlive its session. Once a tagged entry is an hour
overdue (`CIRCLE_BACK_ADOPT_AFTER` seconds), the next attended session that
stops in the directory takes it over and fires it. Headless sessions never do.
