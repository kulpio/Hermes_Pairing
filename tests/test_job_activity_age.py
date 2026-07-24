#!/usr/bin/env python3
"""Activity-age filters and stale-notified auto-cancel for map seat calm."""

from __future__ import annotations

import os
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "python"))


class JobActivityAgeTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        os.environ["PONG_HOME"] = self.tmp.name
        from pong.jsonutil import write_json
        from pong.paths import active_path, ensure_layout, pairs_path

        ensure_layout()
        pair = {
            "schema_version": 2,
            "conductor": {
                "id": "c1",
                "type": "grok",
                "label": "Grok Build",
                "cmd": "grok",
                "mode": "tmux",
                "tmux_index": 0,
            },
            "workers": [
                {
                    "id": "w1",
                    "type": "claude",
                    "label": "Builder",
                    "cmd": "claude",
                    "mode": "tmux",
                    "tmux_index": 1,
                    "done_marker": "##WORKER_DONE##",
                }
            ],
            "transport_default": "job",
            "project_root": "/tmp/proj",
            "team_brief": "test",
            "autonomy_level": "full",
        }
        write_json(pairs_path(), {"pong-team": pair})
        active = dict(pair)
        active["session"] = "pong-team"
        write_json(active_path(), active)
        os.environ["PONG_SESSION"] = "pong-team"

    def tearDown(self) -> None:
        self.tmp.cleanup()
        os.environ.pop("PONG_HOME", None)
        os.environ.pop("PONG_SESSION", None)

    def _plant_job(self, *, status: str, age_s: float, job_id: str = "job_age_test") -> dict:
        """Write job JSON with backdated timestamps (save_job would clobber updated_at)."""
        from pong.jsonutil import write_json
        from pong.paths import ensure_layout, jobs_dir

        ensure_layout("pong-team")
        now = time.time()
        ts = now - age_s
        job = {
            "id": job_id,
            "session": "pong-team",
            "worker": "w1",
            "worker_type": "claude",
            "worker_label": "Builder",
            "status": status,
            "task": "zombie work",
            "project_root": "/tmp/proj",
            "team_brief": "test",
            "acceptance": [],
            "done_marker": "##WORKER_DONE##",
            "require_claim": True,
            "human_takeover": False,
            "round": 1,
            "created_at": ts,
            "updated_at": ts,
            "claim": None,
            "error": None,
            "transports_used": [],
            "prompt_path": None,
            "schema_version": 2,
        }
        write_json(jobs_dir("pong-team") / f"{job_id}.json", job)
        return job

    def test_fresh_notified_is_activity_running(self) -> None:
        from pong.jobs import activity_open_jobs, is_activity_fresh
        from pong.snapshot import _worker_status_hint

        self._plant_job(status="notified", age_s=60, job_id="job_fresh_notif")
        self.assertTrue(is_activity_fresh({"status": "notified", "updated_at": time.time() - 60}))
        act = activity_open_jobs("pong-team")
        self.assertEqual(len(act), 1)
        hint, n = _worker_status_hint("pong-team", "w1")
        self.assertEqual(hint, "running")
        self.assertGreaterEqual(n, 1)

    def test_notified_30m_not_active_for_status_hint(self) -> None:
        from pong.jobs import activity_open_jobs, is_activity_fresh, open_jobs
        from pong.snapshot import _worker_status_hint

        # 30 minutes > 20m notified activity threshold, < 2h auto-cancel
        self._plant_job(status="notified", age_s=30 * 60, job_id="job_stale_soft")
        self.assertFalse(
            is_activity_fresh(
                {"status": "notified", "updated_at": time.time() - 30 * 60}
            )
        )
        self.assertEqual(len(open_jobs("pong-team")), 1)
        self.assertEqual(len(activity_open_jobs("pong-team")), 0)
        hint, n = _worker_status_hint("pong-team", "w1")
        self.assertEqual(hint, "idle")
        self.assertEqual(n, 0)

    def test_notified_3h_auto_cancelled(self) -> None:
        from pong.jobs import cancel_stale_abandoned_jobs, load_job, open_jobs

        self._plant_job(status="notified", age_s=3 * 3600, job_id="job_stale_hard")
        cancelled = cancel_stale_abandoned_jobs("pong-team")
        self.assertIn("job_stale_hard", cancelled)
        reloaded = load_job("pong-team", "job_stale_hard")
        self.assertEqual(reloaded.get("status"), "cancelled")
        self.assertEqual(reloaded.get("cancel_reason"), "stale_notified")
        self.assertEqual(len(open_jobs("pong-team")), 0)

    def test_running_fresh_is_active(self) -> None:
        from pong.jobs import is_activity_fresh
        from pong.snapshot import _worker_status_hint

        self._plant_job(status="running", age_s=5 * 60, job_id="job_run_fresh")
        self.assertTrue(
            is_activity_fresh({"status": "running", "updated_at": time.time() - 5 * 60})
        )
        hint, n = _worker_status_hint("pong-team", "w1")
        self.assertEqual(hint, "running")
        self.assertGreaterEqual(n, 1)

    def test_running_50m_not_activity_but_not_auto_cancelled(self) -> None:
        from pong.jobs import (
            activity_open_jobs,
            cancel_stale_abandoned_jobs,
            is_activity_fresh,
            load_job,
            open_jobs,
        )

        # 50m > 45m activity max; < 24h cancel
        self._plant_job(status="running", age_s=50 * 60, job_id="job_run_old")
        self.assertFalse(
            is_activity_fresh({"status": "running", "updated_at": time.time() - 50 * 60})
        )
        self.assertEqual(len(activity_open_jobs("pong-team")), 0)
        self.assertEqual(len(open_jobs("pong-team")), 1)
        cancelled = cancel_stale_abandoned_jobs("pong-team")
        self.assertEqual(cancelled, [])
        self.assertEqual(load_job("pong-team", "job_run_old").get("status"), "running")

    def test_summarize_splits_open_and_activity_open(self) -> None:
        from pong.jobs import summarize_jobs

        self._plant_job(status="notified", age_s=30 * 60, job_id="job_sum")
        s = summarize_jobs("pong-team")
        self.assertEqual(s["counts"]["open"], 1)
        self.assertEqual(s["counts"]["activity_open"], 0)
        self.assertEqual(len(s["open"]), 1)
        self.assertEqual(len(s["activity_open"]), 0)


if __name__ == "__main__":
    unittest.main()
