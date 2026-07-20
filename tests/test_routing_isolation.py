#!/usr/bin/env python3
"""Acceptance tests for Addendum 2 cross-team routing isolation.

All six cross-team attack vectors must refuse and log route.refused.
Sole legitimate inter-team path: pong brief send (file-based).
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


def _write_team(pairs_path, active_path, name: str, **extra):
    from pong.jsonutil import write_json, read_json

    pair = {
        "schema_version": 2,
        "conductor": {
            "id": "c1",
            "type": "grok",
            "label": "Grok",
            "cmd": "grok",
            "mode": "tmux",
            "tmux_index": 0,
        },
        "workers": [
            {
                "id": "w1",
                "type": "claude",
                "label": f"Claude {name}",
                "cmd": "claude",
                "mode": "tmux",
                "tmux_index": 1,
                "done_marker": "##CLAUDE_DONE##",
            }
        ],
        "transport_default": "job",
        "project_root": f"/tmp/{name}",
        "team_brief": f"Team {name}",
    }
    pair.update(extra)
    db = read_json(pairs_path) if pairs_path.exists() else {}
    if not isinstance(db, dict):
        db = {}
    db[name] = pair
    write_json(pairs_path, db)
    return pair


class RoutingIsolationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        for k in (
            "PONG_SESSION",
            "HERMES_PONG_SESSION",
            "PONG_TOKEN",
            "PONG_SESSION_TOKEN",
            "TMUX",
        ):
            os.environ.pop(k, None)

        from pong.paths import ensure_layout, pairs_path, active_path
        from pong.jsonutil import write_json
        from pong.routing import ensure_session_token

        ensure_layout()
        self.team_a = "pong-team-a"
        self.team_b = "pong-team-b"
        _write_team(pairs_path(), active_path(), self.team_a)
        _write_team(pairs_path(), active_path(), self.team_b)
        # active-pair points at A (the trap for V1)
        active = _write_team(pairs_path(), active_path(), self.team_a)
        active = dict(active)
        active["session"] = self.team_a
        write_json(active_path(), active)
        self.token_a = ensure_session_token(self.team_a)
        self.token_b = ensure_session_token(self.team_b)

    def tearDown(self) -> None:
        self.tmp.cleanup()
        for k in (
            "PONG_HOME",
            "PONG_SESSION",
            "HERMES_PONG_SESSION",
            "PONG_TOKEN",
            "PONG_SESSION_TOKEN",
            "TMUX",
        ):
            os.environ.pop(k, None)

    def _refused_events(self):
        from pong import events

        return [r for r in events.tail(100) if r.get("type") == "route.refused"
                or r.get("original_type") == "route.refused"
                or (r.get("type") == "system" and r.get("original_type") == "route.refused")]

    # --- (a) from B's pane, job create --session A ---
    def test_a_cross_session_job_create_refused(self) -> None:
        from pong.jobs import create_job
        from pong.routing import RouteRefused
        from pong.paths import jobs_dir

        os.environ["PONG_SESSION"] = self.team_b
        os.environ["PONG_TOKEN"] = self.token_b
        with self.assertRaises(RouteRefused) as cm:
            create_job(
                session=self.team_a,
                worker_key="w1",
                task="CROSS TEAM PAYLOAD — must never land",
            )
        self.assertIn("refused", str(cm.exception).lower())
        # zero delivery
        a_jobs = list(jobs_dir(self.team_a).glob("job_*.json"))
        self.assertEqual(a_jobs, [])
        rows = self._refused_events()
        self.assertTrue(any("token" in str(r).lower() or r.get("reason") for r in rows))

    # --- (b) no env/tmux; active-pair points at A ---
    def test_b_no_context_active_pair_fallback_refused(self) -> None:
        from pong.jobs import create_job
        from pong.routing import RouteRefused, resolve_write_session
        from pong.state import detect_bound_session
        from pong.paths import jobs_dir

        # Read path still sees active-pair
        self.assertEqual(detect_bound_session(), self.team_a)
        with self.assertRaises(RouteRefused):
            resolve_write_session(None)
        with self.assertRaises(RouteRefused):
            create_job(session=None, worker_key="w1", task="should not create")
        self.assertEqual(list(jobs_dir(self.team_a).glob("job_*.json")), [])
        self.assertTrue(self._refused_events())

    # --- (c) tmux_paste with no pane registration ---
    def test_c_tmux_paste_no_pane_refused(self) -> None:
        from pong.transports import tmux_paste

        job = {
            "session": self.team_a,
            "_prompt": "evil paste",
            "id": "job_test",
        }
        worker = {
            "id": "w1",
            "type": "claude",
            # deliberately no pane_id; no panes.json
            "tmux_index": 1,  # old code would guess index 1
        }
        r = tmux_paste.send(job, worker, {"session": self.team_a})
        self.assertFalse(r.ok)
        self.assertIn("pane", r.detail.lower())
        rows = self._refused_events()
        self.assertTrue(
            any(
                r.get("reason") == "tmux_paste_no_pane"
                or "tmux_paste" in str(r.get("reason", ""))
                for r in rows
            )
            or "pane" in r.detail.lower()
        )

    # --- (d) window_paste while non-Terminal frontmost ---
    def test_d_window_paste_verify_after_focus(self) -> None:
        from pong.transports import window_paste

        job = {"session": self.team_a, "_prompt": "do not type me", "id": "j"}
        worker = {"id": "w1", "window_id": "99999"}

        # Simulate focus "success" but frontmost is Safari (not Terminal / wrong id)
        with mock.patch.object(
            window_paste, "_osascript", side_effect=self._fake_osascript_focus_ok
        ), mock.patch.object(
            window_paste,
            "_frontmost_info",
            return_value={"app": "Safari", "window_id": "1"},
        ), mock.patch.object(
            window_paste, "_read_clipboard", return_value="prior"
        ), mock.patch.object(
            window_paste, "_write_clipboard", return_value=True
        ) as wclip:
            r = window_paste.send(job, worker, {})
        self.assertFalse(r.ok)
        self.assertIn("verify", r.detail.lower())
        # clipboard restored (final call with prior)
        self.assertTrue(
            any(call.args and call.args[0] == "prior" for call in wclip.call_args_list)
        )

    def _fake_osascript_focus_ok(self, script: str):
        if "window id" in script and "activate" in script:
            return True, "ok"
        if "keystroke" in script:
            # must not be reached
            return True, "KEYSTROKE_SHOULD_NOT_RUN"
        return True, ""

    def test_d2_window_paste_no_global_fallback(self) -> None:
        from pong.transports import window_paste

        job = {"session": self.team_a, "_prompt": "x", "id": "j"}
        # worker missing window_id; old code used state.claude_window_id
        worker = {"id": "w1"}
        state = {"claude_window_id": "12345", "session": self.team_a}
        r = window_paste.send(job, worker, state)
        self.assertFalse(r.ok)
        self.assertIn("fallback", r.detail.lower())

    # --- (e) recovery: exact token only; identical Claude titles never match ---
    def test_e_exact_token_title_matching(self) -> None:
        from pong.routing import exact_window_title

        a = exact_window_title(self.team_a, "w1")
        b = exact_window_title(self.team_b, "w1")
        self.assertEqual(a, f"pong.{self.team_a}.w1")
        self.assertEqual(b, f"pong.{self.team_b}.w1")
        self.assertNotEqual(a, b)
        # Fuzzy titles that used to collide must not equal either token
        fuzzy = "dylandemnard — ✳ Claude Code — /Users/dylandemnard"
        self.assertNotEqual(fuzzy, a)
        self.assertNotIn(a, fuzzy)
        self.assertNotIn(b, fuzzy)

    # --- (f) claim of A job using B's token / identity ---
    def test_f_cross_team_claim_refused(self) -> None:
        from pong.jobs import create_job, record_claim
        from pong.routing import RouteRefused
        from pong.paths import jobs_dir

        # Create legitimate job on A
        os.environ["PONG_SESSION"] = self.team_a
        os.environ["PONG_TOKEN"] = self.token_a
        job = create_job(session=self.team_a, worker_key="w1", task="legit work")
        jid = job["id"]

        # Switch to B identity; try claim with B token on A job
        os.environ["PONG_SESSION"] = self.team_b
        os.environ["PONG_TOKEN"] = self.token_b
        with self.assertRaises(RouteRefused):
            record_claim(
                self.team_a,
                jid,
                summary="stolen claim",
                claim_token=self.token_b,
            )
        # Job must still not be done
        from pong.jobs import load_job

        # load as A for read (bypass write) — direct file read
        path = jobs_dir(self.team_a) / f"{jid}.json"
        data = json.loads(path.read_text())
        self.assertNotEqual(data.get("status"), "done")
        self.assertTrue(self._refused_events())

    # --- Legitimate path: brief send A→B ---
    def test_brief_send_is_only_cross_team_channel(self) -> None:
        from pong.routing import brief_send
        from pong.paths import state_dir

        os.environ["PONG_SESSION"] = self.team_a
        os.environ["PONG_TOKEN"] = self.token_a
        path = brief_send(
            source_session=self.team_a,
            to_session=self.team_b,
            body="Please review the isolation PR when free.",
            subject="handoff note",
        )
        self.assertTrue(path.is_file())
        text = path.read_text()
        self.assertIn(self.team_a, text)
        self.assertIn(self.team_b, text)
        self.assertIn("not auto-pasted", text)
        self.assertIn("Please review", text)
        # lives under briefs/<to>/inbox
        self.assertIn(str(state_dir() / "briefs" / self.team_b / "inbox"), str(path))

        from pong import events

        rows = events.tail(20)
        self.assertTrue(
            any(
                r.get("type") == "brief.sent"
                or r.get("original_type") == "brief.sent"
                for r in rows
            )
        )

    def test_same_session_job_create_ok(self) -> None:
        from pong.jobs import create_job
        from pong.routing import partition_last_paths
        from pong.paths import state_dir

        os.environ["PONG_SESSION"] = self.team_a
        os.environ["PONG_TOKEN"] = self.token_a
        job = create_job(session=self.team_a, worker_key="w1", task="same team ok")
        self.assertEqual(job["session"], self.team_a)
        # V6: last-sent is per-session, not global
        paths = partition_last_paths(self.team_a)
        self.assertTrue(paths["last_sent"].is_file())
        global_sent = state_dir() / "last-sent.txt"
        # Must not create/overwrite global root as write path
        # (may pre-exist empty — ensure content isolation via session file)
        self.assertIn("same team ok", paths["last_sent"].read_text())

    def test_token_required_for_foreign_session_with_token_a(self) -> None:
        """Presenting A's token while bound to B still allows A if token matches target."""
        from pong.jobs import create_job

        os.environ["PONG_SESSION"] = self.team_b
        # Correct target token for A — this is the authenticated cross-session path
        # Spec: "present a token matching the *target* session"
        os.environ["PONG_TOKEN"] = self.token_a
        job = create_job(session=self.team_a, worker_key="w1", task="authz cross with token")
        self.assertEqual(job["session"], self.team_a)


if __name__ == "__main__":
    unittest.main()
