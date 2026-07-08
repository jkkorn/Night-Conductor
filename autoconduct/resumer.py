"""Run the `claude` CLI headlessly.

Two entry points share one subprocess core (`run_claude`):
  • `resume_session` — `claude --resume <id> -p <prompt>` to continue a
    stalled session in place (the night watch's job), and
  • the orchestrator's node runner, which calls `run_claude` directly with
    `-p <prompt> --model <m>` to run a fresh subtask in a worktree.
"""

from __future__ import annotations

import subprocess
from dataclasses import dataclass

from .conductor_db import StalledSession
from .config import Config

RESUME_TIMEOUT_SECONDS = 60 * 60  # one long agentic run, but never forever


@dataclass(frozen=True)
class ResumeResult:
    session_id: str
    ok: bool
    detail: str


@dataclass(frozen=True)
class ClaudeRun:
    ok: bool
    detail: str  # tail of stdout on success, or the error/exit info on failure


def run_claude(
    args: list[str],
    cwd: str,
    timeout: int = RESUME_TIMEOUT_SECONDS,
    dry_run: bool = False,
) -> ClaudeRun:
    """Invoke `claude` with `args` in `cwd`, headless. Fails closed.

    `args` are everything after the `claude` binary (e.g. ["-p", prompt,
    "--model", "claude-sonnet-5", "--permission-mode", "acceptEdits"]).
    """
    cmd = ["claude", *args]
    if dry_run:
        return ClaudeRun(True, f"DRY RUN [{cwd}]: {' '.join(cmd)}")
    try:
        proc = subprocess.run(
            cmd,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired:
        return ClaudeRun(False, f"timed out after {timeout // 60}m")
    except FileNotFoundError:
        return ClaudeRun(False, "claude CLI not found on PATH")
    if proc.returncode != 0:
        tail = (proc.stderr or proc.stdout or "").strip()[-300:]
        return ClaudeRun(False, f"exit {proc.returncode}: {tail}")
    return ClaudeRun(True, (proc.stdout or "").strip()[-300:])


def resume_session(
    session: StalledSession, config: Config, dry_run: bool = False
) -> ResumeResult:
    """Run `claude --resume` in the session's workspace directory.

    Headless print mode (-p) so the run terminates on its own. Work lands
    in the workspace files/git; Conductor's chat UI won't show the turns.
    """
    args = [
        "--resume",
        session.claude_session_id,
        "-p",
        config.resume_prompt,
        "--permission-mode",
        config.permission_mode,
    ]
    run = run_claude(args, cwd=session.workspace_path, dry_run=dry_run)
    return ResumeResult(session.session_id, run.ok, run.detail)
