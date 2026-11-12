#!/usr/bin/env python3
"""Report token usage and estimated cost for a Hermes kanban task.

Joins the kanban run's worker session id to the profile's `session_model_usage`
table, then prints a markdown summary suitable for a PR or merge comment.

Usage:
    python bin/kanban-usage.py t_69f3c047
    python bin/kanban-usage.py t_69f3c047 --markdown usage.md --json usage.json
    python bin/kanban-usage.py --sweep --ledger tmp/usage/ledger.jsonl --kanban-comment
    python bin/kanban-usage.py t_69f3c047 --comment-pr 12

--ledger and --kanban-comment are local-only: a JSONL file on disk and a comment in the
board's own SQLite. Nothing is published to GitHub unless --comment-pr is passed explicitly.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sqlite3
import sys
import tempfile
from pathlib import Path

COLUMNS = (
    "session_id", "model", "task", "api_call_count", "input_tokens",
    "output_tokens", "cache_read_tokens", "cache_write_tokens",
    "reasoning_tokens", "estimated_cost_usd", "cost_status", "cost_source",
)


def run_json(args: list[str]) -> list[dict]:
    proc = subprocess.run(args, capture_output=True, text=True, encoding="utf-8")
    if proc.returncode != 0:
        raise SystemExit(f"command failed: {' '.join(args)}\n{proc.stderr.strip()}")
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError as exc:
        raise SystemExit(f"could not parse JSON from {' '.join(args)}: {exc}")
    return data if isinstance(data, list) else [data]


def hermes() -> str:
    exe = shutil.which("hermes")
    if not exe:
        raise SystemExit("hermes executable not found on PATH")
    return exe


def resolve_gh(preferred: str = "gh") -> str | None:
    """Locate gh, including the Windows installer default that a fresh shell may not have on PATH."""
    for candidate in (preferred, "gh"):
        found = shutil.which(candidate)
        if found:
            return found
    fallback = Path("C:/Program Files/GitHub CLI/gh.exe")
    return str(fallback) if fallback.exists() else None


def profile_db(profile: str) -> Path:
    """Ask the CLI where the profile's config lives, then sit next to it."""
    proc = subprocess.run(
        [hermes(), "-p", profile, "config", "path"],
        capture_output=True, text=True, encoding="utf-8",
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        raise SystemExit(f"could not resolve config path for profile {profile!r}")
    return Path(proc.stdout.strip().splitlines()[-1]).parent / "state.db"


def worker_session_id(board: str, task: str) -> str:
    runs = run_json([hermes(), "kanban", "--board", board, "runs", task, "--json"])
    if not runs:
        raise SystemExit(f"no runs recorded for {task} on board {board!r}")
    session = (runs[-1].get("metadata") or {}).get("worker_session_id")
    if not session:
        raise SystemExit(f"run for {task} has no worker_session_id in its metadata")
    return session


def collect(db: Path, session: str) -> list[sqlite3.Row]:
    if not db.exists():
        raise SystemExit(f"state database not found: {db}")
    conn = sqlite3.connect(f"file:{db}?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    try:
        tables = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if "session_model_usage" not in tables:
            raise SystemExit(f"no session_model_usage table in {db}")
        have = {r[1] for r in conn.execute("PRAGMA table_info(session_model_usage)")}
        cols = [c for c in COLUMNS if c in have]
        rows = conn.execute(
            f"SELECT {', '.join(cols)} FROM session_model_usage WHERE session_id = ?", (session,)
        ).fetchall()
    finally:
        conn.close()
    if not rows:
        raise SystemExit(f"no usage rows for session {session}")
    return rows


def summarize(rows: list[sqlite3.Row]) -> dict:
    def n(row, key):
        return int(row[key] or 0) if key in row.keys() else 0

    by_task: dict[str, dict] = {}
    for row in rows:
        label = (row["task"] if "task" in row.keys() else "") or "main"
        bucket = by_task.setdefault(label, {
            "api_calls": 0, "input_tokens": 0, "output_tokens": 0,
            "cache_read_tokens": 0, "cache_write_tokens": 0,
            "reasoning_tokens": 0, "estimated_cost_usd": 0.0,
        })
        bucket["api_calls"] += n(row, "api_call_count")
        bucket["input_tokens"] += n(row, "input_tokens")
        bucket["output_tokens"] += n(row, "output_tokens")
        bucket["cache_read_tokens"] += n(row, "cache_read_tokens")
        bucket["cache_write_tokens"] += n(row, "cache_write_tokens")
        bucket["reasoning_tokens"] += n(row, "reasoning_tokens")
        bucket["estimated_cost_usd"] += float(row["estimated_cost_usd"] or 0.0)

    totals = {k: sum(v[k] for v in by_task.values()) for k in next(iter(by_task.values()))}
    cost_statuses = {row["cost_status"] for row in rows if "cost_status" in row.keys()}
    sources = {row["cost_source"] for row in rows if "cost_source" in row.keys()} - {None}
    models = {row["model"] for row in rows if "model" in row.keys() and row["model"]}
    return {
        "by_task": by_task,
        "totals": totals,
        "models": sorted(models),
        "cost_status": sorted(s for s in cost_statuses if s),
        "cost_source": sorted(sources),
        "counts": len(rows),
    }


def fmt_int(value: int) -> str:
    return f"{value:,}"


def markdown(task: str, summary: dict) -> str:
    totals = summary["totals"]
    lines = [
        f"### Agent usage — `{task}`",
        "",
        "| Phase | Calls | Input | Output | Cache read | Est. cost |",
        "| --- | ---: | ---: | ---: | ---: | ---: |",
    ]
    for label, bucket in sorted(summary["by_task"].items(), key=lambda kv: -kv[1]["api_calls"]):
        lines.append(
            f"| {label} | {bucket['api_calls']} | {fmt_int(bucket['input_tokens'])} | "
            f"{fmt_int(bucket['output_tokens'])} | {fmt_int(bucket['cache_read_tokens'])} | "
            f"${bucket['estimated_cost_usd']:.4f} |"
        )
    lines.append(
        f"| **Total** | **{totals['api_calls']}** | **{fmt_int(totals['input_tokens'])}** | "
        f"**{fmt_int(totals['output_tokens'])}** | **{fmt_int(totals['cache_read_tokens'])}** | "
        f"**${totals['estimated_cost_usd']:.4f}** |"
    )
    lines.append("")
    model = ", ".join(summary["models"]) or "unknown"
    lines.append(f"Model `{model}` · pricing `{', '.join(summary['cost_source']) or 'none'}`")
    missing = [s for s in summary["cost_status"] if s != "estimated"]
    if missing or not summary["cost_source"]:
        lines.append(
            f"> Cost is unavailable for part of this run (`{', '.join(missing) or 'no pricing entry'}`); "
            "token counts are still exact."
        )
    return "\n".join(lines) + "\n"


def append_ledger(path: Path, summary: dict) -> bool:
    """Append one JSON record per (task, session); returns False when it was already recorded."""
    from datetime import datetime, timezone

    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        for line in path.read_text(encoding="utf-8").splitlines():
            try:
                seen = json.loads(line)
            except json.JSONDecodeError:
                continue
            if seen.get("task") == summary["task"] and seen.get("session_id") == summary["session_id"]:
                return False
    record = dict(summary)
    record["recorded_at"] = datetime.now(timezone.utc).isoformat(timespec="seconds")
    with path.open("a", encoding="utf-8") as handle:
        handle.write(json.dumps(record, sort_keys=True) + "\n")
    return True


USAGE_COMMENT_MARKER = "### Agent usage"


def has_usage_comment(board: str, task: str) -> bool:
    """True when the card already carries a usage table, so re-runs never duplicate it."""
    proc = subprocess.run([hermes(), "kanban", "--board", board, "show", task],
                          capture_output=True, text=True, encoding="utf-8")
    return USAGE_COMMENT_MARKER in (proc.stdout or "")


def comment_on_card(board: str, task: str, body: str) -> int:
    """Store the table as a local kanban comment (SQLite only — never leaves the machine)."""
    proc = subprocess.run([hermes(), "kanban", "--board", board, "comment", task, body], text=True)
    if proc.returncode != 0:
        print(f"could not comment on {task}", file=sys.stderr)
    return proc.returncode


def record(task: str, board: str, profile: str, session: str, db: Path | None,
           ledger: Path | None, kanban_comment: bool) -> dict:
    """Collect, report, and persist one task's usage. Raises SystemExit on unusable data."""
    summary = summarize(collect(db or profile_db(profile), session))
    summary.update({"task": task, "board": board, "profile": profile, "session_id": session})
    text = markdown(task, summary)
    print(text)

    if ledger:
        if append_ledger(ledger, summary):
            print(f"appended usage record to {ledger}")
        else:
            print(f"already in ledger: {task}")
    if kanban_comment:
        if has_usage_comment(board, task):
            print(f"usage comment already present on {task}")
        else:
            rc = comment_on_card(board, task, text)
            if rc != 0:
                raise SystemExit(rc)
            print(f"commented usage on kanban task {task}")
    return summary


def sweep(board: str, profile: str, db: Path | None, ledger: Path | None, kanban_comment: bool) -> int:
    """Record every finished card on the board that is not yet recorded.

    Local only: writes to the ledger and the board's own SQLite, never to GitHub.
    """
    tasks = run_json([hermes(), "kanban", "--board", board, "list", "--status", "done", "--json"])
    recorded = skipped = 0
    for task in tasks:
        task_id = task.get("id")
        if not task_id:
            continue
        try:
            session = worker_session_id(board, task_id)
        except SystemExit as exc:
            print(f"skip {task_id}: {exc}", file=sys.stderr)
            skipped += 1
            continue
        try:
            record(task_id, board, profile, session, db, ledger, kanban_comment)
            recorded += 1
        except SystemExit as exc:
            print(f"skip {task_id}: {exc}", file=sys.stderr)
            skipped += 1
    print(f"sweep: {recorded} task(s) processed, {skipped} skipped")
    return 0


def utf8_stdout() -> None:
    """Write UTF-8 whatever the console codepage is.

    Windows runners default to cp1252, which turns the report's em dash into 0x97 and
    breaks any reader that decodes the stream as UTF-8. Streams that are already UTF-8,
    and streams that cannot be reconfigured (a StringIO or other replacement), are left
    alone so the report still prints.
    """
    stream = sys.stdout
    reconfigure = getattr(stream, "reconfigure", None)
    if not callable(reconfigure):
        return
    encoding = (getattr(stream, "encoding", None) or "").lower().replace("_", "").replace("-", "")
    if encoding == "utf8":
        return
    try:
        reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, OSError, ValueError):
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("task", nargs="?", help="kanban task id, e.g. t_69f3c047 (omit with --sweep)")
    parser.add_argument("--board", default="newsagg")
    parser.add_argument("--profile", default="newsagg")
    parser.add_argument("--session-id", help="skip the kanban lookup and read this session id directly")
    parser.add_argument("--db", type=Path, help="state.db path (default: resolved from the profile)")
    parser.add_argument("--markdown", type=Path, help="write the markdown table here")
    parser.add_argument("--json", dest="json_out", type=Path, help="write the summary as JSON here")
    parser.add_argument("--comment-pr", type=int, metavar="N", help="post the table to pull request N via gh")
    parser.add_argument("--ledger", type=Path, help="append a JSON record to this local ledger file")
    parser.add_argument("--kanban-comment", action="store_true",
                        help="store the table as a local kanban comment on the task")
    parser.add_argument("--sweep", action="store_true",
                        help="record every finished card on the board (local only, skips ones already recorded)")
    parser.add_argument("--gh", default="gh", help="gh executable (default: gh on PATH)")
    args = parser.parse_args()

    if args.sweep:
        if not (args.ledger or args.kanban_comment):
            print("--sweep needs --ledger and/or --kanban-comment", file=sys.stderr)
            return 2
        return sweep(args.board, args.profile, args.db, args.ledger, args.kanban_comment)

    if not args.task:
        print("a task id is required unless --sweep is used", file=sys.stderr)
        return 2

    session = args.session_id or worker_session_id(args.board, args.task)
    db = args.db or profile_db(args.profile)
    summary = summarize(collect(db, session))
    summary.update({"task": args.task, "board": args.board, "profile": args.profile, "session_id": session})

    text = markdown(args.task, summary)
    print(text)

    if args.markdown:
        args.markdown.write_text(text, encoding="utf-8")
    if args.json_out:
        args.json_out.write_text(json.dumps(summary, indent=2), encoding="utf-8")
    if args.ledger:
        if append_ledger(args.ledger, summary):
            print(f"appended usage record to {args.ledger}")
        else:
            print(f"already in ledger: {args.task}")
    if args.kanban_comment:
        if has_usage_comment(args.board, args.task):
            print(f"usage comment already present on {args.task}")
        else:
            rc = comment_on_card(args.board, args.task, text)
            if rc != 0:
                return rc
            print(f"commented usage on kanban task {args.task}")

    if args.comment_pr is not None:
        gh = resolve_gh(args.gh)
        if not gh:
            print("gh executable not found; install GitHub CLI or pass --gh <path>", file=sys.stderr)
            return 1
        with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False, encoding="utf-8") as handle:
            handle.write(text)
            body = handle.name
        try:
            proc = subprocess.run([gh, "pr", "comment", str(args.comment_pr), "--body-file", body])
        finally:
            os.unlink(body)
        if proc.returncode != 0:
            return proc.returncode
        print(f"posted usage comment to PR #{args.comment_pr}")
    return 0


if __name__ == "__main__":
    utf8_stdout()
    sys.exit(main())
