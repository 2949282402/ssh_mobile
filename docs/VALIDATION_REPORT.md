# Validation Report

> 最新更新时间：2026-07-26

- Latest source validation: 2026-07-17
- Full build/coverage baseline: 2026-07-10
- Host: Windows 10 x64
- Flutter: 3.44.2 stable
- Dart: 3.12.2

## Automated Results

Formatting, analysis, tests, and the source-size audit were refreshed after the
repository-wide modular refactor. Coverage and platform-build rows retain the
most recent full release-chain evidence from 2026-07-10 and were not re-run for
this documentation update.

| Check | Result |
| --- | --- |
| Dart formatting | 459 files checked, 0 changes required |
| Flutter analyzer | Passed with 0 issues |
| Unit and widget tests | 829 passed |
| Non-generated Dart file size | All below 1000 lines; generated `app_database.g.dart` excluded |
| Non-generated line coverage | 39.3% (`12690/32302`), last verified 2026-07-10 |
| Coverage regression floor | 35% |
| Android debug APK | Built successfully |
| Android release APK | Built successfully without signing credentials |
| Android release signature check | Expected unsigned result confirmed with `apksigner` |
| Windows release executable | Built successfully |
| App icon generation | Deterministic across 33 PNG targets and one ICO target |
| Drift generated database code | Deterministic on a second build |
| Shared Codex/Claude maintenance skill | Synchronized |
| Web manifest JSON and Git diff checks | Passed |

## Commands

Latest source validation:

```powershell
dart format --output=none --set-exit-if-changed lib test
flutter analyze
flutter test
git diff --check
```

Full build and coverage baseline from 2026-07-10:

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool
dart run build_runner build
flutter analyze --no-pub
flutter test --no-pub --coverage
dart run tool/check_coverage.dart --minimum=35
flutter build apk --debug --no-pub
flutter build apk --release --no-pub
flutter build windows --no-pub
```

The unsigned Android release is a build-chain verification artifact, not a
publishable APK. Configure the release signing environment variables documented
in `docs/RELEASE_CHECKLIST.md` before distribution.

## Not Verified on This Host

- Android touch, lifecycle, background execution, network switching, and
  performance on a physical device
- iOS device behavior and signed archive creation
- macOS and unsigned iOS jobs in the updated GitHub Actions workflow
- TalkBack and VoiceOver behavior on physical devices
- Store metadata, privacy policy, permanent application identifiers, and legal
  license choice

These remaining items require owner decisions, external accounts, CI execution,
or physical devices and are tracked in `docs/RELEASE_CHECKLIST.md`.
