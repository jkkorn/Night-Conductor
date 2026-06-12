import json
import sqlite3
from datetime import datetime, timezone

import pytest

from autoconduct.conductor_db import find_stalled_sessions

# Frozen "now" matching the fixture timestamps below.
NOW = datetime(2026, 6, 10, 6, 0, tzinfo=timezone.utc)

LIMIT_ERROR = {
    "type": "result",
    "subtype": "success",
    "is_error": True,
    "api_error_status": 429,
    "result": "You've hit your session limit · resets 1:30pm (America/Sao_Paulo)",
}

OK_RESULT = {"type": "result", "subtype": "success", "is_error": False}

# Conductor appends synthetic messages after a 429 — these must not mask it.
SYNTHETIC_ASSISTANT = {"type": "assistant", "message": {"model": "<synthetic>"}}
SYSTEM_NOTIFICATION = {"type": "system", "subtype": "task_notification"}


@pytest.fixture
def db(tmp_path):
    path = tmp_path / "conductor.db"
    conn = sqlite3.connect(path)
    conn.executescript(
        """
        CREATE TABLE sessions (
            id TEXT PRIMARY KEY, claude_session_id TEXT,
            workspace_id TEXT, title TEXT, status TEXT
        );
        CREATE TABLE workspaces (
            id TEXT PRIMARY KEY, workspace_path TEXT, state TEXT
        );
        CREATE TABLE session_messages (
            id TEXT PRIMARY KEY, session_id TEXT,
            content TEXT, created_at TEXT
        );
        """
    )
    conn.commit()
    yield conn, path
    conn.close()


def _seed(
    conn,
    tmp_path,
    session_id,
    messages,
    ws_state="ready",
    ws_exists=True,
    base_day="2026-06-10",
    status="error",
):
    ws_path = tmp_path / f"ws-{session_id}"
    if ws_exists:
        ws_path.mkdir(exist_ok=True)
    conn.execute(
        "INSERT INTO workspaces VALUES (?, ?, ?)",
        (f"ws-{session_id}", str(ws_path), ws_state),
    )
    conn.execute(
        "INSERT INTO sessions VALUES (?, ?, ?, ?, ?)",
        (
            session_id,
            f"claude-{session_id}",
            f"ws-{session_id}",
            f"Task {session_id}",
            status,
        ),
    )
    for i, payload in enumerate(messages):
        conn.execute(
            "INSERT INTO session_messages VALUES (?, ?, ?, ?)",
            (
                f"{session_id}-m{i}",
                session_id,
                json.dumps(payload),
                f"{base_day}T0{i}:00:00.000Z",
            ),
        )
    conn.commit()


class TestFindStalledSessions:
    def test_finds_session_whose_last_result_is_429(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s1", [OK_RESULT, LIMIT_ERROR])
        stalled = find_stalled_sessions(path, now=NOW)
        assert len(stalled) == 1
        assert stalled[0].session_id == "s1"
        assert "resets 1:30pm" in stalled[0].error_text

    def test_synthetic_messages_after_429_do_not_mask_it(self, db, tmp_path):
        # Regression: Conductor writes synthetic assistant + system messages
        # after the 429, so the error is rarely the literal last row.
        conn, path = db
        _seed(
            conn, tmp_path, "s2",
            [LIMIT_ERROR, SYNTHETIC_ASSISTANT, SYSTEM_NOTIFICATION],
        )
        stalled = find_stalled_sessions(path, now=NOW)
        assert [s.session_id for s in stalled] == ["s2"]

    def test_ignores_session_that_recovered(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s3", [LIMIT_ERROR, OK_RESULT])
        assert find_stalled_sessions(path, now=NOW) == ()

    def test_ignores_archived_workspace_but_keeps_ready(self, db, tmp_path):
        # Regression: real Conductor states are 'ready'/'archived', not
        # 'active' — filtering for 'active' matched nothing.
        conn, path = db
        _seed(conn, tmp_path, "s4", [LIMIT_ERROR], ws_state="archived")
        _seed(conn, tmp_path, "s5", [LIMIT_ERROR], ws_state="ready")
        stalled = find_stalled_sessions(path, now=NOW)
        assert [s.session_id for s in stalled] == ["s5"]

    def test_ignores_session_conductor_is_already_running(self, db, tmp_path):
        # Regression: if the user (or Conductor) already retried a stalled
        # session, its status is 'working' — resuming it again would
        # double-run the task and burn budget for nothing.
        conn, path = db
        _seed(conn, tmp_path, "s9", [LIMIT_ERROR], status="working")
        assert find_stalled_sessions(path, now=NOW) == ()

    def test_ignores_stalls_older_than_48h(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s6", [LIMIT_ERROR], base_day="2026-05-20")
        assert find_stalled_sessions(path, now=NOW) == ()

    def test_ignores_deleted_workspace_dir(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s7", [LIMIT_ERROR], ws_exists=False)
        assert find_stalled_sessions(path, now=NOW) == ()

    def test_ignores_malformed_json_rows(self, db, tmp_path):
        conn, path = db
        _seed(conn, tmp_path, "s8", [LIMIT_ERROR])
        conn.execute(
            "INSERT INTO session_messages VALUES (?, ?, ?, ?)",
            ("s8-bad", "s8", "{not valid json", "2026-06-10T05:00:00.000Z"),
        )
        conn.commit()
        stalled = find_stalled_sessions(path, now=NOW)
        assert [s.session_id for s in stalled] == ["s8"]

    def test_missing_db_raises(self, tmp_path):
        with pytest.raises(FileNotFoundError):
            find_stalled_sessions(tmp_path / "missing.db", now=NOW)
