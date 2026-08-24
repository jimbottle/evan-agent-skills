---
name: circle-back
description: Queue a follow-up prompt to be sent automatically N seconds after the current work finishes, without interrupting it. Use this whenever the user says "circle around", "circle back", "queue this for later", "come back to this in X minutes", "after this is done, also...", or otherwise wants a prompt held and fired later rather than acted on now — including when the queued prompt is unrelated to whatever is currently in flight.
---

# circle-back

Hold a prompt in a queue file. A Stop hook drains it: when the current turn
ends, the hook waits the entry's delay and then feeds the prompt back as the
next instruction. Queued prompts never interrupt work in progress.

## Adding an entry

Invocation looks like `/circle-back <seconds> <prompt>`. The first token is
the delay in seconds; everything after it is the prompt, verbatim.

Resolve the queue path, then append:

```bash
Q="${CIRCLE_BACK_QUEUE:-$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue}"
mkdir -p "$(dirname "$Q")"
printf '%s\t%s\n' "$SECONDS_ARG" "$PROMPT_ARG" >> "$Q"
```

Then confirm in one line — the delay and a few words of the prompt — and stop.
Do not start on the queued work, do not elaborate on it, do not ask whether the
user wants it done now instead. Queuing is the whole job.

## Rules

- Write the prompt so it stands alone. It arrives after the current turn is
  gone from view, so "fix that" or "now the other one" will land with no
  referent. Expand pronouns into nouns before writing the entry.
- One line per entry. Collapse any newlines in the prompt to spaces.
- The delay is measured from when the previous turn ends, not from now.
- Entries fire oldest first, one per turn.
- Delays are clamped to `CIRCLE_BACK_MAX_WAIT` (default 1800s). For anything
  longer, schedule a one-shot cron task instead — those survive an idle session
  and don't hold a hook process open.
- If the user gives a delay in minutes or hours, convert to seconds yourself
  rather than asking.
- If the user gives no delay, use 0.

## Inspecting the queue

List what's pending:

```bash
cat -n "$Q"
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
pops the oldest entry, sleeps the delay, and returns
`{"decision":"block","reason":"<prompt>"}`, which Claude Code delivers as the
next instruction. An empty queue means the hook exits silently and the turn ends
normally.

The queue is scoped per working directory, so two sessions in different repos
keep separate queues. Two sessions in the *same* directory share one — set
`CIRCLE_BACK_QUEUE` per session to split them.
