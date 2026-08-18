---
name: git-commit
description: Inspect, stage, and commit repository changes safely. Use when the user asks to commit, stage files, run git commit, or says "提交一下", "git 提交", or "git提交一下"; create a scoped message and verify the resulting repository state.
---

> 最新更新时间：2026-08-15

# Git Commit

## Workflow

1. Inspect `git status --short`, the relevant working-tree diff, and the staged
   diff. Confirm which files belong to the requested logical change.
2. Preserve unrelated user work. Stage explicit paths only; do not use
   `git add .` or `git add -A` in a dirty tree. If unrelated changes are already
   staged, do not unstage or commit them without explicit direction.
3. Run the owning format gate on the changed files before staging. The exact
   per-language command lives in the maintenance Skill's validation reference
   (`.agents/skills/ssh-mobile-maintenance/references/validation.md`). CI
   enforces formatting, so never commit unformatted code.
4. Run `git diff --check` before staging and `git diff --cached --check`
   afterward.
5. Write a detailed commit message in Conventional Commits form:
   - Subject：`type(scope): 摘要`——imperative 祈使句，尽量 ≤ 50 字符、无句号。
     type 沿用仓库既有前缀（`feat`/`fix`/`refactor`/`docs`/`test`/`style`/`chore` 等），
     scope 为受影响模块（`relay`、`sdk`、`apps/ssh_mobile_full` 等）。语言与改动主体
     一致，中英文均可。
   - Body：subject 后空一行，说明"改了什么 + 为什么 + 关键影响"，比 subject 详细；
     多个逻辑点用 `-` 分条，单行不超过约 72 字符。涉及行为、协议、文档或较大改动时
     必须有 body；纯小改动且无行为/文档变化时才允许单行 subject。
   - 只提交暂存区内容，提交信息不与未暂存改动混在一起。
6. Verify success with `git status --short` and `git log -1 --oneline`.

- Do not amend, reset, force, or push unless the user explicitly requests that
  additional action.

## 提交信息示例

规范提交（subject + 详细 body，多个逻辑点分条）：

```
feat(relay): 引入 Storage/Cache 存储层并接入 MySQL/Redis 存储后端

- Storage/Cache 接口抽象 + 内存实现（默认 RELAY_STORAGE_MODE=memory）
- MySQL 持久化 enrollment/吊销（openMySQLStore、幂等 schema、-seed-enrollments 播种）
- Redis 共享状态层：presence、防重放 nonce（SET+Lua 128 上限）、admin 会话、共享状态事件（单 Relay 实例部署）
- mysql 模式强制要求 Redis；fail-open 降级（nonce 降级 + 日志告警）
```

小改动且无行为/文档变化时可用单行 subject：

```
fix(relay): 修正 refresh 忽略吊销 tombstone 的问题
```

需要说明改动理由时写完整 body：

```
docs(relay): 同步存储后端部署配置与文档

- compose 新增 storage profile（MySQL + Redis）与变量转发
- README（中英）注明 mysql 模式需 Redis 及新环境变量
```
