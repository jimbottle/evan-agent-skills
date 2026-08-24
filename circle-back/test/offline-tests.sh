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

ok()   { PASS=$((PASS+1)); printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  \033[31mFAIL\033[0m %s\n'   "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

assert_eq() { # label expected actual
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1" "expected [$2] got [$3]"; fi
}

DEFAULT_EVENT='{"cwd":"/tmp","stop_hook_active":false}'
fire() { # queue_path [stdin_json] -> prints hook stdout
  CIRCLE_BACK_QUEUE="$1" bash "$HOOK" <<< "${2:-$DEFAULT_EVENT}"
}

reason_of() { grep -o '"reason"[^,]*' | sed 's/.*: *"//; s/"$//'; }

# ---------------------------------------------------------------- preflight
head_ "0. preflight"
command -v jq >/dev/null 2>&1 && ok "jq present" || { bad "jq present" "install jq first"; exit 1; }
[ -f "$HOOK" ] && ok "hook script found" || { bad "hook script found" "$HOOK"; exit 1; }
bash -n "$HOOK" && ok "hook parses" || bad "hook parses"
bash -n "$SRC/install.sh" && ok "installer parses" || bad "installer parses"

# ------------------------------------------------------------------- hook
head_ "1. empty queue ends the turn normally"
Q="$WORK/empty.queue"; : > "$Q"
OUT=$(fire "$Q"); RC=$?
assert_eq "exit 0"      "0"  "$RC"
assert_eq "no stdout"   ""   "$OUT"

head_ "2. queue drains oldest-first, one per turn"
Q="$WORK/drain.queue"
printf '0\tprompt one\n0\tprompt two\n0\tprompt three\n' > "$Q"
assert_eq "fire 1" "prompt one"   "$(fire "$Q" | reason_of)"
assert_eq "fire 2" "prompt two"   "$(fire "$Q" | reason_of)"
assert_eq "fire 3" "prompt three" "$(fire "$Q" | reason_of)"
assert_eq "queue now empty" "0" "$(grep -c . "$Q" 2>/dev/null | head -1)"
assert_eq "4th fire silent"  ""  "$(fire "$Q")"

head_ "3. consecutive fires ignore stop_hook_active"
Q="$WORK/active.queue"
printf '0\tafter block\n' > "$Q"
assert_eq "fires with stop_hook_active=true" "after block" \
  "$(fire "$Q" '{"cwd":"/tmp","stop_hook_active":true}' | reason_of)"

head_ "4. delay is honored"
Q="$WORK/delay.queue"; printf '2\twaited\n' > "$Q"
T0=$(date +%s); fire "$Q" >/dev/null; ELAPSED=$(( $(date +%s) - T0 ))
[ "$ELAPSED" -ge 2 ] && ok "slept >=2s (got ${ELAPSED}s)" || bad "slept >=2s" "got ${ELAPSED}s"

head_ "5. delay clamps to CIRCLE_BACK_MAX_WAIT"
Q="$WORK/clamp.queue"; printf '99999\ttoo long\n' > "$Q"
T0=$(date +%s)
CIRCLE_BACK_MAX_WAIT=2 CIRCLE_BACK_QUEUE="$Q" bash "$HOOK" <<< '{"cwd":"/tmp"}' >/dev/null
ELAPSED=$(( $(date +%s) - T0 ))
[ "$ELAPSED" -lt 10 ] && ok "clamped (${ELAPSED}s, not 99999s)" || bad "clamped" "took ${ELAPSED}s"

head_ "6. malformed delay degrades to 0"
Q="$WORK/junk.queue"; printf 'abc\tbad delay\n' > "$Q"
assert_eq "still fires" "bad delay" "$(fire "$Q" | reason_of)"

head_ "7. shell-hostile prompts survive intact"
Q="$WORK/evil.queue"
printf '0\tfix the "auth" bug in C:\\path; echo $HOME `whoami` && rm -rf /\n' > "$Q"
OUT=$(fire "$Q")
case "$OUT" in
  *'$HOME'*whoami*) ok "metacharacters preserved, not expanded" ;;
  *) bad "metacharacters preserved" "$OUT" ;;
esac
[ ! -e "$WORK/pwned" ] && ok "nothing executed" || bad "nothing executed"

head_ "8. kill mid-sleep leaves the entry queued"
Q="$WORK/survive.queue"; printf '30\tshould survive\n' > "$Q"
CIRCLE_BACK_QUEUE="$Q" bash "$HOOK" <<< '{"cwd":"/tmp"}' >/dev/null 2>&1 &
HPID=$!; sleep 1; kill -9 $HPID 2>/dev/null; wait $HPID 2>/dev/null
assert_eq "entry retained" "1" "$(grep -c . "$Q")"

head_ "9. queues are scoped per working directory"
export CIRCLE_BACK_DIR="$WORK/scoped"; mkdir -p "$CIRCLE_BACK_DIR"
unset CIRCLE_BACK_QUEUE
hash_of() { printf '%s' "$1" | { shasum -a 256 2>/dev/null || sha256sum; } | cut -c1-12; }
printf '0\tfrom repo A\n' > "$CIRCLE_BACK_DIR/$(hash_of /repo/a).queue"
printf '0\tfrom repo B\n' > "$CIRCLE_BACK_DIR/$(hash_of /repo/b).queue"
assert_eq "repo A isolated" "from repo A" \
  "$(bash "$HOOK" <<< '{"cwd":"/repo/a"}' | reason_of)"
assert_eq "repo B isolated" "from repo B" \
  "$(bash "$HOOK" <<< '{"cwd":"/repo/b"}' | reason_of)"
unset CIRCLE_BACK_DIR

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
assert_eq "timeout exceeds max wait" "1810" \
  "$(jq -r '.hooks.Stop[].hooks[] | select(.command|test("circle-back")) | .timeout' "$S")"
[ -f "$HOME/.claude/skills/circle-back/SKILL.md" ] && ok "skill installed" || bad "skill installed"
[ -x "$HOME/.claude/hooks/circle-back.sh" ] && ok "hook installed executable" || bad "hook installed executable"
ls "$HOME/.claude"/settings.json.bak.* >/dev/null 2>&1 && ok "backup written" || bad "backup written"

head_ "11. installer is idempotent"
bash "$SRC/install.sh" >/dev/null 2>&1
assert_eq "no duplicate registration" "1" \
  "$(jq '[.hooks.Stop[].hooks[] | select(.command|test("circle-back"))] | length' "$S")"
assert_eq "Stop group count stable" "2" "$(jq '.hooks.Stop | length' "$S")"

head_ "12. installer handles a virgin ~/.claude"
export HOME="$WORK/home2"; mkdir -p "$HOME"
bash "$SRC/install.sh" >/dev/null 2>&1
assert_eq "hook registered from scratch" "1" \
  "$(jq '[.hooks.Stop[].hooks[] | select(.command|test("circle-back"))] | length' "$HOME/.claude/settings.json")"

# ------------------------------------------------------------------ result
printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
