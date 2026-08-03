---
name: git-commit
description: Inspect, stage, and commit repository changes safely. Use when the user asks to commit, stage files, run git commit, or says "提交一下", "git 提交", or "git提交一下"; create a scoped message and verify the resulting repository state.
---

> 最新更新时间：2026-07-29

# Git Commit

## Workflow

1. Inspect `git status --short`, the relevant working-tree diff, and the staged
   diff. Confirm which files belong to the requested logical change.
2. Preserve unrelated user work. Stage explicit paths only; do not use
   `git add .` or `git add -A` in a dirty tree. If unrelated changes are already
   staged, do not unstage or commit them without explicit direction.
3. Run `git diff --check` before staging and `git diff --cached --check`
   afterward. Do not rerun Flutter analysis or tests solely for the commit;
   rely on validation completed during implementation and report any gap.
4. Create a short, direct, imperative subject in Chinese or English, then commit
   only the intended staged change.
5. Verify success with `git status --short` and `git log -1 --oneline`.

- Do not amend, reset, force, or push unless the user explicitly requests that
  additional action.
