"""Tests for cx.py. Stdlib only: python3 -m unittest discover -s voice-cx/test"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import unittest
from contextlib import redirect_stdout
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import cx  # noqa: E402


def turn(i: int, ts: str, heard: str, said: str = "Done.", **kw) -> dict:
    return {
        "id": f"t{i}",
        "ts": f"2026-10-06T{ts}+00:00",
        "device": kw.pop("device", "puck"),
        "session": kw.pop("session", "s1"),
        "heard": heard,
        "said": said,
        "layer": kw.pop("layer", "local"),
        "outcome": kw.pop("outcome", "action_done"),
        **kw,
    }


class Repo:
    """A throwaway consuming repo: cx.json + logs/turns.jsonl + cx/."""

    def __init__(self, turns: list[dict]):
        self.dir = tempfile.TemporaryDirectory()
        self.root = Path(self.dir.name)
        (self.root / "logs").mkdir()
        (self.root / "logs" / "turns.jsonl").write_text(
            "".join(json.dumps(t) + "\n" for t in turns)
        )
        self.config = self.root / "cx.json"
        self.config.write_text(json.dumps({"turns": "logs/turns.jsonl", "data_dir": "cx"}))

    def run(self, *argv: str) -> str:
        out = io.StringIO()
        with redirect_stdout(out):
            cx.main(["--config", str(self.config), *argv])
        return out.getvalue()

    def cfg(self):
        return cx.load_config(self.config)


class EpisodeTests(unittest.TestCase):
    def test_gap_splits_and_session_joins(self):
        cfg = dict(cx.DEFAULTS)
        turns = [
            turn(1, "01:00:00", "play the radio"),
            turn(2, "01:04:00", "play the radio station wfpk"),  # same session, 4 min
            turn(3, "01:20:00", "set volume to 20"),  # same session id but 16 min: new
            turn(4, "01:20:30", "louder", session="s2"),  # 30 s: continues regardless
        ]
        eps = cx.build_episodes(turns, cfg)
        self.assertEqual([[t["id"] for t in e.turns] for e in eps], [["t1", "t2"], ["t3", "t4"]])

    def test_devices_never_share_an_episode(self):
        turns = [
            turn(1, "01:00:00", "a", device="kitchen"),
            turn(2, "01:00:05", "b", device="bedroom"),
        ]
        self.assertEqual(len(cx.build_episodes(turns, dict(cx.DEFAULTS))), 2)

    def test_voice_flag_is_split_out_with_its_literal_reason(self):
        turns = [turn(1, "01:00:00", "play wfpk"), turn(2, "01:00:20", " Flag that, I said WFPK.")]
        requests, flags = cx.split_flags(turns, cx.DEFAULTS["flag_pattern"])
        self.assertEqual([t["id"] for t in requests], ["t1"])
        self.assertEqual(flags[0]["reason"], "I said WFPK")

    def test_bare_flag_has_empty_reason(self):
        _, flags = cx.split_flags([turn(1, "01:00:00", "Flag that.")], cx.DEFAULTS["flag_pattern"])
        self.assertEqual(flags[0]["reason"], "")

    def test_flag_word_inside_a_request_is_not_a_flag(self):
        requests, flags = cx.split_flags(
            [turn(1, "01:00:00", "play the flag that waves")], cx.DEFAULTS["flag_pattern"]
        )
        # Anchored at the start: "play the flag ..." is a request.
        self.assertEqual((len(requests), len(flags)), (1, 0))

    def test_flag_attaches_to_latest_prior_turn_even_after_the_session(self):
        cfg = dict(cx.DEFAULTS)
        eps = cx.build_episodes(
            [turn(1, "01:00:00", "a"), turn(2, "01:30:00", "b", session="s9")], cfg
        )
        flag = {"ts": "2026-10-06T01:10:00+00:00", "reason": "wrong station", "channel": "voice"}
        orphans = cx.attach_flags(eps, [flag], cfg)
        self.assertEqual(orphans, [])
        self.assertEqual(eps[0].flags, [flag])

    def test_flag_with_nothing_before_it_is_an_orphan(self):
        cfg = dict(cx.DEFAULTS)
        eps = cx.build_episodes([turn(1, "05:00:00", "a")], cfg)
        orphans = cx.attach_flags(eps, [{"ts": "2026-10-06T01:00:00+00:00", "note": "x"}], cfg)
        self.assertEqual(len(orphans), 1)

    def test_signals(self):
        cfg = dict(cx.DEFAULTS)
        e = cx.build_episodes(
            [
                turn(
                    1,
                    "01:00:00",
                    "set volume to 30",
                    said="Volume set",
                    effects_changed=False,
                    intent="V",
                ),
                turn(2, "01:00:10", "set the volume to 30", said="Volume set", intent="V"),
                turn(
                    3,
                    "01:00:20",
                    "no stop",
                    said="Is there anything else?",
                    layer="llm",
                    latency_s=9.0,
                ),
                turn(4, "01:00:30", "why did you do that"),
            ],
            cfg,
        )[0]
        cx.detect_signals(e, cfg)
        text = " | ".join(e.signals)
        self.assertIn("reported success but nothing observed changed", text)
        self.assertIn("turn 2: repeats turn 1", text)
        self.assertIn("turn 3: correction/cancel", text)
        self.assertIn("answered by the LLM", text)
        self.assertIn("9.0s on llm", text)
        self.assertIn("reply ends in a question", text)
        self.assertEqual(e.user_voice, ["why did you do that"])


class JudgmentTests(unittest.TestCase):
    def test_one_episode_can_hold_several_clusters_and_takes_the_worst(self):
        js = [
            {"episode": "e1", "cluster": "radio", "verdict": "bad"},
            {"episode": "e1", "cluster": "volume", "verdict": "friction"},
            {"episode": "e2", "cluster": "volume", "verdict": "good"},
        ]
        self.assertEqual(cx.episode_verdicts(js), {"e1": "bad", "e2": "good"})

    def test_user_voice_net_catches_frustration_said_sideways(self):
        for text in (
            "Whatever you're doing is not decreasing the volume in any way.",
            "Ah, fuck.",
            "it isn't working",
        ):
            self.assertTrue(cx.EXPERIENCE_LANGUAGE.search(text), text)
        self.assertFalse(cx.EXPERIENCE_LANGUAGE.search("play the radio station wfpk"))


class LoopTests(unittest.TestCase):
    def setUp(self):
        self.repo = Repo(
            [
                turn(1, "01:00:00", "play wfpk", said="Playing it now"),
                turn(2, "01:00:20", "flag that I said WFPK"),
                turn(3, "03:00:00", "set volume to 20", said="Volume set"),
            ]
        )

    def tearDown(self):
        self.repo.dir.cleanup()

    def test_episodes_lists_flagged_first_and_reads_the_flag_literally(self):
        out = self.repo.run("episodes", "--days", "100000")
        self.assertLess(out.index("FLAG (voice"), out.index("No signals"))
        self.assertIn("'I said WFPK'  <- read literally", out)

    def test_bad_verdict_requires_cluster_severity_stage(self):
        with self.assertRaises(SystemExit):
            self.repo.run("judge", "t1", "--verdict", "bad")

    def test_judged_episodes_drop_out_of_the_todo_list(self):
        self.repo.run("judge", "t3", "--verdict", "good")
        out = self.repo.run("episodes", "--days", "100000")
        self.assertNotIn("t3", out)

    def test_cluster_lifecycle(self):
        r = self.repo
        r.run(
            "judge",
            "t1",
            "--verdict",
            "bad",
            "--severity",
            "S1",
            "--stage",
            "routing",
            "--cluster",
            "radio",
            "--fix",
            "template",
            "--wanted",
            "WFPK",
        )
        (c,) = cx.clusters(*reversed(r.cfg()))
        # S1 (8) x flagged boost (3) / template cost (1)
        self.assertEqual((c["status"], c["score"], c["flagged"]), ("open", 24.0, 1))

        r.run("ship", "radio", "--ref", "abc123")
        # Ship time is "now", after every turn: nothing judged since -> shipped.
        self.assertEqual(cx.clusters(*reversed(r.cfg()))[0]["status"], "shipped")

    def test_verified_and_reopened_need_an_episode_after_the_ship(self):
        r = self.repo
        data = r.root / "cx"
        data.mkdir()
        (data / "ships.jsonl").write_text(
            json.dumps({"ts": "2026-10-06T02:00:00+00:00", "cluster": "vol"}) + "\n"
        )
        r.run("judge", "t3", "--verdict", "good", "--cluster", "vol")
        self.assertEqual(cx.clusters(*reversed(r.cfg()))[0]["status"], "verified")
        r.run(
            "judge",
            "t3",
            "--verdict",
            "friction",
            "--severity",
            "S3",
            "--stage",
            "action",
            "--cluster",
            "vol",
        )
        # Newest judgment for an (episode, cluster) wins.
        self.assertEqual(cx.clusters(*reversed(r.cfg()))[0]["status"], "reopened")

    def test_scorecard_counts_a_flag_the_judge_called_good_as_missed(self):
        self.repo.run("judge", "t1", "t3", "--verdict", "good")
        card = json.loads(self.repo.run("scorecard", "--days", "100000"))
        self.assertEqual(card["judge_missed_flags"], ["t1"])
        self.assertEqual(card["flags"], 1)
        self.assertEqual(card["good_pct"], 100.0)

    def test_chat_flag_attaches_by_time(self):
        self.repo.run("flag", "--note", "volume did nothing", "--at", "2026-10-06T03:00:30+00:00")
        out = self.repo.run("episodes", "--days", "100000")
        self.assertIn("FLAG (chat", out)
        self.assertIn("'volume did nothing'", out)


if __name__ == "__main__":
    unittest.main()
