"""Tests for the derived project usage ledger and Kanban usage CLI."""

from __future__ import annotations

import json
from pathlib import Path

import pytest

from hermes_state import SessionDB
from hermes_cli import kanban as kc
from hermes_cli import kanban_db as kb
from hermes_cli import project_usage_ledger as usage


@pytest.fixture
def usage_home(tmp_path, monkeypatch):
    home = tmp_path / ".hermes"
    home.mkdir()
    monkeypatch.setenv("HERMES_HOME", str(home))
    monkeypatch.setattr(Path, "home", lambda: tmp_path)
    kb._INITIALIZED_PATHS.clear()
    kb.init_db(board="default")
    return home


def _seed_session(home: Path, session_id: str, *, in_tok: int, out_tok: int, cost: float) -> None:
    db = SessionDB(home / "state.db")
    try:
        db.create_session(session_id, "kanban", model="gpt-test", user_id="u-test")
        db.update_token_counts(
            session_id,
            input_tokens=in_tok,
            output_tokens=out_tok,
            reasoning_tokens=7,
            estimated_cost_usd=cost,
            billing_provider="test-provider",
            billing_mode="api",
            api_call_count=2,
            absolute=True,
        )
        db.end_session(session_id, "done")
    finally:
        db.close()


def _seed_completed_run(session_id: str, *, title: str = "usage task") -> str:
    with kb.connect(board="default") as conn:
        tid = kb.create_task(conn, title=title, assignee="worker")
        assert kb.claim_task(conn, tid)
        assert kb.complete_task(
            conn,
            tid,
            summary="finished",
            metadata={"worker_session_id": session_id},
        )
        return tid


def test_project_usage_backfill_correlates_kanban_run_to_session(usage_home):
    _seed_session(usage_home, "sess-usage-1", in_tok=100, out_tok=50, cost=0.0123)
    tid = _seed_completed_run("sess-usage-1")

    data = usage.get_summary(board="default", task_id=tid, refresh=True)

    assert data["ledger_path"].endswith("usage/project_usage.db")
    assert data["totals"]["input_tokens"] == 100
    assert data["totals"]["output_tokens"] == 50
    assert data["totals"]["reasoning_tokens"] == 7
    assert data["totals"]["estimated_cost_usd"] == pytest.approx(0.0123)
    assert [b["board_slug"] for b in data["boards"]] == ["default"]
    assert data["tasks"][0]["task_id"] == tid
    assert data["tasks"][0]["sessions"] == 1
    assert data["runs"][0]["session_id"] == "sess-usage-1"


def test_project_usage_backfill_counts_session_usage_once_across_runs(usage_home):
    _seed_session(usage_home, "sess-retry", in_tok=100, out_tok=50, cost=0.0123)
    tid = _seed_completed_run("sess-retry")
    with kb.connect(board="default") as conn:
        conn.execute(
            """
            INSERT INTO task_runs(
                task_id, profile, status, started_at, ended_at, outcome,
                summary, metadata
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                tid,
                "worker",
                "completed",
                10,
                20,
                "done",
                "retry terminal row",
                json.dumps({"worker_session_id": "sess-retry"}),
            ),
        )

    data = usage.get_summary(board="default", task_id=tid, refresh=True)

    assert data["totals"]["entries"] == 2
    assert data["totals"]["sessions"] == 1
    assert data["totals"]["input_tokens"] == 100
    assert data["totals"]["output_tokens"] == 50
    assert data["totals"]["estimated_cost_usd"] == pytest.approx(0.0123)
    assert data["tasks"][0]["runs"] == 2
    assert data["tasks"][0]["sessions"] == 1
    assert data["tasks"][0]["input_tokens"] == 100


def test_project_usage_summary_keeps_unassigned_sessions_visible(usage_home):
    _seed_session(usage_home, "sess-unassigned", in_tok=11, out_tok=22, cost=0.003)

    data = usage.get_summary(refresh=True)

    unassigned = next(b for b in data["boards"] if b["board_slug"] == "__unassigned__")
    assert unassigned["board_name"] == "Unassigned sessions"
    assert unassigned["sessions"] == 1
    assert data["totals"]["input_tokens"] == 11
    assert data["totals"]["output_tokens"] == 22


def test_stamp_usage_metadata_embeds_worker_session_snapshot(usage_home):
    _seed_session(usage_home, "sess-snapshot", in_tok=5, out_tok=6, cost=0.0009)

    stamped = usage.stamp_usage_metadata({"keep": True}, "sess-snapshot")

    assert stamped["keep"] is True
    assert stamped["worker_session_id"] == "sess-snapshot"
    assert stamped["usage_snapshot"]["input_tokens"] == 5
    assert stamped["usage_snapshot"]["output_tokens"] == 6
    assert stamped["usage_snapshot"]["estimated_cost_usd"] == pytest.approx(0.0009)


def test_kanban_usage_cli_outputs_json_summary(usage_home):
    _seed_session(usage_home, "sess-cli", in_tok=13, out_tok=17, cost=0.0042)
    tid = _seed_completed_run("sess-cli", title="cli usage task")

    out = kc.run_slash("usage --json")
    data = json.loads(out)

    assert data["totals"]["input_tokens"] == 13
    assert data["totals"]["output_tokens"] == 17
    row = next(t for t in data["tasks"] if t["task_id"] == tid)
    assert row["task_title"] == "cli usage task"
    assert row["estimated_cost_usd"] == pytest.approx(0.0042)
