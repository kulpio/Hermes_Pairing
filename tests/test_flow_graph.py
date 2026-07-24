#!/usr/bin/env python3
"""Architecture flow_graph assign + claim target resolution."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


class FlowGraphTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        for k in ("PONG_SESSION", "PONG_SEAT", "PONG_ROLE", "PONG_TOKEN"):
            os.environ.pop(k, None)
        from pong.paths import ensure_layout, pairs_path
        from pong.jsonutil import write_json

        ensure_layout()
        self.sess = "pong-team-flow"
        pair = {
            "schema_version": 2,
            "session": self.sess,
            "conductor": {"id": "c1", "type": "grok", "label": "Orch", "cmd": "grok", "mode": "tmux", "tmux_index": 0},
            "workers": [
                {"id": "w1", "type": "claude", "label": "Bob", "cmd": "claude", "tmux_index": 1},
                {"id": "w2", "type": "hermes", "label": "Lil bob", "cmd": "hermes", "tmux_index": 2, "parent_id": "w1"},
            ],
            "transport_default": "job",
            "flow_graph": {
                "edges": [
                    {"from": "c1", "to": "w1", "kind": "delegate", "dir": "forward", "id": "c1>w1"},
                    {"from": "w1", "to": "w2", "kind": "sub", "dir": "forward", "id": "w1>w2"},
                    {"from": "w2", "to": "c1", "kind": "claim", "dir": "forward", "id": "w2>c1"},
                ]
            },
        }
        write_json(pairs_path(), {self.sess: pair})
        os.environ["PONG_SESSION"] = self.sess

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_orch_cannot_skip_hop(self) -> None:
        from pong.state import load_session_state
        from pong.flow import assert_assign_allowed
        from pong.routing import RouteRefused

        st = load_session_state(self.sess)
        os.environ["PONG_ROLE"] = "conductor"
        with self.assertRaises(RouteRefused) as cm:
            assert_assign_allowed(st, "w2")
        self.assertIn("w1", str(cm.exception))

    def test_orch_can_assign_bob(self) -> None:
        from pong.state import load_session_state
        from pong.flow import assert_assign_allowed

        st = load_session_state(self.sess)
        os.environ["PONG_ROLE"] = "conductor"
        assert_assign_allowed(st, "w1")  # no raise

    def test_bob_can_assign_sub(self) -> None:
        from pong.state import load_session_state
        from pong.flow import assert_assign_allowed

        st = load_session_state(self.sess)
        os.environ["PONG_SEAT"] = "w1"
        assert_assign_allowed(st, "w2")

    def test_claim_targets_orch(self) -> None:
        from pong.state import load_session_state
        from pong.flow import claim_notify_targets

        st = load_session_state(self.sess)
        self.assertEqual(claim_notify_targets(st, "w2"), ["c1"])

    def test_handoff_recap_sub_claims_parent_not_hardcoded_only_c1(self) -> None:
        """w1 claims to c1; w2 (sub) should be told claim to parent path from graph."""
        from pong.state import load_session_state
        from pong.handoff_recap import architecture_recap_for_seat
        from pong.jobs import build_task_prompt

        st = load_session_state(self.sess)
        # Graph: c1→w1, w1→w2, w2→c1 claim — w1 recap should mention assign to w2
        r1 = architecture_recap_for_seat(st, "w1")
        self.assertIn("ARCHITECTURE HANDOFF", r1)
        self.assertIn("Send claim to c1", r1)
        self.assertIn("w2", r1)

        # w2 claims to c1 on this fixture; recap must surface that hop
        r2 = architecture_recap_for_seat(st, "w2")
        self.assertIn("Send claim to c1", r2)

        job = {
            "id": "job_test_recap",
            "session": self.sess,
            "worker": "w1",
            "task": "do the thing",
            "require_claim": True,
            "round": 1,
        }
        prompt = build_task_prompt(job, st)
        self.assertIn("## ARCHITECTURE HANDOFF (seat w1)", prompt)
        self.assertIn("** Send claim to c1 **", prompt)
        self.assertIn("do the thing", prompt)

    def test_default_edges_when_graph_empty(self) -> None:
        from pong.handoff_recap import architecture_recap_for_seat, default_edges_from_state

        st = {
            "session": "pong-team-empty",
            "conductor": {"id": "c1", "type": "grok", "label": "Orch"},
            "workers": [
                {"id": "w1", "type": "claude", "label": "A"},
                {"id": "w2", "type": "claude", "label": "B"},
            ],
            "flow_graph": {"edges": []},
        }
        edges = default_edges_from_state(st)
        kinds = {(e["from"], e["to"], e["kind"]) for e in edges}
        self.assertIn(("c1", "w1", "delegate"), kinds)
        self.assertIn(("w1", "c1", "claim"), kinds)
        self.assertIn(("w1", "w2", "peer"), kinds)
        recap = architecture_recap_for_seat(st, "w1")
        self.assertIn("Send claim to c1", recap)
        self.assertIn("Peer handoff to w2", recap)

    def test_claim_to_parent_when_sub_edge(self) -> None:
        from pong.handoff_recap import architecture_recap_for_seat

        st = {
            "session": "pong-team-sub",
            "conductor": {"id": "c1", "type": "grok", "label": "Orch"},
            "workers": [
                {"id": "w1", "type": "claude", "label": "Parent"},
                {"id": "w0", "type": "claude", "label": "Sub", "parent_id": "w1"},
            ],
            "flow_graph": {
                "edges": [
                    {"from": "c1", "to": "w1", "kind": "delegate"},
                    {"from": "w1", "to": "c1", "kind": "claim"},
                    {"from": "w1", "to": "w0", "kind": "sub"},
                    {"from": "w0", "to": "w1", "kind": "claim"},
                ]
            },
        }
        recap = architecture_recap_for_seat(st, "w0")
        self.assertIn("** Send claim to w1 **", recap)
        self.assertNotIn("** Send claim to c1 **", recap)

    def test_empty_graph_still_enforces_default_road(self) -> None:
        """Empty flow_graph must not mean open assign — defaults are the road."""
        from pong.flow import assert_assign_allowed
        from pong.routing import RouteRefused

        st = {
            "session": "pong-team-road",
            "conductor": {"id": "c1", "type": "grok", "label": "Orch"},
            "workers": [
                {"id": "w1", "type": "claude", "label": "Bob", "mission_role": "coder"},
                {
                    "id": "w2",
                    "type": "claude",
                    "label": "Lil",
                    "mission_role": "reviewer",
                    "parent_id": "w1",
                },
            ],
            "flow_graph": {"edges": []},
        }
        os.environ["PONG_ROLE"] = "conductor"
        os.environ.pop("PONG_SEAT", None)
        # Orch may assign top-level w1
        assert_assign_allowed(st, "w1")
        # Orch may NOT skip hop to sub w2
        with self.assertRaises(RouteRefused) as cm:
            assert_assign_allowed(st, "w2")
        self.assertIn("w1", str(cm.exception))

    def test_job_prompt_includes_identity_and_role_lock(self) -> None:
        from pong.jobs import build_task_prompt
        from pong.state import load_session_state

        st = load_session_state(self.sess)
        # stamp mission roles
        st["workers"][0]["mission_role"] = "coder"
        st["workers"][1]["mission_role"] = "reviewer"
        job = {
            "id": "job_id_test",
            "session": self.sess,
            "worker": "w1",
            "task": "build feature X",
            "require_claim": True,
            "round": 1,
        }
        prompt = build_task_prompt(job, st)
        self.assertIn("SEAT IDENTITY", prompt)
        self.assertIn("Mission role (locked)", prompt)
        self.assertIn("ARCHITECTURE ROAD", prompt)
        self.assertIn("Coder", prompt)
        self.assertIn("build feature X", prompt)


if __name__ == "__main__":
    unittest.main()
