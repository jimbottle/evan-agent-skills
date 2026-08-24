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

- `bash test/offline-tests.sh` reports 0 failures
- `/hooks` lists `circle-back.sh` under Stop
- A single queued prompt fires after its delay, unprompted
- Two queued prompts fire in order across consecutive turns
- A queued prompt does not interrupt a long-running turn
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

Note whether a Stop hook already exists. If one does, flag it — two Stop hooks
run concurrently, and if the existing one is slow it competes with this one's
`sleep`. Not a blocker, but say so before continuing.

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
Expect 32 assertions across 13 groups.

Any failure → stop and report the failing group verbatim. Do not install over a
red harness.

---

## Phase 2 — install

**2.1** Run the installer:

```bash
cd "$SRC" && bash install.sh
```

It copies `SKILL.md` to `~/.claude/skills/circle-back/`, copies the hook to
`~/.claude/hooks/`, `chmod +x`'s it, backs up `settings.json` to
`settings.json.bak.<epoch>`, and appends the Stop hook entry via jq. It's
idempotent — a second run won't duplicate the registration.

**2.2** Verify the install landed:

```bash
jq -e '[.hooks.Stop[].hooks[] | select(.command|test("circle-back"))] | length == 1' ~/.claude/settings.json
test -x ~/.claude/hooks/circle-back.sh && echo "hook executable"
test -f ~/.claude/skills/circle-back/SKILL.md && echo "skill present"
ls -t ~/.claude/settings.json.bak.* | head -1
```

**Pass condition:** `true`, both echoes, and a backup path. Also confirm any
pre-existing hooks noted in 0.3 are still present.

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

### 4.5 — final state

```bash
cat /tmp/circle-back-test.log
grep -c . "$Q"   # expect 0
```

**Pass condition:** FIRE1, FIRE2A, FIRE2B, FIRE3, SKILLTEST all present in
order; queue drained to empty.

---

## Phase 5 — report

Summarize: which of 4.1–4.5 passed, the observed delay accuracy (queued vs.
actual seconds), and anything surprising. Then clean up:

```bash
rm -f /tmp/circle-back-test.log
```

Leave the install in place unless a test failed.

---

## Rollback

If anything is wrong, restore from the installer's backup:

```bash
cp "$(ls -t ~/.claude/settings.json.bak.* | head -1)" ~/.claude/settings.json
rm -rf ~/.claude/skills/circle-back ~/.claude/hooks/circle-back.sh ~/.claude/circle-back
```

Then `/hooks` to confirm the Stop entry is gone. **HUMAN GATE** — a restart may
be needed for deregistration to take effect.

Emergency stop without uninstalling: set `"disableAllHooks": true` in
`settings.json`, or empty the queue with `: > "$Q"`.

---

## Known constraints

Carry these into the report; none is a bug to fix in this pass.

- Delays clamp to `CIRCLE_BACK_MAX_WAIT` (default 1800s) because the hook
  holds a `sleep` open and the registered timeout is 1810s. For longer waits,
  use a one-shot cron task instead — those survive an idle session.
- Session-scoped by nature: the hook only fires when a turn ends, so nothing
  fires while the session is closed or sitting idle at the prompt.
- The queue is keyed by working directory. Two sessions in the same directory
  share one queue and will drain each other's entries. Set
  `CIRCLE_BACK_QUEUE` per session to split them — worth doing if cmux
  workspaces point at the same repo.
- Append-and-pop has a small race window. Queuing an entry at the exact moment
  the hook rewrites the file can drop it. Rare, and not worth locking around
  until it actually bites.
- Prompts are one line each; newlines get collapsed. Queued prompts must be
  self-contained, since they arrive with the originating turn out of view.
