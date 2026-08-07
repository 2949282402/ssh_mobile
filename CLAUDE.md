# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> 最新更新时间：2026-08-07

SSH Mobile is a Flutter (Dart) cross-platform SSH / SFTP, server monitoring, and
client-side AI-agent client for Android, iOS, macOS, Windows, and Web. The AI
runtime and tool loop run on the device; remote systems are reached through
SSH/SFTP.

Use `AGENTS.md` as the authoritative repository guide for structure, architecture,
coding rules, commands, testing, documentation markers, and security
expectations. Do not duplicate those rules here — this file only routes and
quick-references.

## First steps for non-trivial work

1. Read `AGENT_MEMORY.md` (durable, non-obvious decisions; not a changelog).
2. Follow `.claude/skills/ssh-mobile-maintenance/SKILL.md` for task routing and
   safety boundaries, and load only the task-specific code and references it
   routes to.
3. Validate proportional to the change and report what was not verified.

## Quick commands

- `dart pub get` — resolve the root workspace (after any workspace member
  `pubspec.yaml` or Drift changes).
- `dart format --output=none --set-exit-if-changed apps/ssh_mobile_full/lib apps/ssh_mobile_full/test apps/ssh_mobile_full/tool` — format check.
- From `apps/ssh_mobile_full/`, `flutter analyze` — static analysis.
- From `apps/ssh_mobile_full/`, `flutter test` — all tests;
  `flutter test test/path/foo_test.dart` — one file.
- From `apps/ssh_mobile_full/`, `dart run build_runner build` — regenerate
  Drift DAOs and other codegen.

Full quality gate (incl. coverage floor), icon/Doc codegen, and platform builds:
see `AGENTS.md`.

## Operational notes

- Development happens on Windows; prefer PowerShell for one-off commands.
- UI copy is centralized and bilingual (Chinese/English) in `AppStrings` /
  `TerminalStrings`; route app diagnostics through `AppLogService`, never `print`.
- Keep non-generated Dart files under 1000 lines; edit generator inputs, never
  generated `*.g.dart`.
- Credentials and API keys stay in platform secure storage, never in code, logs,
  docs, or commits.
- After editing a shared agent skill, sync it:
  `powershell -ExecutionPolicy Bypass -File .\scripts\sync_agent_skills.ps1 -Mode Check`
