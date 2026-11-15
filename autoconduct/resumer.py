"""Resume a stalled session headlessly via the claude CLI."""

from __future__ import annotations

import os
import re
import subprocess
from dataclasses import dataclass
from pathlib import Path

from .conductor_db import StalledSession
from .config import Config

RESUME_TIMEOUT_SECONDS = 60 * 60  # one long agentic run, but never forever

_UUID = re.compile(r"^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$")


def is_safe_resume(session_id: str, workspace: str, home: str | None = None) -> bool:
    """Mirror of the app's ResumeSafety (security audit H1/H2).

    Both values come from another app's database. The id must be a UUID (so
    `claude` can never parse it as a flag) and the workspace must be a project
    folder strictly under $HOME: not $HOME itself, not ~/Library, and with no
    hidden component, so a crafted row can't aim an acceptEdits agent at
    your dotfiles.
    """
    if not _UUID.match(session_id or ""):
        return False
    if not workspace or not workspace.startswith("/"):
        return False
    base = Path(os.path.realpath(home or os.path.expanduser("~")))
    target = Path(os.path.realpath(workspace))
    try:
        parts = target.relative_to(base).parts
    except ValueError:
        return False
    return bool(parts) and parts[0] != "Library" and not any(p.startswith(".") for p in parts)


@dataclass(frozen=True)
class ResumeResult:
    session_id: str
    ok: bool
    detail: str


def resume_session(
    session: StalledSession, config: Config, dry_run: bool = False
) -> ResumeResult:
    """Run `claude --resume` in the session's workspace directory.

    Headless print mode (-p) so the run terminates on its own. Work lands
    in the workspace files/git; Conductor's chat UI won't show the turns.
    """
    if not is_safe_resume(session.claude_session_id, session.workspace_path):
        return ResumeResult(session.session_id, False, "refused: session id or workspace failed safety checks")
    cmd = [
        "claude",
        "--resume",
        session.claude_session_id,
        "-p",
        config.resume_prompt,
        "--permission-mode",
        config.permission_mode,
    ]
    if dry_run:
        return ResumeResult(session.session_id, True, f"DRY RUN: {' '.join(cmd)}")
    try:
        proc = subprocess.run(
            cmd,
            cwd=session.workspace_path,
            capture_output=True,
            text=True,
            timeout=RESUME_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired:
        return ResumeResult(session.session_id, False, "timed out after 1h")
    except FileNotFoundError:
        return ResumeResult(session.session_id, False, "claude CLI not found on PATH")
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-300:]
        return ResumeResult(session.session_id, False, f"exit {proc.returncode}: {tail}")
    return ResumeResult(session.session_id, True, (proc.stdout or "").strip()[-300:])
