"""Read-only scanner for Conductor's session database.

A session is "stalled" when its most recent *result-type* message is a 429
usage-limit error. (After a 429, Conductor appends synthetic assistant and
system messages, so the error is rarely the literal last row.) The database
is opened with mode=ro; this module never writes.
"""

from __future__ import annotations

import json
import sqlite3
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

DB_PATH = (
    Path.home()
    / "Library"
    / "Application Support"
    / "com.conductor.app"
    / "conductor.db"
)

# Don't resurrect sessions abandoned at a limit ages ago — they're stale by
# now, and the user has likely moved on.
MAX_STALL_AGE_HOURS = 48

_LAST_RESULT_QUERY = """
WITH results AS (
    SELECT session_id, content, created_at,
           ROW_NUMBER() OVER (
               PARTITION BY session_id ORDER BY created_at DESC, id DESC
           ) AS rn
    FROM session_messages
    WHERE json_valid(content)
      AND json_extract(content, '$.type') = 'result'
)
SELECT s.id, s.claude_session_id, s.title, w.workspace_path,
       r.content, r.created_at
FROM results r
JOIN sessions s ON s.id = r.session_id
JOIN workspaces w ON w.id = s.workspace_id
WHERE r.rn = 1
  AND w.state != 'archived'
  AND s.status != 'working'
  AND json_extract(r.content, '$.is_error') = 1
  AND json_extract(r.content, '$.api_error_status') = 429
"""


@dataclass(frozen=True)
class StalledSession:
    session_id: str
    claude_session_id: str
    title: str
    workspace_path: str
    error_text: str  # e.g. "You've hit your session limit · resets 7:50pm"
    stalled_at: datetime


def _parse_row(row: tuple, now: datetime) -> StalledSession | None:
    session_id, claude_session_id, title, workspace_path, content, created = row
    if not claude_session_id or not workspace_path:
        return None
    if not Path(workspace_path).is_dir():
        return None  # workspace was removed; nothing to resume into

    try:
        payload = json.loads(content)
    except json.JSONDecodeError:
        return None

    stalled_at = datetime.fromisoformat(created.replace("Z", "+00:00"))
    if stalled_at.tzinfo is None:
        stalled_at = stalled_at.replace(tzinfo=timezone.utc)
    if now - stalled_at > timedelta(hours=MAX_STALL_AGE_HOURS):
        return None  # too old; the user has moved on

    return StalledSession(
        session_id=session_id,
        claude_session_id=claude_session_id,
        title=title or "Untitled",
        workspace_path=workspace_path,
        error_text=str(payload.get("result", "")),
        stalled_at=stalled_at,
    )


def find_stalled_sessions(
    db_path: Path = DB_PATH, now: datetime | None = None
) -> tuple[StalledSession, ...]:
    """Return all sessions currently stalled on a usage-limit error."""
    if not db_path.exists():
        raise FileNotFoundError(f"Conductor DB not found at {db_path}")
    reference_time = now or datetime.now(timezone.utc)
    uri = f"file:{db_path}?mode=ro"
    with sqlite3.connect(uri, uri=True, timeout=10) as conn:
        rows = conn.execute(_LAST_RESULT_QUERY).fetchall()
    parsed = (_parse_row(row, reference_time) for row in rows)
    return tuple(s for s in parsed if s is not None)
