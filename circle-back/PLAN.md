# circle-back — setup and test plan

Executable plan for a Claude Code agent. Work top to bottom. Every step has an
explicit pass condition; **stop at the first failure and report it rather than
improvising a fix.** Two steps are human gates and are marked as such.

Expect roughly 10 minutes, most of it waiting on live-test delays.

## Inputs

Four files, placed anywhere (referred to below as `$SRC`):

```
$SRC/SKILL.md
$SRC/install.sh
$SRC/hooks/circle-back.sh
$SRC/test/offline-tests.sh
```

## Definition of done

- `bash test/offline-tests.sh` reports 0 failures (45 assertions)
- `/hooks` lists `circle-back.sh` under Stop
- A single queued prompt fires after its delay, unprompted
- Two queued prompts fire in order across consecutive turns
- A due entry queued *after* a later-due one still fires first (due order, not file order)
- A queued prompt does not interrupt a long-running turn
- A 30-minute delay leaves the session immediately responsive
- Rollback verified as working

---

## Phase 0 — preflight

Read-only. Nothing is modified.

**0.1** Confirm the four input files exist and are non-empty. If any is missing,
stop and report which.

**0.2** Check `jq`:

```bash
command -v jq && jq --version
```

Missing → stop and report. `brew install jq`. Do not attempt a workaround; the
hook builds its JSON with it.

**0.3** Record the pre-existing state for comparison later:

```bash
jq -c '.hooks.Stop // "none"' ~/.claude/settings.json 2>/dev/null || echo "no settings.json"
ls ~/.claude/hooks/ 2>/dev/null
```

Note whether a Stop hook already exists. If one does, flag it. Multiple Stop
hooks run concurrently and every blocking reason is delivered together, so a
pre-existing hook does not prevent circle-back from firing — but a slow one
still delays the turn ending. Not a blocker, but say so before continuing.

**0.4** Confirm no session is mid-task in this working directory other than
this one.

---

## Phase 1 — offline tests, before installing

The harness runs against throwaway directories and a fake `$HOME`. It does not
touch the real `~/.claude`. Running it *before* install means a failure costs
nothing.

```bash
cd "$SRC" && bash test/offline-tests.sh
```

**Pass condition:** final line reads `N passed, 0 failed`, exit status 0.
Expect 45 assertions across 15 groups.

Any failure → stop and report the failing group verbatim. Do not install over a
red harness.

---

## Phase 2 — install

**2.1** Run the installer:

```bash
cd "$SRC" && bash install.sh
```

It copies `SKILL.md` to `~/.claude/skills/circle-back/`, copies the hook to
`~/.claude/hooks/`, `chmod +x`'s it, and — only if the Stop hook is not yet
registered — backs up `settings.json` to `settings.json.bak.<epoch>` and
appends the entry via jq. A re-run refreshes the copied files but leaves
`settings.json` and the backups alone, so the newest backup is always the
pre-install state.

**2.2** Verify the install landed:

```bash
jq -e '[.hooks.Stop[].hooks[] | select(.command|test("circle-back"))] | length == 1' ~/.claude/settings.json
test -x ~/.claude/hooks/circle-back.sh && echo "hook executable"
test -f ~/.claude/skills/circle-back/SKILL.md && echo "skill present"
ls -t ~/.claude/settings.json.bak.* | head -1
```

**Pass condition:** `true`, both echoes, and a backup path (from the first
install; a re-run writes no new backup). Also confirm any pre-existing hooks
noted in 0.3 are still present.

**2.3** Smoke-test the installed copy directly, bypassing Claude entirely:

```bash
Q="$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue"
mkdir -p "$(dirname "$Q")"
printf '0\tsmoke test\n' > "$Q"
echo '{"cwd":"'"$PWD"'","stop_hook_active":false}' | ~/.claude/hooks/circle-back.sh
cat "$Q"
```

**Pass condition:** JSON on stdout with `"decision":"block"` and
`"reason":"smoke test"`; the queue file is left empty.

---

## Phase 3 — HUMAN GATE: register the hook

**Agent: stop here. Print the instruction below and end your turn. Do not
proceed to Phase 4 in this turn.**

> Hook registration needs you. Claude Code's behavior here is version-dependent
> — older builds snapshot hooks at session start, newer ones watch the settings
> files and hot-reload, and when hooks change externally the harness may hold
> them pending your review. In every version there's a human in the loop,
> because a config that could self-approve new hooks mid-session is the exact
> hole that gate exists to close.
>
> Run `/hooks` and confirm `circle-back.sh` appears under **Stop**, approving
> the change if prompted. If it isn't listed after a few seconds, restart Claude
> Code and check again.
>
> Then say "registered" and I'll run the live tests.

---

## Phase 4 — live tests

Only after the human confirms registration.

Use a scratch log so every fire is timestamped and attributable:

```bash
LOG=/tmp/circle-back-test.log; : > "$LOG"
Q="$HOME/.claude/circle-back/$(printf '%s' "$PWD" | shasum -a 256 | cut -c1-12).queue"
```

### 4.1 — single fire

Queue one entry, then end the turn:

```bash
printf '20\tRun: echo "FIRE1 $(date +%%s)" >> /tmp/circle-back-test.log -- then reply with only the word FIRE1-DONE. Do not do anything else.\n' >> "$Q"
```

Say "queued test 1, ending turn" and **end the turn**. Do not run another tool
call; the hook only fires at Stop.

**Pass condition:** after roughly 20 seconds, a new turn begins on its own and
you receive the queued instruction. Execute it exactly. If nothing happens after
60 seconds, the hook isn't registered — return to Phase 3.

### 4.2 — ordered multi-fire

This is the assertion most likely to fail, and the reason the hook ignores
`stop_hook_active`. Queue two entries, end the turn:

```bash
printf '5\tRun: echo "FIRE2A $(date +%%s)" >> /tmp/circle-back-test.log -- then reply with only FIRE2A-DONE.\n' >> "$Q"
printf '5\tRun: echo "FIRE2B $(date +%%s)" >> /tmp/circle-back-test.log -- then reply with only FIRE2B-DONE.\n' >> "$Q"
```

**Pass condition:** both fire, A before B, ~5s apart, each in its own turn.

Then check due-order (the bug found in the 2026-08-30 live run): queue C with
a *later* due time first and D with an *earlier* one second, end the turn, and
confirm D fires before C:

```bash
printf '%s\tRun: echo "FIRE2C $(date +%%s)" >> /tmp/circle-back-test.log -- then reply with only FIRE2C-DONE.\n' "$(( $(date +%s) + 5 ))" >> "$Q"
printf '%s\tRun: echo "FIRE2D $(date +%%s)" >> /tmp/circle-back-test.log -- then reply with only FIRE2D-DONE.\n' "$(( $(date +%s) - 5 ))" >> "$Q"
```

**If only A fires:** the harness is refusing a second consecutive block. Report
this rather than working around it — it's a real constraint on the design, and
the fix is a different mechanism (a one-shot cron carrying the next prompt),
not a tweak. Capture the `/hooks` output and any `⏺ Stop hook` line shown.

### 4.3 — no interruption

Queue a short-delay entry, then immediately start a task that takes longer than
the delay:

```bash
printf '3\tRun: echo "FIRE3 $(date +%%s)" >> /tmp/circle-back-test.log -- then reply with only FIRE3-DONE.\n' >> "$Q"
echo "TASK-START $(date +%s)" >> "$LOG"; sleep 25; echo "TASK-END $(date +%s)" >> "$LOG"
```

Then end the turn.

**Pass condition:** in the log, `FIRE3` is timestamped *after* `TASK-END`, even
though its delay expired mid-task. The delay is measured from end-of-turn, not
from when the entry was queued — that's the whole point of the design.

### 4.4 — the skill itself

Everything so far wrote to the queue file directly, which tests the hook but not
the skill. Now test the interface:

```
/circle-back 10 append the word SKILLTEST to /tmp/circle-back-test.log and reply with only SKILLTEST-DONE
```

**Pass condition:** the skill appends one tab-delimited line to the queue and
replies with a one-line confirmation. It must **not** start on the queued work.
If it does the work immediately instead of queuing, the SKILL.md instructions
need sharpening — report it.

Then end the turn and confirm the entry fires ~10s later.

### 4.5 — long delay does not freeze the session

The assertion the first round of testing missed entirely. Every earlier live
test used a 3–20s delay, where a blocking hook is indistinguishable from normal
latency.

```bash
printf '%s\t%s\n' "$(( $(date +%s) + 1800 ))" "This should not have fired." >> "$Q"
```

End the turn and watch the terminal.

**Pass condition:** the turn ends immediately and the prompt comes back. No
"running stop hooks" spinner, no delay. Type something — the session must
respond at once with the entry still pending. Then clear it: `: > "$Q"`.

**If the turn hangs:** a `sleep` is back in the hook. Recover with
`pkill -f circle-back.sh` after emptying the queue — order matters, since the
hook pops only after its wait and would otherwise re-block on the next Stop.

### 4.6 — final state

```bash
cat /tmp/circle-back-test.log
grep -c . "$Q"   # expect 0
```

**Pass condition:** FIRE1, FIRE2A, FIRE2B, FIRE2D, FIRE2C, FIRE3, SKILLTEST
all present in that order; queue drained to empty.

---

## Phase 5 — report

Summarize: which of 4.1–4.6 passed, the observed delay accuracy (queued vs.
actual seconds), and anything surprising. Then clean up:

```bash
rm -f /tmp/circle-back-test.log
```

Leave the install in place unless a test failed.

---

## Rollback

If anything is wrong, remove the registration surgically — this leaves every
other hook and setting exactly as it is:

```bash
S=~/.claude/settings.json
jq '.hooks.Stop |= map(select(([.hooks[]?.command] | any(test("circle-back"))) | not))' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
rm -rf ~/.claude/skills/circle-back ~/.claude/hooks/circle-back.sh ~/.claude/circle-back
```

Restoring `settings.json.bak.<epoch>` wholesale also works, but only if
nothing else has edited `settings.json` since the install (Claude Code writes
to it too, e.g. permission grants) — prefer the jq form.

Then `/hooks` to confirm the Stop entry is gone. **HUMAN GATE** — a restart may
be needed for deregistration to take effect.

Emergency stop without uninstalling: set `"disableAllHooks": true` in
`settings.json`, or empty the queue with `: > "$Q"`.

---

## Known constraints

Carry these into the report; none is a bug to fix in this pass.

- **The hook must never sleep.** Stop hooks run synchronously and Claude Code
  blocks the session until they return. The original design slept for the delay
  inside the hook, which made `/circle-back 1800` a 30-minute freeze — the
  session sat at "running stop hooks" and accepted no input. Entries now carry
  an absolute due time and the hook exits in milliseconds when nothing is due.
  Test group 5 is the regression guard; group 0 fails the build if a bare
  `sleep` reappears in the script.
- Firing is turn-driven, not timer-driven. A due entry is noticed at the first
  turn that *ends* at or after its due time, so nothing fires while the session
  sits idle at the prompt or is closed. Because of this, the skill now uses the
  built-in `CronCreate` tool (`recurring: false`) for any delay above 0, and
  keeps the queue for delay 0 ("after this is done") and for sessions a
  `/goal` or `/loop` keeps continuously busy. On 2026-09-23 a queued
  `/circle-back 1080 /roborev-fix` sat unfired overnight because that session
  never ended another turn. For a prompt that must fire with no session open,
  use the `schedule` skill.
- The queue file is keyed by working directory, but each entry carries the
  session id that queued it and fires only in that session. Before this, a
  roborev reviewer (`claude -p` in the same repo) drained a queued
  `/roborev-fix` and answered it in its review output (2026-09-24). Legacy
  untagged entries fire only in an attended session.
- The hook's select-and-remove holds `flock(2)` on `<queue>.lock` (flock(1)
  where installed, else perl's flock, since stock macOS lacks flock(1)). The
  lock dies with the process, so a killed hook leaves nothing stale. It never
  waits: if the lock is held it skips that Stop. With neither flock(1) nor
  perl installed it never touches the queue (the rewrite is read-modify-write
  and would race); if any entry is due it says so in a systemMessage instead.
  Appends (`printf >>` in
  SKILL.md) don't take the lock, so queuing an entry at the exact moment the
  hook rewrites the file can still drop it. Rare.
- Adoption of a dead session's entries relies on `~/.claude/sessions/*.json`,
  an internal Claude Code file, not a documented interface. It is parsed with
  jq, a pid counts only if it is alive and its start time matches `procStart`
  (compared in UTC), and the registry is trusted only if it lists the calling
  session and every file in it parses (a file caught mid-rewrite could be a
  live session's). If it is missing or untrusted, the hook falls back to adopting
  entries an hour overdue.
- Prompts are one line each; newlines get collapsed. Queued prompts must be
  self-contained, since they arrive with the originating turn out of view.
- `CronCreate` one-shots (the built-in scheduler behind `/loop`) fire only
  while the REPL is idle. In the 2026-08-30 live run a one-shot scheduled for
  19:57 was still pending at 19:59 because a `/goal` Stop hook kept the session
  continuously busy, while queue entries fired at every Stop. The two
  mechanisms are complementary: the queue fires at turn boundaries and never
  while idle; cron fires while idle and never mid-work. Pick by whether the
  user will still be ending turns when the prompt is due.
- Write queued test prompts so they carry their own follow-through. A prompt
  ending "reply with only X and do nothing else" leaves the session parked
  waiting on you — a test-design trap, not a product defect.
