#!/usr/bin/env bash
# circle-back offline test harness.
#
# Exercises the Stop hook and the installer against throwaway directories.
# Touches nothing under your real ~/.claude. Run from the repo root:
#   bash test/offline-tests.sh
#
# Exits 0 if every assertion passes, 1 otherwise.

set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$SRC/hooks/circle-back.sh"
WORK=$(mktemp -d)
PASS=0; FAIL=0

trap 'rm -rf "$WORK"' EXIT

# Hermetic: don't inherit the running Claude Code session's identity. Groups
# 1-9 exercise legacy untagged entries, which fire only in an attended session.
unset CLAUDE_CODE_SESSION_ID
export CLAUDE_CODE_SESSION_ATTENDED=1
export CIRCLE_BACK_SESSIONS_DIR="$WORK/sessions"; mkdir -p "$CIRCLE_BACK_SESSIONS_DIR"

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n'   "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

NOW() { date +%s; }
PAST=1            # an epoch far in the past -> always due
future() { echo $(( $(NOW) + ${1:-3600} )); }

DEFAULT_EVENT='{"cwd":"/tmp","stop_hook_active":false}'
fire() { # queue_path [stdin_json] -> prints hook stdout
  CIRCLE_BACK_QUEUE="$1" bash "$HOOK" <<< "${2:-$DEFAULT_EVENT}"
}

reason_of() { jq -r '.reason // empty' 2>/dev/null; }

# ---------------------------------------------------------------- preflight
head_ "0. preflight"
command -v jq >/dev/null 2>&1 && ok "jq present" || { bad "jq present" "install jq first"; exit 1; }
[ -f "$HOOK" ] && ok "hook script found" || { bad "hook script found" "$HOOK"; exit 1; }
bash -n "$HOOK" && ok "hook parses" || bad "hook parses"
bash -n "$SRC/install.sh" && ok "installer parses" || bad "installer parses"
grep -qE '^[^#]*\bsleep\b' "$HOOK" && bad "hook contains no sleep" "a blocking sleep freezes the session" \
  || ok "hook contains no sleep"

# ------------------------------------------------------------------- hook
head_ "1. empty queue ends the turn normally"
Q="$WORK/empty.queue"; : > "$Q"
OUT=$(fire "$Q"); RC=$?
assert_eq "exit 0"      "0"  "$RC"
assert_eq "no stdout"   ""   "$OUT"

head_ "2. due entries drain oldest-first, one per turn"
Q="$WORK/drain.queue"
printf '%s\tprompt one\n%s\tprompt two\n%s\tprompt three\n' "$PAST" "$PAST" "$PAST" > "$Q"
assert_eq "fire 1" "prompt one"   "$(fire "$Q" | reason_of)"
assert_eq "fire 2" "prompt two"   "$(fire "$Q" | reason_of)"
assert_eq "fire 3" "prompt three" "$(fire "$Q" | reason_of)"
assert_eq "queue now empty" "0" "$(grep -c . "$Q" 2>/dev/null | head -1)"
assert_eq "4th fire silent"  ""  "$(fire "$Q")"

head_ "3. consecutive fires ignore stop_hook_active"
Q="$WORK/active.queue"
printf '%s\tafter block\n' "$PAST" > "$Q"
assert_eq "fires with stop_hook_active=true" "after block" \
  "$(fire "$Q" '{"cwd":"/tmp","stop_hook_active":true}' | reason_of)"

head_ "4. an entry that is not yet due does not fire"
Q="$WORK/pending.queue"; printf '%s\tnot yet\n' "$(future 3600)" > "$Q"
assert_eq "no stdout"     ""  "$(fire "$Q")"
assert_eq "entry retained" "1" "$(grep -c . "$Q")"

head_ "5. REGRESSION: a long delay must not block the session"
# The original design slept for the delay inside the hook. Stop hooks run
# synchronously, so `/circle-back 1800` froze the session for 30 minutes.
Q="$WORK/long.queue"; printf '%s\thalf an hour out\n' "$(future 1800)" > "$Q"
T0=$(NOW); fire "$Q" >/dev/null; ELAPSED=$(( $(NOW) - T0 ))
[ "$ELAPSED" -le 2 ] && ok "returned in ${ELAPSED}s, not 1800s" \
  || bad "returned promptly" "took ${ELAPSED}s -- the hook is blocking again"

head_ "6. a pending entry does not hold up a later due one"
Q="$WORK/jump.queue"
printf '%s\tstill waiting\n%s\tready now\n' "$(future 3600)" "$PAST" > "$Q"
assert_eq "due entry fires past the pending one" "ready now" "$(fire "$Q" | reason_of)"
assert_eq "pending entry retained" "still waiting" "$(cut -f2 "$Q")"

head_ "6b. REGRESSION: due entries fire by due time, not file order"
# Live test 2026-08-30: entry queued first with a later due time fired ahead of
# an entry queued second that was due earlier, because the scan took the first
# due line in file order. SKILL.md promises oldest-due-first.
Q="$WORK/order.queue"
printf '%s\tqueued first, due later\n%s\tqueued second, due earlier\n' "$(( $(NOW) - 10 ))" "$(( $(NOW) - 100 ))" > "$Q"
assert_eq "earlier due fires first" "queued second, due earlier" "$(fire "$Q" | reason_of)"
assert_eq "later due fires next"    "queued first, due later"    "$(fire "$Q" | reason_of)"
Q="$WORK/tie.queue"
printf '%s\ttie A\n%s\ttie B\n' "$PAST" "$PAST" > "$Q"
assert_eq "equal due times keep queue order" "tie A" "$(fire "$Q" | reason_of)"

head_ "7. malformed due time fires immediately"
Q="$WORK/junk.queue"; printf 'abc\tbad due time\n' > "$Q"
assert_eq "still fires" "bad due time" "$(fire "$Q" | reason_of)"

head_ "8. shell-hostile prompts survive intact"
Q="$WORK/evil.queue"
printf '%s\tfix the "auth" bug in C:\\path; echo $HOME `whoami` && rm -rf /\n' "$PAST" > "$Q"
OUT=$(fire "$Q")
case "$OUT" in
  *'$HOME'*whoami*) ok "metacharacters preserved, not expanded" ;;
  *) bad "metacharacters preserved" "$OUT" ;;
esac
[ ! -e "$WORK/pwned" ] && ok "nothing executed" || bad "nothing executed"

head_ "9. queues are scoped per working directory"
export CIRCLE_BACK_DIR="$WORK/scoped"; mkdir -p "$CIRCLE_BACK_DIR"
unset CIRCLE_BACK_QUEUE
hash_of() { printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12; }
printf '%s\tfrom repo A\n' "$PAST" > "$CIRCLE_BACK_DIR/$(hash_of /repo/a).queue"
printf '%s\tfrom repo B\n' "$PAST" > "$CIRCLE_BACK_DIR/$(hash_of /repo/b).queue"
assert_eq "repo A isolated" "from repo A" \
  "$(bash "$HOOK" <<< '{"cwd":"/repo/a"}' | reason_of)"
assert_eq "repo B isolated" "from repo B" \
  "$(bash "$HOOK" <<< '{"cwd":"/repo/b"}' | reason_of)"
unset CIRCLE_BACK_DIR

head_ "9b. entries fire only in the session that queued them"
Q="$WORK/sessions.queue"
MINE=11111111-aaaa-bbbb-cccc-000000000001
THEIRS=22222222-aaaa-bbbb-cccc-000000000002
as() { jq -nc --arg s "$1" '{cwd:"/tmp",session_id:$s}'; }
# THEIRS is a live session: registered under this test shell's pid.
register() { jq -nc --argjson p "$2" --arg s "$1" '{pid:$p,sessionId:$s}' > "$CIRCLE_BACK_SESSIONS_DIR/$2.json"; }
register "$THEIRS" $$
printf '%s\t%s\tfor theirs\n%s\t%s\tfor mine\n' "$PAST" "$THEIRS" "$PAST" "$MINE" > "$Q"
assert_eq "own tagged entry fires, tag stripped" "for mine" \
  "$(fire "$Q" "$(as "$MINE")" | reason_of)"
assert_eq "live session's overdue entry not adopted" "" \
  "$(fire "$Q" "$(as "$MINE")" | reason_of)"
assert_eq "live session's entry retained" "1" "$(grep -c 'for theirs' "$Q")"
printf '%s\tlegacy entry\n' "$PAST" > "$Q"
assert_eq "headless reviewer leaves legacy entry" "" \
  "$(CLAUDE_CODE_SESSION_ATTENDED=0 fire "$Q" "$(as "$THEIRS")" | reason_of)"
assert_eq "attended session fires legacy entry" "legacy entry" \
  "$(fire "$Q" "$(as "$MINE")" | reason_of)"
printf '%s\tdeadbeef\tcheck it\n' "$PAST" > "$Q"
assert_eq "hex word in a legacy prompt is not a session tag" "deadbeef	check it" \
  "$(fire "$Q" "$(as "$MINE")" | reason_of)"

head_ "9c. orphaned entries are adopted once their session is gone"
rm -f "$CIRCLE_BACK_SESSIONS_DIR"/*.json
DEAD=999999; while kill -0 "$DEAD" 2>/dev/null; do DEAD=$((DEAD-1)); done
register "$THEIRS" "$DEAD"            # registered, but the process is gone
printf '%s\t%s\torphaned\n' "$(( $(NOW) - 60 ))" "$THEIRS" > "$Q"
assert_eq "headless session does not adopt an orphan" "" \
  "$(CLAUDE_CODE_SESSION_ATTENDED=0 fire "$Q" "$(as "$MINE")" | reason_of)"
assert_eq "attended session adopts a dead session's due entry" "orphaned" \
  "$(fire "$Q" "$(as "$MINE")" | reason_of)"
assert_eq "adopted orphan removed" "0" "$(grep -c . "$Q" 2>/dev/null | head -1)"
printf '%s\t%s\tunregistered\n' "$(( $(NOW) - 60 ))" "$THEIRS" > "$Q"
rm -f "$CIRCLE_BACK_SESSIONS_DIR"/*.json
assert_eq "unregistered session counts as gone" "unregistered" \
  "$(fire "$Q" "$(as "$MINE")" | reason_of)"
printf '%s\t%s\tno registry, recent\n%s\t%s\tno registry, old\n' \
  "$(( $(NOW) - 60 ))" "$THEIRS" "$(( $(NOW) - 7200 ))" "$THEIRS" > "$Q"
assert_eq "no registry: hour-overdue entry adopted" "no registry, old" \
  "$(CIRCLE_BACK_SESSIONS_DIR="$WORK/nonexistent" fire "$Q" "$(as "$MINE")" | reason_of)"
assert_eq "no registry: recently due entry left alone" "" \
  "$(CIRCLE_BACK_SESSIONS_DIR="$WORK/nonexistent" fire "$Q" "$(as "$MINE")" | reason_of)"

head_ "9d. select-and-remove is locked, never waited on"
printf '%s\tlocked out\n' "$PAST" > "$Q"
mkdir "$Q.lock"
assert_eq "held lock: hook skips this Stop" "" "$(fire "$Q" | reason_of)"
assert_eq "held lock: entry kept" "1" "$(grep -c 'locked out' "$Q")"
touch -t 200001010000 "$Q.lock"
assert_eq "stale lock is broken" "locked out" "$(fire "$Q" | reason_of)"
[ ! -e "$Q.lock" ] && ok "lock released after firing" || bad "lock released after firing"

# -------------------------------------------------------------- installer
head_ "10. installer merges without clobbering existing config"
export HOME="$WORK/home"; mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/settings.json" <<'JSON'
{
  "model": "opus",
  "hooks": {
    "PostToolUse": [{"matcher":"Edit|Write","hooks":[{"type":"command","command":"~/.claude/hooks/pre-existing.sh"}]}],
    "Stop": [{"hooks":[{"type":"command","command":"~/.claude/hooks/pre-existing-stop.sh"}]}]
  }
}
JSON
bash "$SRC/install.sh" >/dev/null 2>&1
S="$HOME/.claude/settings.json"
jq -e . "$S" >/dev/null 2>&1 && ok "settings.json still valid JSON" || bad "settings.json still valid JSON"
assert_eq "unrelated keys preserved"  "opus" "$(jq -r '.model' "$S")"
assert_eq "PostToolUse preserved" "~/.claude/hooks/pre-existing.sh" "$(jq -r '.hooks.PostToolUse[0].hooks[0].command' "$S")"
assert_eq "existing Stop hook preserved" "~/.claude/hooks/pre-existing-stop.sh" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S")"
assert_eq "circle-back registered" "1" \
  "$(jq '[.hooks.Stop[].hooks[] | select(.command|test("circle-back"))] | length' "$S")"
assert_eq "short timeout, hook never sleeps" "10" \
  "$(jq -r '.hooks.Stop[].hooks[] | select(.command|test("circle-back")) | .timeout' "$S")"
[ -f "$HOME/.claude/skills/circle-back/SKILL.md" ] && ok "skill installed" || bad "skill installed"
[ -x "$HOME/.claude/hooks/circle-back.sh" ] && ok "hook installed executable" || bad "hook installed executable"
ls "$HOME/.claude"/settings.json.bak.* >/dev/null 2>&1 && ok "backup written" || bad "backup written"

head_ "11. installer is idempotent"
bash "$SRC/install.sh" >/dev/null 2>&1
assert_eq "no duplicate registration" "1" \
  "$(jq '[.hooks.Stop[].hooks[] | select(.command|test("circle-back"))] | length' "$S")"
assert_eq "Stop group count stable" "2" "$(jq '.hooks.Stop | length' "$S")"
assert_eq "no second backup on a no-op run" "1" "$(ls "$HOME"/.claude/settings.json.bak.* | wc -l | tr -d ' ')"

head_ "12. installer handles a virgin ~/.claude"
export HOME="$WORK/home2"; mkdir -p "$HOME"
bash "$SRC/install.sh" >/dev/null 2>&1
assert_eq "hook registered from scratch" "1" \
  "$(jq '[.hooks.Stop[].hooks[] | select(.command|test("circle-back"))] | length' "$HOME/.claude/settings.json")"

head_ "13. rollback restores the pre-install settings and removes files"
export HOME="$WORK/home"   # the install from group 10/11 lives here
S="$HOME/.claude/settings.json"
jq '.hooks.Stop |= map(select(([.hooks[]?.command] | any(test("circle-back"))) | not))' "$S" > "$S.tmp" && mv "$S.tmp" "$S"
rm -rf "$HOME/.claude/skills/circle-back" "$HOME/.claude/hooks/circle-back.sh" "$HOME/.claude/circle-back"
S="$HOME/.claude/settings.json"
jq -e . "$S" >/dev/null 2>&1 && ok "settings.json valid after rollback" || bad "settings.json valid after rollback"
assert_eq "circle-back unregistered" "0" \
  "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command|test("circle-back"))] | length' "$S")"
assert_eq "pre-existing Stop hook still present" "~/.claude/hooks/pre-existing-stop.sh" "$(jq -r '.hooks.Stop[0].hooks[0].command' "$S")"
assert_eq "unrelated keys survive rollback" "opus" "$(jq -r '.model' "$S")"
[ ! -e "$HOME/.claude/hooks/circle-back.sh" ] && [ ! -e "$HOME/.claude/skills/circle-back" ] \
  && ok "hook and skill files removed" || bad "hook and skill files removed"
BAK=$(ls -t "$HOME"/.claude/settings.json.bak.* | head -1)
assert_eq "newest backup is the pre-install state" "0" \
  "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command|test("circle-back"))] | length' "$BAK")"

# ------------------------------------------------------------------ result
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
