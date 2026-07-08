"""Multi-model branch orchestrator.

Decompose a goal into a dependency graph of subtasks, open a git worktree +
branch per subtask, route each to the right Claude model (budget-aware), run
independent subtasks in parallel and dependent ones in sequence, and hand off
finished work by merging into an integration branch.
"""
