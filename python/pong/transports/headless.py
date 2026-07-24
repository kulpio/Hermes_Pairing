"""Optional: non-interactive worker CLI (best-effort per vendor)."""

from __future__ import annotations

import shlex
import subprocess
from typing import Any

from .base import TransportResult

# cmd templates: {prompt} replaced; shell=False with list when possible
# NOTE: Never auto-approve host commands (`--yolo` / equivalent). Headless means
# non-interactive only — the user still owns risk via their CLI install defaults.
HEADLESS = {
    "grok": ["grok", "-p", "{prompt}"],
    "claude": ["claude", "-p", "{prompt}"],
    "hermes": ["hermes", "chat", "-q", "{prompt}", "-Q"],
    "codex": ["codex", "exec", "{prompt}"],
}


def send(job: dict[str, Any], worker: dict[str, Any], state: dict[str, Any]) -> TransportResult:
    wtype = str(worker.get("type") or "")
    prompt = job.get("_prompt") or job.get("task") or ""
    cwd = (job.get("project_root") or state.get("project_root") or None) or None
    tmpl = HEADLESS.get(wtype)
    if not tmpl:
        # custom: worker cmd + -p if looks like a path
        cmd0 = (worker.get("cmd") or "").strip()
        if not cmd0:
            return TransportResult("headless", False, f"no headless mapping for type={wtype}")
        argv = shlex.split(cmd0) + ["-p", prompt]
    else:
        argv = []
        for part in tmpl:
            argv.append(part.replace("{prompt}", prompt) if "{prompt}" in part else part)
    try:
        r = subprocess.run(
            argv,
            capture_output=True,
            text=True,
            timeout=600,
            cwd=cwd if cwd else None,
        )
        out = (r.stdout or "") + ("\n" + r.stderr if r.stderr else "")
        ok = r.returncode == 0
        return TransportResult(
            "headless",
            ok,
            f"exit={r.returncode} out_chars={len(out)}",
            meta={"stdout_tail": out[-4000:], "argv0": argv[0]},
        )
    except subprocess.TimeoutExpired:
        return TransportResult("headless", False, "timeout 600s")
    except FileNotFoundError:
        return TransportResult("headless", False, f"command not found: {argv[0]}")
    except Exception as e:
        return TransportResult("headless", False, str(e))
