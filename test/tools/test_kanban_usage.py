"""Integration tests for bin/kanban-usage.py against a disposable state database."""

from __future__ import annotations

import json
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPT = REPO / "bin" / "kanban-usage.py"

SCHEMA = """
CREATE TABLE session_model_usage (
  session_id TEXT, model TEXT, billing_provider TEXT, billing_base_url TEXT,
  billing_mode TEXT, task TEXT, api_call_count INTEGER, input_tokens INTEGER,
  output_tokens INTEGER, cache_read_tokens INTEGER, cache_write_tokens INTEGER,
  reasoning_tokens INTEGER, estimated_cost_usd REAL, actual_cost_usd REAL,
  cost_status TEXT, cost_source TEXT, first_seen REAL, last_seen REAL
);
"""


def make_db(path: Path, rows: list[tuple]) -> None:
    conn = sqlite3.connect(path)
    conn.executescript(SCHEMA)
    conn.executemany(
        "INSERT INTO session_model_usage (session_id, model, task, api_call_count, "
        "input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, "
        "reasoning_tokens, estimated_cost_usd, cost_status, cost_source) "
        "VALUES (?, ?, ?, ?, ?, ?, ?, 0, 0, ?, ?, ?)",
        rows,
    )
    conn.commit()
    conn.close()


def run_script(*args: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *args],
        capture_output=True, text=True, encoding="utf-8",
    )


class KanbanUsageTest(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.db = Path(self.tmp.name) / "state.db"

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def test_reports_totals_and_cost_for_a_session(self) -> None:
        make_db(self.db, [
            ("s1", "deepseek-flash", "", 100, 80000, 40000, 8000000, 0.0600, "estimated", "official_docs_snapshot"),
            ("s1", "deepseek-flash", "vision", 5, 1000, 2000, 0, 0.0005, "estimated", "official_docs_snapshot"),
        ])

        result = run_script("t_test", "--session-id", "s1", "--db", str(self.db))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| **Total** | **105** | **81,000** | **42,000** | **8,000,000** | **$0.0605** |", result.stdout)
        self.assertIn("| main | 100 |", result.stdout)
        self.assertIn("| vision | 5 |", result.stdout)
        self.assertNotIn("Cost is unavailable", result.stdout)

    def test_flags_runs_without_resolved_pricing(self) -> None:
        make_db(self.db, [
            ("s2", "deepseek-flash", "", 10, 500, 500, 0, 0.0, "unknown", "none"),
        ])

        result = run_script("t_test", "--session-id", "s2", "--db", str(self.db))

        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Cost is unavailable", result.stdout)
        self.assertIn("unknown", result.stdout)

    def test_writes_json_summary(self) -> None:
        make_db(self.db, [
            ("s3", "deepseek-flash", "", 3, 300, 150, 0, 0.001, "estimated", "official_docs_snapshot"),
        ])
        out = Path(self.tmp.name) / "usage.json"

        result = run_script("t_test", "--session-id", "s3", "--db", str(self.db), "--json", str(out))

        self.assertEqual(result.returncode, 0, result.stderr)
        payload = json.loads(out.read_text(encoding="utf-8"))
        self.assertEqual(payload["totals"]["api_calls"], 3)
        self.assertEqual(payload["totals"]["input_tokens"], 300)
        self.assertAlmostEqual(payload["totals"]["estimated_cost_usd"], 0.001)
        self.assertEqual(payload["session_id"], "s3")

    def test_missing_session_is_an_error(self) -> None:
        make_db(self.db, [
            ("other", "deepseek-flash", "", 1, 1, 1, 0, 0.0, "estimated", "official_docs_snapshot"),
        ])

        result = run_script("t_test", "--session-id", "s3", "--db", str(self.db))

        self.assertEqual(result.returncode, 1)
        self.assertIn("no usage rows for session s3", result.stderr)

    def test_missing_database_is_an_error(self) -> None:
        missing = Path(self.tmp.name) / "absent.db"

        result = run_script("t_test", "--session-id", "s1", "--db", str(missing))

        self.assertEqual(result.returncode, 1)
        self.assertIn("state database not found", result.stderr)

    def test_ledger_records_each_session_once(self) -> None:
        make_db(self.db, [
            ("s4", "deepseek-flash", "", 7, 700, 70, 0, 0.002, "estimated", "official_docs_snapshot"),
        ])
        ledger = Path(self.tmp.name) / "nested" / "usage.jsonl"

        first = run_script("t_test", "--session-id", "s4", "--db", str(self.db), "--ledger", str(ledger))
        second = run_script("t_test", "--session-id", "s4", "--db", str(self.db), "--ledger", str(ledger))

        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual(second.returncode, 0, second.stderr)
        self.assertIn("already in ledger", second.stdout)

        records = [json.loads(line) for line in ledger.read_text(encoding="utf-8").splitlines()]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0]["totals"]["api_calls"], 7)
        self.assertEqual(records[0]["task"], "t_test")
        self.assertEqual(records[0]["session_id"], "s4")
        self.assertIn("recorded_at", records[0])

    def test_ledger_appends_a_second_session(self) -> None:
        make_db(self.db, [
            ("s5", "deepseek-flash", "", 2, 200, 20, 0, 0.001, "estimated", "official_docs_snapshot"),
            ("s6", "deepseek-flash", "", 4, 400, 40, 0, 0.002, "estimated", "official_docs_snapshot"),
        ])
        ledger = Path(self.tmp.name) / "usage.jsonl"

        for session in ("s5", "s6"):
            run_script("t_test", "--session-id", session, "--db", str(self.db), "--ledger", str(ledger))

        records = [json.loads(line) for line in ledger.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([r["session_id"] for r in records], ["s5", "s6"])


if __name__ == "__main__":
    unittest.main()
