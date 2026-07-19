#!/usr/bin/env python3
"""pong-ledger.py — adversarial verdict ledger for Hermes Pong.

CLI + importable module. Flat files only, under ~/.hermes-pong/ledger/:
  verdicts.jsonl — append-only verdict records (one JSON object per line)
  patterns.md    — distilled reject patterns (auto section between markers)

Every JSONL line carries "schema": 1 so the format can evolve without
migrations. Corrupt/partial lines are skipped with a stderr warning.

Recording is pairing-scoped: `record` refuses unless a HermesPong pair is
active (a `session` in active-pair.json). Reading (stats/patterns/distill)
is always allowed — it's the user's local audit surface.

Subcommands:
  record   — append one verdict line
  stats    — one-line summary (rounds, accept rate, reject streak, last)
  patterns — top recurring reject themes
  distill  — regenerate the auto section of patterns.md
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from datetime import datetime, timezone
from pathlib import Path

SCHEMA = 1
STATE_DIR = Path.home() / ".hermes-pong"
LEDGER_DIR = STATE_DIR / "ledger"
VERDICTS = LEDGER_DIR / "verdicts.jsonl"
PATTERNS_MD = LEDGER_DIR / "patterns.md"
ACTIVE_PAIR = STATE_DIR / "active-pair.json"

VALID_VERDICTS = ("accept", "reject", "escalate")

AUTO_START = "<!-- auto:start -->"
AUTO_END = "<!-- auto:end -->"

# Keyword clusters for reject evidence. Deterministic: fixed order, plain
# substring matches on lowercased evidence. One reject may hit several.
CLUSTERS = [
    ("tests", "claims tests pass without running them / test failures",
     ("test", "pytest", "assert", "unittest", "coverage")),
    ("scope", "edits outside task scope",
     ("scope", "unrelated", "outside", "out of scope", "extra file")),
    ("error-handling", "skips error handling",
     ("error handling", "exception", "unhandled", "traceback", "crash",
      "file i/o", "try/except", "no fallback")),
    ("imports", "import/dependency breakage",
     ("import", "modulenotfound", "dependency", "missing module",
      "no module named")),
    ("claim-mismatch", "claim does not match evidence",
     ("claim", "mismatch", "did not run", "didn't run", "not actually",
      "no evidence", "never ran")),
]


def _now_ts() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _active_session() -> str | None:
    """Session name of the active HermesPong pair, or None if not paired."""
    try:
        if ACTIVE_PAIR.exists():
            d = json.loads(ACTIVE_PAIR.read_text())
            if d.get("session"):
                return str(d["session"])
    except Exception:
        pass
    return None


def read_entries() -> list[dict]:
    """All valid ledger entries, oldest first. Corrupt lines are skipped."""
    if not VERDICTS.exists():
        return []
    entries = []
    for n, line in enumerate(VERDICTS.read_text().splitlines(), 1):
        line = line.strip()
        if not line:
            continue
        try:
            d = json.loads(line)
            if not isinstance(d, dict):
                raise ValueError("not an object")
            entries.append(d)
        except Exception as e:
            print(f"[ledger] skipping corrupt line {n}: {e}", file=sys.stderr)
    return entries


def record(task_id: str, round_n: int, verdict: str, evidence: str = "",
           claim: dict | None = None, checks: list | None = None) -> dict:
    """Append one verdict line (O_APPEND, single write). Requires an active pair."""
    if verdict not in VALID_VERDICTS:
        raise ValueError(f"verdict must be one of {VALID_VERDICTS}")
    session = _active_session()
    if session is None:
        raise RuntimeError(
            "no active HermesPong pair — verdicts can only be recorded while "
            "a pair is active (open Hermes Pong → New pair or Link)"
        )
    entry = {
        "schema": SCHEMA,
        "ts": _now_ts(),
        "pair": session,
        "task_id": task_id,
        "round": round_n,
        "verdict": verdict,
        "claim": claim or {},
        "checks": checks or [],
        "evidence": evidence,
    }
    LEDGER_DIR.mkdir(parents=True, exist_ok=True)
    line = json.dumps(entry, ensure_ascii=False) + "\n"
    fd = os.open(VERDICTS, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    try:
        os.write(fd, line.encode("utf-8"))
    finally:
        os.close(fd)
    return entry


def stats_line() -> str | None:
    """One-line summary, or None if the ledger is empty/missing."""
    entries = read_entries()
    if not entries:
        return None
    total = len(entries)
    accepts = sum(1 for e in entries if e.get("verdict") == "accept")
    rate = round(100 * accepts / total)
    streak = 0
    for e in reversed(entries):
        if e.get("verdict") == "reject":
            streak += 1
        else:
            break
    last = entries[-1]
    last_bit = f"{last.get('verdict', '?')} ({last.get('task_id', '?')} r{last.get('round', '?')})"
    return f"{total} rounds | accept {rate}% | reject streak {streak} | last: {last_bit}"


def top_patterns(top: int = 3) -> list[tuple[str, int]]:
    """Top recurring reject themes as (label, count), deterministic order."""
    rejects = [e for e in read_entries() if e.get("verdict") == "reject"]
    counts = {label: 0 for _, label, _ in CLUSTERS}
    other = 0
    for e in rejects:
        ev = str(e.get("evidence", "")).lower()
        hit = False
        for _, label, keywords in CLUSTERS:
            if any(k in ev for k in keywords):
                counts[label] += 1
                hit = True
        if not hit:
            other += 1
    ranked = [(label, c) for _, label, _ in CLUSTERS if (c := counts[label]) > 0]
    ranked.sort(key=lambda x: (-x[1], x[0]))
    if other:
        ranked.append(("other (uncategorized)", other))
    return ranked[:top]


def patterns_line(top: int = 3, counts: bool = False) -> str | None:
    """Single-line 'PATTERNS' body, or None when there are no rejects yet."""
    ranked = top_patterns(top)
    if not ranked:
        return None
    if counts:
        return "  ".join(f"{i}) {label} (x{c})" for i, (label, c) in enumerate(ranked, 1))
    return "  ".join(f"{i}) {label}" for i, (label, _) in enumerate(ranked, 1))


def distill() -> Path:
    """Regenerate the auto section of patterns.md between the markers."""
    entries = read_entries()
    rejects = sum(1 for e in entries if e.get("verdict") == "reject")
    ranked = top_patterns(top=len(CLUSTERS) + 1)
    lines = [
        "_Auto-generated by `pong-ledger.py distill` — do not edit inside the markers._",
        "",
    ]
    if ranked:
        lines += [f"- {label}: {c}" for label, c in ranked]
    else:
        lines.append("- no reject patterns yet")
    lines += ["", f"({rejects} rejects analyzed of {len(entries)} verdicts)"]
    auto = "\n".join(lines)
    block = f"{AUTO_START}\n{auto}\n{AUTO_END}"

    LEDGER_DIR.mkdir(parents=True, exist_ok=True)
    if PATTERNS_MD.exists():
        text = PATTERNS_MD.read_text()
        if AUTO_START in text and AUTO_END in text:
            head, rest = text.split(AUTO_START, 1)
            _, tail = rest.split(AUTO_END, 1)
            text = head + block + tail
        else:
            text = text.rstrip() + "\n\n" + block + "\n"
    else:
        text = (
            "# Hermes Pong — reject patterns\n"
            "\n"
            "Hand-written notes go here (above the markers) — `distill` never touches them.\n"
            "Hermes: rewrite this prose section as you learn; the auto section below just counts.\n"
            "\n"
            + block + "\n"
        )
    PATTERNS_MD.write_text(text)
    return PATTERNS_MD


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    rec = sub.add_parser("record", help="append one verdict line")
    rec.add_argument("--task-id", required=True)
    rec.add_argument("--round", type=int, required=True)
    rec.add_argument("--verdict", required=True, choices=VALID_VERDICTS)
    rec.add_argument("--evidence", default="")
    rec.add_argument("--claim-json", default=None,
                     help="JSON object: {files, commands, tests_tail}")
    rec.add_argument("--checks-json", default=None,
                     help="JSON array: [{cmd, exit, pass}]")

    sub.add_parser("stats", help="one-line ledger summary")

    pat = sub.add_parser("patterns", help="top recurring reject themes")
    pat.add_argument("--top", type=int, default=3)

    sub.add_parser("distill", help="regenerate auto section of patterns.md")

    args = ap.parse_args()

    if args.cmd == "record":
        claim = checks = None
        try:
            if args.claim_json:
                claim = json.loads(args.claim_json)
            if args.checks_json:
                checks = json.loads(args.checks_json)
        except Exception as e:
            print(f"[ledger] bad --claim-json/--checks-json: {e}", file=sys.stderr)
            return 1
        try:
            entry = record(args.task_id, args.round, args.verdict,
                           evidence=args.evidence, claim=claim, checks=checks)
        except RuntimeError as e:
            print(f"[ledger] refused: {e}", file=sys.stderr)
            return 2
        print(f"[ledger] recorded {entry['verdict']} ({entry['task_id']} r{entry['round']}) → {VERDICTS}")
        return 0

    if args.cmd == "stats":
        line = stats_line()
        print(line if line else "no verdicts recorded")
        return 0

    if args.cmd == "patterns":
        ranked = top_patterns(args.top)
        if not ranked:
            print("no reject patterns yet")
            return 0
        for i, (label, c) in enumerate(ranked, 1):
            print(f"{i}) {label} (x{c})")
        return 0

    if args.cmd == "distill":
        path = distill()
        print(f"[ledger] distilled → {path}")
        return 0

    return 1


if __name__ == "__main__":
    raise SystemExit(main())
