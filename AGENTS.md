# Repository Guidelines

## Project Structure & Module Organization

This is a Flutter app for SSH, SFTP, server monitoring (including general metrics, port usage, process application performance, and service status), logs, and OpenAI-compatible AI tools. Main Dart code lives in `lib/`: `screens/` for pages, `services/` for SSH/SFTP/storage/LLM logic, `models/` for connection data, `theme/` for shared styling, plus `utils/` and `widgets/`. Platform projects are in `android/`, `ios/`, `macos/`, and `windows/`. Static files belong in `assets/`, tests in `test/`, packaging scripts in `scripts/`, installer files in `installer/`, and longer design docs in `docs/`. The vendored terminal package under `third_party/xterm/` is excluded from the root analyzer.

## Build, Test, and Development Commands

- `flutter pub get`: install dependencies from `pubspec.yaml`.
- `dart format lib test`: format project Dart code.
- `flutter analyze`: run static analysis using `analysis_options.yaml`.
- `flutter test`: run Flutter tests in `test/`.
- `flutter devices`: list available targets.
- `flutter run -d <device-id>`: run locally on a device, emulator, or desktop target.
- `flutter build apk --debug`: build an Android debug APK.
- `flutter build windows`: build the Windows desktop app.
- `powershell -ExecutionPolicy Bypass -File .\scripts\build_windows_msi.ps1`: build the Windows MSI installer.

## Coding Style & Naming Conventions

Use standard Dart formatting and `flutter_lints`. Prefer two-space indentation, `lower_snake_case.dart` filenames, `UpperCamelCase` classes/widgets, and `lowerCamelCase` members. Keep UI text centralized in `AppStrings`/`TerminalStrings` with Chinese and English entries. Route logs through `AppLogService`; do not use ad hoc `print` calls for app diagnostics. Keep UI styling consistent with `lib/theme/app_theme.dart`.

## Testing Guidelines

Add focused tests under `test/` with names ending in `_test.dart`. Use `flutter_test` for widget and unit coverage. Run `flutter test` and `flutter analyze` before submitting changes. Broaden tests when touching shared services such as storage, SSH/SFTP behavior, LLM tool dispatch, or platform branching.

## Commit & Pull Request Guidelines

Recent commit subjects are short and direct, often English or Chinese, for example `add log`, `update`, or `font config`. Keep commits scoped and imperative when possible. Pull requests should include a clear summary, validation commands run, linked issues if applicable, and screenshots or screen recordings for UI changes.

## Security & Agent-Specific Notes

Never commit passwords, private keys, API keys, tokens, or server credentials. Store secrets through `flutter_secure_storage`, not `SharedPreferences`, and keep exports credential-free. Read `AGENT_MEMORY.md` before non-trivial maintenance work. Keep `.agents/skills/ssh-mobile-maintenance/SKILL.md` and `.claude/skills/ssh-mobile-maintenance/SKILL.md` synchronized with `.\scripts\sync_agent_skills.ps1 -Mode Check` after skill edits.
