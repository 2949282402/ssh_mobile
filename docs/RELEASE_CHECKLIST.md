> Last updated: 2026-08-31

# Release and Portfolio Checklist

This checklist separates repository work that can be automated from decisions
that require the project owner's identity, signing credentials, devices, or
legal choice. Never commit signing keys, passwords, API keys, or server data.

## Completed in the Repository

- Direct Dart dependencies use explicit compatible version ranges.
- The Dart and Flutter SDK floor matches the current lockfile baseline.
- GitHub Actions pins Flutter and checks formatting, analysis, tests, coverage,
  Android compilation, Windows compilation, macOS compilation, and an unsigned
  iOS build.
- The native network package exposes a bounded typed Realtime Dart facade over
  the existing command/event FFI ABI; native runtime state and WebRTC handles
  remain owned by Rust, and no Flutter UI/client business code depends on raw
  native objects.
- Dependabot checks Dart packages and GitHub Actions weekly.
- The app has a custom icon across Android, iOS, macOS, Windows, and Web.
- Custom mobile navigation items expose labels, button actions, and selected
  state to accessibility services.
- Generated coverage output is ignored by Git.

## Owner Decisions Required

- [ ] Choose a permanent Android application ID and Apple bundle ID. Changing
      these identifiers after publishing creates a different app identity.
- [ ] Create release signing credentials outside the repository and configure
      the four environment variables below locally or as protected CI secrets.
- [ ] Choose an open-source or source-available license and add `LICENSE`.
- [ ] Add the publisher name, privacy contact, support URL, and privacy policy.
- [ ] Confirm whether Web and desktop builds are public deliverables or only
      development/portfolio targets.

## Real-device Acceptance

Record device, OS version, build mode, commit, and result for each run.

- [ ] Android: first launch, notification permission, battery optimization
      guide, background/foreground, process recreation, and network switching.
- [ ] Android: SSH password/private-key login, Host Key trust and mismatch,
      terminal input, selection, clipboard, and large-output responsiveness.
- [ ] Android: SFTP upload/download/preview/edit/delete with large files and
      interrupted connectivity.
- [ ] Android: monitor several servers for at least ten minutes while checking
      frame times and memory in Flutter DevTools.
- [ ] iOS: build and run on a physical device, verify Keychain writes, lifecycle
      behavior, file picking, notifications, and background limitations.
- [ ] Tablet/foldable: portrait, landscape, keyboard, split-screen, and large
      text scale.
- [ ] Screen reader: TalkBack/VoiceOver navigation order, labels, selected
      states, destructive confirmations, and form errors.

## Android Release Signing

Release builds never fall back to the Android debug key. Configure all four
variables before producing a publishable APK or AAB:

- `SSH_MOBILE_KEYSTORE_FILE`: path to the release keystore
- `SSH_MOBILE_KEYSTORE_PASSWORD`: keystore password
- `SSH_MOBILE_KEY_ALIAS`: signing key alias
- `SSH_MOBILE_KEY_PASSWORD`: signing key password

Keystores and `android/key.properties` are ignored by Git. If the environment
variables are absent, Gradle produces an unsigned release artifact.

## Portfolio Capture

- [ ] Use sanitized demo accounts only; hide server names, addresses, usernames,
      terminal history, paths, logs, API endpoints, and notification content.
- [ ] Capture five core flows: Servers, Terminal, SFTP, Monitor, and AI approval.
- [ ] Record a 30–60 second mobile walkthrough without cuts that hide loading or
      error states.
- [ ] Add measured DevTools results for terminal output, long AI streaming,
      large SFTP directories, and multi-server monitoring.
- [ ] Attach a release APK or GitHub Release only after signing and security
      regression checks are complete.

## Final Commands

```powershell
flutter pub get
dart format --output=none --set-exit-if-changed lib test tool
flutter analyze
flutter test --coverage
dart run tool/check_coverage.dart --minimum=90 --source-root=lib
flutter build apk --debug --no-pub
```

Run the manual security checklist in `docs/security_manual_regression.md` and
the performance scenarios in `docs/PERFORMANCE_ACCEPTANCE.md` before publishing.
