# Mobile UI QA

This document records the Android visual test matrix used for SSH Mobile. It
keeps high-density phone checks reproducible without storing machine-local SDK
paths or emulator snapshots in the repository.

## Device matrix

| Profile | Physical display | Density | Approx. logical display | Control scale | Chrome scale |
| --- | ---: | ---: | ---: | ---: | ---: |
| Pixel 9 Pro (`ssh_mobile_15k`) | 1280 × 2856 | 480 dpi | 426.7 × 952.0 dp | 0.84 | 0.952 |
| Pixel 6 Pro (`ssh_mobile_2k`) | 1440 × 3120 | 560 dpi | 411.4 × 891.4 dp | 0.92 | 1.0 |

Both AVDs use the Android 35 Google Play x86_64 system image. The 1280 px and
1440 px physical short edges exercise the interpolation range in
`lib/utils/responsive.dart` instead of testing only one density bucket.
`MobileUiMetrics` is the single source for these mobile control, chrome, and
visual-density corrections. It deliberately leaves the system text scale
unchanged for accessibility.

## Visual baseline

- Verify the light and dark palettes match the desktop design tokens in
  `lib/theme/app_theme.dart`.
- Compare relative header, card, navigation, input, and action sizes between
  both devices. Small differences are expected from their logical dimensions,
  but neither device should look materially denser or more oversized.
- Check system status/navigation insets, the software keyboard, long Chinese and
  English labels, empty states, dialogs, sheets, and landscape layouts.
- Capture the first-launch background-service guide and the settled Servers,
  SFTP, AI, System Admin, Logs, Settings, and connection-form screens.
- Treat any Flutter overflow or clipped tappable target as a failed visual gate.

## Baseline observations

- The shared violet palette and primary empty-state styling already render on
  both density classes.
- The home screen's main proportions are close across 1280 px and 1440 px short
  edges, so the physical-short-edge interpolation remains the correct basis for
  the mobile correction.
- The five mobile navigation targets remain fully visible, selectable, and
  semantically labeled on both profiles after applying the shared metrics. The
  1280 px profile uses slightly tighter chrome; the 1440 px profile keeps the
  standard 68 dp navigation height.
- The connection form uses shared icon-led section cards on both profiles. Its
  collapsible jump-host and advanced headers expose full-width semantic button
  targets, the password visibility action is labeled, and focusing an input
  hides the sticky save bar so the keyboard does not cover the active field.
  Long English authentication choices wrap without overflow.
- The first-launch background-service guide and less common routes still need a
  consistency pass against the shared page-surface components.
- Cold startup remained on the native black launch surface for a noticeable
  interval on fresh AVD data. Startup initialization and native launch styling
  require a dedicated performance-stage audit.

## Re-test commands

Resolve Flutter and the Android SDK from the environment or Flutter tooling;
do not add local absolute paths to scripts or documentation.

```powershell
flutter emulators
flutter build apk --debug
flutter devices
```

Install the generated debug APK on each AVD, clear app data when testing the
first-launch guide, and capture screenshots only after the frame is stable.
