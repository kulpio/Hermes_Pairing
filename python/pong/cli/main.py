#!/usr/bin/env python3
"""pong — Agent mission control CLI."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

# Allow running from repo without install
_ROOT = Path(__file__).resolve().parents[2]
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))


def _cmd_status(args: argparse.Namespace) -> int:
    from pong.paths import state_dir
    from pong.state import (
        detect_bound_session,
        format_team_roster,
        gate_text,
        load_session_state,
        write_bind_card,
    )

    sess = detect_bound_session(args.session)
    state = load_session_state(sess)
    g, _ = gate_text(sess)
    print(f"state_dir: {state_dir()}")
    print(f"bound_session: {sess or '(none)'}")
    print(f"gate: {g}")
    if state:
        print(f"roster: {format_team_roster(state)}")
        print(f"transport_default: {state.get('transport_default')}")
        print(f"project_root: {state.get('project_root') or '(unset)'}")
        c = state.get("conductor") or {}
        print(f"conductor: {c.get('label')} ({c.get('type')}) cmd={c.get('cmd')}")
        if sess:
            p = write_bind_card(str(sess))
            print(f"bind_card: {p}")
    return 0


def _cmd_gate(args: argparse.Namespace) -> int:
    from pong.ledger import summary
    from pong.state import (
        detect_bound_session,
        format_team_roster,
        gate_text,
        load_session_state,
    )

    sess = detect_bound_session(args.session)
    state = load_session_state(sess)
    line, code = gate_text(sess)
    print(line)
    if state and workers_ok(state):
        print(f"TEAM: {format_team_roster(state)}", file=sys.stderr)
        try:
            s = summary()
            print(
                f"LEDGER: rounds={s['rounds']} accept_rate={s['accept_rate']:.0%} "
                f"reject_streak={s['reject_streak']}",
                file=sys.stderr,
            )
            if s.get("patterns"):
                print("PATTERNS: (see ~/.pong/ledger/patterns.md)", file=sys.stderr)
        except Exception:
            pass
    return code


def workers_ok(state: dict) -> bool:
    from pong.state import workers_from_state

    return bool(workers_from_state(state))


def _route_err(e: BaseException) -> int:
    from pong.routing import RouteRefused

    if isinstance(e, RouteRefused):
        print(f"error: {e}", file=sys.stderr)
        return int(getattr(e, "exit_code", 2) or 2)
    print(f"error: {e}", file=sys.stderr)
    return 2


def _cmd_job_create(args: argparse.Namespace) -> int:
    from pong.jobs import create_job
    from pong.routing import RouteRefused
    from pong.transports.dispatch import dispatch_job, parse_transport_plan

    task = args.task
    if args.file:
        task = Path(args.file).read_text(encoding="utf-8")
    if not task or not str(task).strip():
        print("error: empty task", file=sys.stderr)
        return 2
    extra: dict = {}
    parent = getattr(args, "parent", None)
    if parent:
        extra["parent_worker"] = parent
        extra["ephemeral_seat"] = True
        extra["kind"] = "subagent"
    if getattr(args, "ephemeral", False):
        extra["ephemeral_seat"] = True
        extra["kind"] = extra.get("kind") or "subagent"
    try:
        job = create_job(
            session=args.session,
            worker_key=args.worker,
            task=task.strip(),
            require_claim=not args.no_claim,
            round_n=args.round,
            extra=extra or None,
        )
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    plan = parse_transport_plan(
        str(job["_state"].get("transport_default") or "job+paste"),
        no_paste=args.no_paste,
        headless_only=args.headless,
        paste_only=args.paste_only,
    )
    results = dispatch_job(job, job["_worker"], job["_state"], plan=plan)
    print(f"job_id={job['id']}")
    print(f"session={job['session']} worker={job['worker']} status={job['status']}")
    print(f"prompt={job.get('prompt_path')}")
    for r in results:
        flag = "ok" if r.ok else "FAIL"
        print(f"  transport[{flag}] {r.name}: {r.detail}")
    # Success: notified/done, or job-file-only plan that intentionally stays queued.
    # Failure: paste/headless was attempted and every notify transport failed — do not
    # exit 0 while the conductor believes the worker was pinged (audit SEV-0).
    st = str(job.get("status") or "")
    if st in ("notified", "done"):
        return 0
    notify_results = [r for r in results if r.name != "job_file"]
    if not notify_results:
        # job-file only (--no-paste or transport_default=job)
        return 0 if st == "queued" else 1
    if any(r.ok for r in notify_results):
        return 0
    print(
        "error: job file written but no notify transport succeeded "
        f"(status={st}, error={job.get('error')!r})",
        file=sys.stderr,
    )
    return 2


def _cmd_job_list(args: argparse.Namespace) -> int:
    from pong.jobs import list_jobs
    from pong.routing import resolve_read_session

    sess = resolve_read_session(args.session)
    if not sess:
        print("error: no session", file=sys.stderr)
        return 2
    for j in list_jobs(sess, status=args.status):
        print(
            f"{j.get('id')}\t{j.get('status')}\t{j.get('worker')}\t"
            f"{(j.get('task') or '')[:60].replace(chr(10), ' ')}"
        )
    return 0


def _cmd_job_show(args: argparse.Namespace) -> int:
    from pong.jobs import load_job
    from pong.routing import resolve_read_session

    sess = resolve_read_session(args.session)
    if not sess:
        print("error: no session", file=sys.stderr)
        return 2
    j = load_job(sess, args.job_id)
    if not j:
        print("error: not found", file=sys.stderr)
        return 2
    print(json.dumps(j, indent=2))
    return 0


def _cmd_job_status(args: argparse.Namespace) -> int:
    from pong.jobs import set_status
    from pong.routing import RouteRefused, resolve_write_session

    try:
        sess = resolve_write_session(args.session)
        j = set_status(sess, args.job_id, args.status)
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"{j['id']} → {j['status']}")
    return 0


def _cmd_job_claim(args: argparse.Namespace) -> int:
    from pong.jobs import record_claim
    from pong.routing import RouteRefused, resolve_write_session

    files = [x.strip() for x in (args.files or "").split(",") if x.strip()]
    try:
        sess = resolve_write_session(args.session)
        j = record_claim(
            sess,
            args.job_id,
            files=files,
            commands=args.commands or "",
            summary=args.summary or "",
            raw=args.raw,
        )
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"claimed {j['id']} status={j['status']}")
    return 0


def _cmd_brief_send(args: argparse.Namespace) -> int:
    """Sole legitimate inter-team channel — file drop, never auto-pasted."""
    from pong.routing import RouteRefused, brief_send, resolve_write_session

    body = " ".join(args.body or []).strip()
    if args.file:
        body = Path(args.file).read_text(encoding="utf-8")
    if not body.strip():
        print("error: empty brief body", file=sys.stderr)
        return 2
    if not args.to:
        print("error: --to <session> required", file=sys.stderr)
        return 2
    try:
        src = resolve_write_session(args.session)
        path = brief_send(
            source_session=src,
            to_session=args.to.strip(),
            body=body,
            subject=args.subject,
        )
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"brief_sent path={path}")
    print("note: file-based only — target team must pull; never auto-pasted")
    return 0


def _cmd_pane_register(args: argparse.Namespace) -> int:
    from pong.routing import (
        RouteRefused,
        exact_window_title,
        register_worker_pane,
        resolve_write_session,
    )

    try:
        sess = resolve_write_session(args.session)
        if not args.worker or not args.pane_id:
            print("error: --worker and --pane-id required", file=sys.stderr)
            return 2
        title = args.title or exact_window_title(sess, args.worker)
        path = register_worker_pane(
            sess,
            args.worker,
            pane_id=args.pane_id,
            start_command=args.cmd or "",
            title=title,
        )
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    print(f"pane_registered session={sess} worker={args.worker} pane_id={args.pane_id}")
    print(f"path={path}")
    return 0


def _cmd_token_ensure(args: argparse.Namespace) -> int:
    """Create/show session token (spawn-time / local admin)."""
    from pong.routing import ensure_session_token, resolve_read_session

    sess = resolve_read_session(args.session)
    if not sess:
        print("error: no session", file=sys.stderr)
        return 2
    tok = ensure_session_token(sess)
    if args.print_token:
        print(tok)
    else:
        print(f"session={sess} token_set=yes (use PONG_TOKEN; file chmod 600)")
    return 0


def _cmd_delegate(args: argparse.Namespace) -> int:
    """Compat: create job + transports (like old pong-delegate)."""
    ns = argparse.Namespace(
        session=args.session,
        worker=args.worker,
        task=" ".join(args.prompt) if args.prompt else "",
        file=args.criteria,
        no_claim=False,
        round=1,
        no_paste=args.no_paste,
        headless=args.headless,
        paste_only=args.paste_only,
    )
    if args.dry_run:
        from pong.state import (
            detect_bound_session,
            format_team_roster,
            load_session_state,
            resolve_worker,
        )

        sess = detect_bound_session(args.session)
        state = load_session_state(sess)
        try:
            w = resolve_worker(state, args.worker)
        except Exception as e:
            print(f"[delegate] {e}", file=sys.stderr)
            return 2
        print(f"bound_session={sess}")
        print(f"roster={format_team_roster(state)}")
        print(f"worker={w.get('id')}={w.get('label')}")
        print("DRY-RUN (no job created)")
        return 0
    if not ns.task and not ns.file:
        print("Usage: pong delegate [--worker w1] 'task…'", file=sys.stderr)
        return 2
    # If criteria file, prepend task
    if args.criteria and ns.task:
        body = Path(args.criteria).read_text(encoding="utf-8")
        ns.task = ns.task + "\n\n" + body
        ns.file = None
    return _cmd_job_create(ns)


def _cmd_subagent(args: argparse.Namespace) -> int:
    from pong.routing import RouteRefused, resolve_read_session, resolve_write_session
    from pong import subagents

    cmd = args.subagent_cmd
    try:
        if cmd == "list":
            sess = resolve_read_session(args.session)
            if not sess:
                print("error: no session", file=sys.stderr)
                return 2
            for r in subagents.load_registry(sess):
                print(
                    f"{r.get('id')}\tparent={r.get('parent_id')}\t"
                    f"{r.get('label')}\t{(r.get('task') or '')[:50]}"
                )
            return 0
        sess = resolve_write_session(args.session)
        if cmd == "up":
            row = subagents.register(
                sess,
                parent_id=args.parent,
                label=args.label or args.task or "Subagent",
                task=args.task or args.label or "",
                sub_id=args.id,
                mission_role=args.role or "coder",
            )
            print(f"subagent_id={row['id']}")
            print(f"session={sess} parent={row['parent_id']} label={row['label']}")
            print("# appears on 3D SUB layer until: pong subagent down", row["id"])
            return 0
        if cmd == "down":
            ok = subagents.unregister(sess, args.id)
            if not ok:
                print(f"error: not found: {args.id}", file=sys.stderr)
                return 2
            print(f"removed {args.id}")
            return 0
    except RouteRefused as e:
        return _route_err(e)
    except Exception as e:
        print(f"error: {e}", file=sys.stderr)
        return 2
    return 2


def _cmd_ledger(args: argparse.Namespace) -> int:
    from pong import ledger

    if args.ledger_cmd == "record":
        try:
            row = ledger.record(
                task_id=args.task_id,
                round_n=args.round,
                verdict=args.verdict,
                evidence=args.evidence or "",
                session=args.session,
                worker=args.worker,
            )
        except Exception as e:
            print(f"error: {e}", file=sys.stderr)
            return 2
        print(json.dumps(row))
        return 0
    if args.ledger_cmd == "summary":
        print(json.dumps(ledger.summary(), indent=2))
        return 0
    if args.ledger_cmd == "distill":
        print(ledger.distill())
        return 0
    return 2


def _cmd_migrate(args: argparse.Namespace) -> int:
    from pong.paths import migrate_legacy_to_primary, state_dir

    p = migrate_legacy_to_primary(force=args.force)
    print(f"state_dir={p} (was preferring legacy if present)")
    print(f"active={state_dir()}")
    return 0


def _cmd_snapshot(args: argparse.Namespace) -> int:
    from pong.snapshot import build_snapshot, write_snapshot

    snap = build_snapshot(session=args.session, events_n=args.events)
    path = write_snapshot(snap, session=args.session)
    if args.write_only:
        print(path)
        return 0
    if args.json or True:
        # always JSON for machine/UI consumers; pretty by default
        print(json.dumps(snap, indent=2 if not args.compact else None))
    if args.write:
        print(f"# wrote {path}", file=sys.stderr)
    else:
        # still refresh snapshot.json for panel file watchers
        write_snapshot(snap)
    return 0


def _cmd_events(args: argparse.Namespace) -> int:
    from pong import events

    rows = events.tail(args.n, session=args.session)
    if args.json:
        print(json.dumps(rows, indent=2))
        return 0
    for r in rows:
        print(f"{r.get('ts')}\t{r.get('type')}\t{r.get('session', '')}\t{json.dumps({k:v for k,v in r.items() if k not in ('ts','type','session')})}")
    return 0


def _cmd_check(args: argparse.Namespace) -> int:
    """Foundation self-check for UI readiness."""
    from pong import __version__
    from pong.schema import CONTRACT_VERSION, SCHEMA_VERSION
    from pong.snapshot import build_snapshot
    from pong.paths import state_dir

    snap = build_snapshot(session=args.session)
    problems: list[str] = []
    if snap.get("contract_version") != CONTRACT_VERSION:
        problems.append("contract_version mismatch")
    if "teams" not in snap or not isinstance(snap["teams"], list):
        problems.append("snapshot.teams missing")
    if "ledger" not in snap:
        problems.append("snapshot.ledger missing")
    for t in snap.get("teams") or []:
        if "conductor" not in t or "workers" not in t or "jobs" not in t:
            problems.append(f"team {t.get('session')} incomplete")
    print(f"pong_version={__version__}")
    print(f"schema_version={SCHEMA_VERSION} contract_version={CONTRACT_VERSION}")
    print(f"state_dir={state_dir()}")
    print(f"teams={len(snap.get('teams') or [])} bridge_on={snap.get('bridge_on')}")
    if problems:
        print("FAIL: " + "; ".join(problems))
        return 1
    print("OK foundation ready for UI consumers")
    return 0


def _cmd_architecture(args: argparse.Namespace) -> int:
    """Architecture helpers (recap for a seat)."""
    from pong.flow import effective_edges
    from pong.handoff_recap import architecture_recap_for_seat
    from pong.state import detect_bound_session, load_session_state

    if args.architecture_cmd != "recap":
        print("error: unknown architecture subcommand", file=sys.stderr)
        return 2
    sess = detect_bound_session(args.session)
    if not sess:
        print("error: no session (pass -s / --session)", file=sys.stderr)
        return 2
    state = load_session_state(sess)
    seat = (args.seat or "").strip()
    if not seat:
        print("error: --seat required (e.g. w1, c1)", file=sys.stderr)
        return 2
    if args.json:
        edges = effective_edges(state)
        print(
            json.dumps(
                {
                    "session": sess,
                    "seat": seat,
                    "edges": edges,
                    "recap": architecture_recap_for_seat(state, seat),
                },
                indent=2,
            )
        )
        return 0
    text = architecture_recap_for_seat(state, seat)
    sys.stdout.write(text)
    return 0


def _cmd_seat(args: argparse.Namespace) -> int:
    """Durable seat identity brief."""
    from pong.role_identity import (
        format_architecture_guardrails,
        format_seat_identity,
        seat_mission_role,
    )
    from pong.state import detect_bound_session, load_session_state

    if args.seat_cmd != "brief":
        print("error: unknown seat subcommand", file=sys.stderr)
        return 2
    sess = detect_bound_session(args.session)
    if not sess:
        print("error: no session (pass -s / --session)", file=sys.stderr)
        return 2
    state = load_session_state(sess)
    seat = (args.seat or "").strip()
    if not seat:
        print("error: --seat required (e.g. w1, c1)", file=sys.stderr)
        return 2
    if args.json:
        print(
            json.dumps(
                {
                    "session": sess,
                    "seat": seat,
                    "mission_role": seat_mission_role(state, seat),
                    "identity": format_seat_identity(state, seat),
                    "architecture": format_architecture_guardrails(state, seat),
                },
                indent=2,
            )
        )
        return 0
    sys.stdout.write(format_seat_identity(state, seat))
    sys.stdout.write("\n")
    sys.stdout.write(format_architecture_guardrails(state, seat))
    return 0


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog="pong", description="Pong — agent mission control")
    p.add_argument("-s", "--session", default=None, help="bound team session")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("status", help="bound session + roster")
    s.set_defaults(func=_cmd_status)

    g = sub.add_parser("gate", help="BRIDGE_ON / BRIDGE_OFF")
    g.set_defaults(func=_cmd_gate)

    snap = sub.add_parser("snapshot", help="UI snapshot JSON (contract v1)")
    snap.add_argument("--json", action="store_true", default=True)
    snap.add_argument("--compact", action="store_true")
    snap.add_argument("--write", action="store_true", help="print path note on stderr")
    snap.add_argument("--write-only", action="store_true", help="only write snapshot.json")
    snap.add_argument("--events", type=int, default=40)
    snap.set_defaults(func=_cmd_snapshot)

    ev = sub.add_parser("events", help="tail events.jsonl")
    ev.add_argument("-n", type=int, default=30)
    ev.add_argument("--json", action="store_true")
    ev.set_defaults(func=_cmd_events)

    chk = sub.add_parser("check", help="foundation self-check (UI readiness)")
    chk.set_defaults(func=_cmd_check)

    arch = sub.add_parser(
        "architecture",
        help="architecture helpers (handoff recap from flow_graph)",
    )
    archsub = arch.add_subparsers(dest="architecture_cmd", required=True)
    ar = archsub.add_parser(
        "recap",
        help="print architecture handoff recap for a seat (claim/assign hops)",
    )
    ar.add_argument("--seat", "-w", required=True, help="seat id e.g. w1, c1")
    ar.add_argument("--json", action="store_true", help="edges + recap as JSON")
    ar.set_defaults(func=_cmd_architecture)

    seat_p = sub.add_parser(
        "seat",
        help="seat identity helpers (durable mission role + architecture road)",
    )
    seatsub = seat_p.add_subparsers(dest="seat_cmd", required=True)
    sb = seatsub.add_parser(
        "brief",
        help="print durable seat identity + architecture guardrails",
    )
    sb.add_argument("--seat", "-w", required=True, help="seat id e.g. w1, c1")
    sb.add_argument("--json", action="store_true")
    sb.set_defaults(func=_cmd_seat)

    j = sub.add_parser("job", help="job control plane")
    jsub = j.add_subparsers(dest="job_cmd", required=True)

    jc = jsub.add_parser("create", help="create job + dispatch transports")
    jc.add_argument("--worker", "-w", default=None)
    jc.add_argument("--task", "-t", default="")
    jc.add_argument("--file", "-f", default=None, help="task body from file")
    jc.add_argument("--no-paste", action="store_true", help="job file only")
    jc.add_argument("--headless", action="store_true", help="job + headless CLI")
    jc.add_argument("--paste-only", action="store_true")
    jc.add_argument("--no-claim", action="store_true")
    jc.add_argument("--round", type=int, default=1)
    jc.add_argument(
        "--parent",
        default=None,
        help="parent seat id (w1/c1) — shows as ephemeral subagent on 3D map until done",
    )
    jc.add_argument(
        "--ephemeral",
        action="store_true",
        help="mark job as ephemeral subagent seat on the map",
    )
    jc.set_defaults(func=_cmd_job_create)

    jl = jsub.add_parser("list")
    jl.add_argument("--status", default=None)
    jl.set_defaults(func=_cmd_job_list)

    js = jsub.add_parser("show")
    js.add_argument("job_id")
    js.set_defaults(func=_cmd_job_show)

    jst = jsub.add_parser("status")
    jst.add_argument("job_id")
    jst.add_argument(
        "status",
        choices=[
            "queued",
            "notified",
            "running",
            "done",
            "failed",
            "rejected",
            "human_takeover",
            "cancelled",
        ],
    )
    jst.set_defaults(func=_cmd_job_status)

    jcl = jsub.add_parser("claim")
    jcl.add_argument("job_id")
    jcl.add_argument("--files", default="")
    jcl.add_argument("--commands", default="")
    jcl.add_argument("--summary", default="")
    jcl.add_argument("--raw", default=None)
    jcl.set_defaults(func=_cmd_job_claim)

    d = sub.add_parser("delegate", help="compat: job create + notify")
    d.add_argument("prompt", nargs="*")
    d.add_argument("--worker", "-w", default=None)
    d.add_argument("--no-wait", action="store_true", help="ignored (async by default)")
    d.add_argument("--dry-run", action="store_true")
    d.add_argument("--no-paste", action="store_true")
    d.add_argument("--headless", action="store_true")
    d.add_argument("--paste-only", action="store_true")
    d.add_argument("--criteria", default=None)
    d.set_defaults(func=_cmd_delegate)

    # Ephemeral subagents (3D map live nodes that vanish when done)
    sa = sub.add_parser(
        "subagent",
        help="ephemeral subagents on the 3D map (appear while active, vanish when down)",
    )
    sasub = sa.add_subparsers(dest="subagent_cmd", required=True)
    sau = sasub.add_parser("up", help="register a live subagent under a parent seat")
    sau.add_argument("--parent", "-p", required=True, help="parent seat id (w1, c1, …)")
    sau.add_argument("--label", "-l", default="", help="short name on the map")
    sau.add_argument("--task", "-t", default="", help="what this sub is doing")
    sau.add_argument("--id", default=None, help="stable id (default: eph_xxxxxxxx)")
    sau.add_argument("--role", default="coder", help="mission role glyph")
    sau.set_defaults(func=_cmd_subagent)
    sad = sasub.add_parser("down", help="remove a subagent from the map")
    sad.add_argument("id", help="subagent id from `pong subagent up`")
    sad.set_defaults(func=_cmd_subagent)
    sal = sasub.add_parser("list", help="list live ephemeral subagents")
    sal.set_defaults(func=_cmd_subagent)

    led = sub.add_parser("ledger")
    lsub = led.add_subparsers(dest="ledger_cmd", required=True)
    lr = lsub.add_parser("record")
    lr.add_argument("--task-id", required=True)
    lr.add_argument("--round", type=int, required=True)
    lr.add_argument("--verdict", required=True, choices=["accept", "reject", "escalate"])
    lr.add_argument("--evidence", default="")
    lr.add_argument("--worker", default=None)
    lr.set_defaults(func=_cmd_ledger)
    ls = lsub.add_parser("summary")
    ls.set_defaults(func=_cmd_ledger)
    ld = lsub.add_parser("distill")
    ld.set_defaults(func=_cmd_ledger)

    m = sub.add_parser("migrate", help="copy ~/.hermes-pong → ~/.pong")
    m.add_argument("--force", action="store_true")
    m.set_defaults(func=_cmd_migrate)

    # Inter-team channel (file-based, never auto-pasted)
    br = sub.add_parser("brief", help="inter-team briefs (file channel only)")
    brsub = br.add_subparsers(dest="brief_cmd", required=True)
    brs = brsub.add_parser("send", help="send brief to another team inbox")
    brs.add_argument("--to", required=True, help="target team session")
    brs.add_argument("--subject", default=None)
    brs.add_argument("--file", "-f", default=None, help="body from file")
    brs.add_argument("body", nargs="*", help="brief body text")
    brs.set_defaults(func=_cmd_brief_send)

    # Pane pin registration (V3)
    pn = sub.add_parser("pane", help="worker pane registration")
    pnsub = pn.add_subparsers(dest="pane_cmd", required=True)
    pnr = pnsub.add_parser("register", help="pin worker to immutable tmux pane id")
    pnr.add_argument("--worker", "-w", required=True)
    pnr.add_argument("--pane-id", required=True, help="tmux pane id e.g. %%3")
    pnr.add_argument("--cmd", default="", help="expected start command")
    pnr.add_argument("--title", default=None, help="exact title pong.<session>.<seat>")
    pnr.set_defaults(func=_cmd_pane_register)

    tok = sub.add_parser("token", help="session isolation token")
    toksub = tok.add_subparsers(dest="token_cmd", required=True)
    te = toksub.add_parser("ensure", help="create token file if missing")
    te.add_argument(
        "--print-token",
        action="store_true",
        help="print raw token (for spawn env export)",
    )
    te.set_defaults(func=_cmd_token_ensure)

    return p


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    # propagate top-level session into subcommands
    return int(args.func(args) or 0)


if __name__ == "__main__":
    raise SystemExit(main())
