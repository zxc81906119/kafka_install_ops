---
name: handoff
description: Keep the cross-session hand-off state in .claude/state/ (status-<branch>.md and dated log entries). Use at session start, after every milestone, before compaction or ending, when switching branch/worktree, and whenever the lab's in-use state changes.
---

# Hand-off state

Why: conversation context is lost on new sessions and thinned by compaction; auto-memory is keyed by directory
(each git worktree has its own) and does not follow branches. Anything needed to continue work lives in the repo.

## Files
- `.claude/state/status-<branch>.md` — one per branch, **overwritten** at each milestone. Sections:
  現在在做什麼 / 做到哪 / 下一步（候選）/ 環境狀態（which lab is in use, by which session, since when; background
  jobs; disposable files; unmerged stashes).
- `.claude/state/log/YYYY-MM-DD-<topic>.md` — **append-only**, one topic per file, decisions and lessons in a
  few bullets; questions for customer/vendors verbatim. New files rarely conflict on merge.
- `CLAUDE.md` — only stable facts; update when a decision in a log becomes permanent.
- `redesign/README.md` — the consolidated design; sync from logs after a decision is confirmed.

## Session start (do this before anything else)
1. `git branch --show-current`, `git worktree list`, `git status --short | head`.
2. Read `.claude/state/status-<branch>.md` (if missing, read the newest status file and say so).
3. Read the newest 2–3 files in `.claude/state/log/`.
4. If status says the lab is in use by another session, do not touch Docker until the user decides.
5. Tell the user in 3–5 lines where things stand and ask which next step.

## Milestones (write immediately, don't batch)
- A step verified, a decision confirmed, a document produced, an environment state change (lab up/down, long
  background job started/finished), a branch/worktree created or merged.
- Keep status ≤ 40 lines; move detail to a log entry.

## Branches and worktrees
- One session = one worktree = one branch; name the worktree after the branch.
- Status file name follows the branch; delete it when the branch is merged and removed.
- Merging: logs merge by adding files; status files never collide; `CLAUDE.md`/`redesign/README.md` conflicts are
  resolved by hand (keep both decisions, dated).
- The lab (Docker) is shared by all worktrees: record "lab: <project> 使用中（<session/branch>, since <time>)" in
  the status file before using it and clear it after.

## Secrets never go into state files
Paths of secret files are fine; values never.
