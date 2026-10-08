# Adapters: connecting an assistant to voice-cx

`cx.py` knows nothing about any platform. An adapter is whatever code in the
consuming repo turns that platform's logs into **turn records**, plus a
`cx.json` and a device-side flag phrase.

## The turn record

One JSON object per line, one line per user utterance on a real device (leave
out your own test runs — or mark them so the judge can `skip` them):

| field | type | meaning |
| --- | --- | --- |
| `id` | str | stable unique id (the platform's run id). The first turn's id is the episode id. |
| `ts` | ISO-8601 | when the turn started, with a timezone |
| `device` | str \| null | which microphone. Episodes never span devices. |
| `session` | str \| null | the platform's conversation id, if it has one. Turns in the same session stay in one episode across gaps up to `session_max_gap_seconds`. |
| `heard` | str | the transcript ("" when nothing was transcribed) |
| `said` | str | what the assistant spoke back |
| `layer` | `local` \| `llm` \| `none` | deterministic handler, language model, or neither |
| `outcome` | str \| null | `action_done`, `query_answer`, `error`, … (the platform's own words are fine) |
| `intent` | str \| null | what handled it (intent name, trigger template) |
| `effects_changed` | bool \| null | **only** `false` when you can prove the targeted thing did not change; otherwise null. Never guess. |
| `effects` | str \| null | short human-readable account of what visibly changed during/after the turn ("speaker: state 'idle'->'playing', title None->'WFPK'"), or "nothing changed" |
| `latency_s` | float \| null | the delay you want held to `latency_budget_s` (say which stage in `cx.json`'s comment) |
| `error` | str \| null | platform error code |
| `note` | str \| null | anything else the judge should see (the platform's own bucket, tool calls the LLM made, STT time) |

`effects` is the field that matters most. Without it the judge can only grade
what the assistant *said*, and the most damaging failures are the ones where
what it said was untrue. Get state changes from the platform's history/recorder
for the targeted entities in a window after the turn.

## cx.json

Paths are relative to the file. Everything has a default (see `DEFAULTS` in `cx.py`).

```json
{
  "turns": "logs/turns.jsonl",
  "data_dir": "cx",
  "session_gap_seconds": 120,
  "session_max_gap_seconds": 600,
  "flag_lookback_seconds": 1800,
  "latency_budget_s": {"local": 2.0, "llm": 8.0},
  "flag_pattern": "^\\W*flag (?:that|this|it)\\b[\\s,.:;!-]*(?P<reason>.*?)[\\s.!?]*$"
}
```

Keep the raw turn file out of git (it is household speech). **Commit
`data_dir`** — judgments, flags, ships and scorecards are the loop's memory.

## The flag phrase on the device

Pick a phrase that nobody says by accident and that the recogniser hears
reliably; the default is **"flag that"**, optionally followed by what went
wrong ("flag that, I said WFPK"). Handle it on the device's *deterministic*
path so it works even when the LLM is the problem, have it change nothing, and
answer with a short acknowledgement ("Flagged."). The turn then appears in the
turn log like any other; `cx.py` recognises it by `flag_pattern`, removes it
from the episode, and attaches it (with the reason, read literally) to the last
thing that happened before it.

If the platform cannot log the flag turn, have the handler write a flag record
to `<data_dir>/flags.jsonl` instead (`{"ts", "channel", "note", "at"?, "episode"?}`).

## The consuming repo's CLAUDE.md

Add a short section that says: this repo uses the voice-cx skill, where it lives
(`~/Projects/personal/claude-skills/voice-cx`, installed at
`~/.claude/skills/voice-cx`), the exact `CX` command line with this repo's
config, how to refresh the turn file, and the repo's own gates and deploy rules
that §6 of the skill defers to.

## Reference adapter: Home Assistant (Voice PE / Assist)

`~/Projects/personal/home-assistant-pi`:

- `tools/pipeline_log.py` (runs inside HA Core) persists every Assist pipeline
  run with recorder history of the watched entities.
- `voice/collector/collect.py pull` copies it off the Pi; `export-turns` maps it
  onto this schema (`cx_turn()`), including `effects` and `effects_changed`.
- `automations/voice_flag.yaml` is the "flag that" conversation trigger.
- `voice/cx.json` is the config; `voice/cx/` the committed loop state.
