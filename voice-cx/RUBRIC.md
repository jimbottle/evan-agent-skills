# Judging rubric

You are judging an **episode**: everything one person said to one device in one
sitting, with what the assistant said and what actually changed in the house.
Judge it the way that person would describe it to a friend afterwards.

## Step 1 — reconstruct the intent

Write one line: what did they want to end up with? Use the whole episode.

- A later turn explains an earlier one. "Play the radio. Music." followed by
  "Play it at Radio WFPK Station" and then "Play the radio. Station WFBK" means
  they wanted WFPK from the first turn, and the first two attempts failed.
- Transcripts are noisy. "W-F-B-K", "to FBK", "for WFPK" are the same request.
  Judge the intent behind the noise, then ask separately whether the noise is
  the problem (stage `stt`).
- An episode with two unrelated problems gets two judgments, one per cluster;
  the episode's verdict is the worst of them. Do not fold a second problem into
  the first cluster's `--why`, or it never reaches the queue.

## Step 2 — read the user literally

Anything the user says **about the experience** is evidence that outranks every
log line:

| They said | Read as |
| --- | --- |
| a flag, with or without a reason | this episode was not fine; the reason (if any) is what they expected |
| "I said X", "I asked for X", "I meant X" | X was the intent; whatever happened instead is S1 or S2 |
| "stop", "no", "cancel", "wait no", "turn it off" right after an action | the action was wrong (S1) unless the episode clearly shows a change of mind |
| "do I need to yell?", "can you hear me?", repeating themselves | wake/STT failures they lived through, even if the log shows only the last, successful attempt |
| "why did you…", "that's not what I…", annoyed asides | the reply or action broke their expectation; find which |

When an episode holds several problems, the user's words boost only the cluster
they were about: judge the others with `--not-voiced`.

Do not argue with these. If the log says success and the user says it failed,
the log is measuring the wrong thing — find what it missed (the effects window,
a second device, a stream that started and died).

The `episodes` packet marks these as `USER VOICE` / `FLAG … <- read literally`,
but its pattern list is a net, not a definition. Read every transcript yourself.

## Step 3 — what did it cost them?

Check each, in order; the first that applies sets the severity:

| | Question | Severity |
| --- | --- | --- |
| S1 | Did it do the **wrong** thing, or something they then had to undo? Did the reply **claim** something that the effects contradict ("Playing WFPK" while YouTube plays; "Volume set" while nothing moved)? | S1 = 8 |
| S2 | Did **nothing** happen when they asked for something (including a no-match, an error, an honest "I could not")? | S2 = 5 |
| S3 | Did they have to **repeat, rephrase or correct** to get there, or wake it twice? | S3 = 3 |
| S4 | Was it **slow** — a routine command that went the long way (LLM) or blew the latency budget? | S4 = 2 |
| S5 | Was the reply **off-manner** — more than one short sentence, chatty, an unasked question (which can reopen the mic), reading out internals? | S5 = 1 |

Verdict:

- **good** — they got what they wanted, first time, promptly, with a reply that told the truth. (S5-level nits alone do not spoil a good episode; note them in `--why`.)
- **friction** — they got there, but paid for it (S3–S5).
- **bad** — they did not get it, or got something wrong or untrue (S1–S2).
- **skip** — no person in the episode (a test run you or a script made). A false wake on room noise is *not* a skip.

An honest "I could not do that." is still S2 — they did not get it — but it is a
much better failure than a confident lie, which is S1. Say which in `--why`.

## Step 4 — where did it break?

Name the **first** stage that went wrong; everything after it is a consequence.

| Stage | Looks like |
| --- | --- |
| `wake` | repeated wake attempts, a run that is only room noise, user says they had to repeat |
| `stt` | the transcript is not what they plausibly said |
| `routing` | right words, wrong handler: a local match to the wrong intent, or a routine command falling to the LLM |
| `resolution` | right intent, wrong or missing target (entity, area, station) |
| `action` | right call, wrong or no effect (floor reached, stream died, device offline) |
| `reply` | the action was right but the words were wrong, untrue, too long, a question |
| `latency` | right result, too slow |
| `llm` | the model chose badly, hallucinated, or leaked internals |
| `platform` | an upstream bug, a crashed dependency, the network |

## Step 5 — cluster and fix

- **Cluster by cause.** Two different phrasings that fail for the same reason are
  one cluster; one phrasing failing for two reasons is two judgments. Reuse
  slugs from `cx.py queue`.
- **Pick the cheapest correct fix** (SKILL.md §5) and record it with `--fix`.
  "Correct" means it fixes the cause for the whole cluster, not just the
  literal sentence in the log.
- **Good episodes in a shipped cluster get that cluster.** That is the only way
  a fix becomes `verified`.

## Calibration

The scorecard's `judge_missed_flags` lists episodes the user flagged that a judge
called good. Each one means the rubric or the judge missed something a person
noticed. Re-judge it (the newest judgment wins), and if the miss is a pattern,
propose a rubric change with the episode as evidence.
