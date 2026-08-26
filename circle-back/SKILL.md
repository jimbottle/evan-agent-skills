---
name: circle-back
description: Queue a follow-up prompt to be sent automatically once a delay has elapsed, without interrupting work in progress. Use this whenever the user says "circle around", "circle back", "queue this for later", "come back to this in X minutes", "after this is done, also...", or otherwise wants a prompt held and fired later rather than acted on now — including when the queued prompt is unrelated to whatever is currently in flight.
---

# circle-back

Hold a prompt in a queue file with an absolute due time. A Stop hook checks the
queue when a turn ends: if an entry has come due it feeds the prompt back as the
next instruction, otherwise it exits instantly and the turn ends normally.

## Adding an entry

Invocation looks like `/circle-back <seconds> <prompt>`. The first token is the
delay in seconds; everything after it is the prompt, verbatim.

Convert the delay to an absolute due timestamp, then append:

```bash
Q="${CIRCLE_BACK_QUEUE:-$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue}"
mkdir -p "$(dirname "$Q")"
printf '%s\t%s\n' "$(( $(date +%s) + SECONDS_ARG ))" "$PROMPT_ARG" >> "$Q"
```

Then confirm in one line — the delay and a few words of the prompt — and stop.
Do not start on the queued work, do not elaborate on it, do not ask whether the
user wants it done now instead. Queuing is the whole job.

## When it actually fires

**At the first turn that ends at or after the due time.** Not on a timer, and
not while the session sits idle at the prompt — the hook only runs on Stop, so
something has to end a turn for a due entry to be noticed.

In practice "circle back in 30 minutes" means "next time I finish a turn, 30+
minutes from now." Say this plainly if the user seems to expect an alarm. If
they need a prompt to fire while they're away from the session, that's a job for
a one-shot cron task via the `schedule` skill, not for this one.

## Rules

- Write the prompt so it stands alone. It arrives after the current turn is
  gone from view, so "fix that" or "now the other one" will land with no
  referent. Expand pronouns into nouns before writing the entry.
- One line per entry. Collapse any newlines in the prompt to spaces.
- The delay is measured from when you queue it.
- Entries fire oldest-due first, one per turn. An entry that isn't due yet does
  not hold up a later one that is.
- If the user gives a delay in minutes or hours, convert to seconds yourself
  rather than asking.
- If the user gives no delay, use 0 — it fires at the end of the current turn.
- Beyond a few hours, prefer the `schedule` skill. A queue entry only fires if
  the session is still open and still ending turns.

## Inspecting the queue

List what's pending, with due times rendered:

```bash
while IFS=$'\t' read -r due prompt; do
  printf '%s  (in %ss)  %s\n' "$(date -r "$due" '+%H:%M:%S')" "$(( due - $(date +%s) ))" "$prompt"
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

## How it fires

The `Stop` hook at `~/.claude/hooks/circle-back.sh` runs when a turn ends. It
scans for the first entry whose due time has passed, removes it, and returns
`{"decision":"block","reason":"<prompt>"}`, which Claude Code delivers as the
next instruction. Nothing due — or an empty queue — means it exits silently.

The hook never sleeps. Stop hooks run synchronously and Claude Code blocks on
them, so a hook that slept for the delay would freeze the whole session for that
long. If you are tempted to add a `sleep` to make timing exact, don't: that was
the original design and it made a 30-minute delay a 30-minute lockup.

The queue is scoped per working directory, so two sessions in different repos
keep separate queues. Two sessions in the *same* directory share one — set
`CIRCLE_BACK_QUEUE` per session to split them.
