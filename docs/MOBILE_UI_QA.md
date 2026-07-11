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

The layout thresholds follow Android's current
[window size classes](https://developer.android.com/develop/adaptive-apps/guides/use-window-size-classes):
expanded width starts at 840 dp and compact height ends at 480 dp. SSH Mobile
uses an app-specific 720 dp minimum before rendering the denser Servers grid.

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
- The Servers header exposes a visible 48 dp settings action in portrait. A
  saved Grid preference safely falls back to the reorderable list below 720 dp,
  list drag handles remain 48 dp, unknown health no longer reads as score zero,
  and scroll padding clears both app navigation and the system inset.
- Both landscape profiles exceed 840 dp width but remain below 480 dp height,
  so they consistently use the icon-only compact rail. All five destinations
  plus Settings remain visible with no RenderFlex overflow on either AVD.
- The Settings drawer stays within both portrait viewports and removes the
  duplicate in-panel page header. Language exposes one semantic button with
  its current value, the list/grid control remains on one line in Chinese and
  English, custom-font helper text may wrap to two lines, cache timeout displays
  its value only once, and the final import row clears the gesture inset.
- The connection form uses shared icon-led section cards on both profiles. Its
  collapsible jump-host and advanced headers expose full-width semantic button
  targets, the password visibility action is labeled, and focusing an input
  hides the sticky save bar so the keyboard does not cover the active field.
  Long English authentication choices wrap without overflow.
- AI Chat keeps its header in normal document flow and re-aligns the selected
  page when rotation crosses the 840 dp navigation breakpoint. Its adaptive
  shell keeps the page subtree stable so focus and unsent drafts survive the
  bottom-navigation-to-rail transition. The composer is
  one rounded input surface with 48 dp Tools and Send targets, a single-line
  hint, and a height-limited scrolling area for plan, command, attachment, and
  tool content. On compact-height keyboard layouts, tools collapse and the
  decorative chat header and rail stop consuming the remaining input space.
  New chats use a centered bilingual empty state with three 48 dp starter
  actions; selecting one only fills and focuses the composer for review.
  Tool approvals keep the full risk reason, target, path, command, and preview
  in one scrollable details region while 48 dp Reject and Approve actions stay
  fixed and reachable on compact-height layouts.
  Chat history animates with normalized progress so an open panel remains full
  width after rotation. It blocks background semantics and Android Back closes
  the history layer before attempting to leave the current route.
  The AI tools grid derives three to six columns from available width, shows
  all rows through the composer's outer scrolling region, and keeps attachment
  removal actions at 48 dp while long filenames ellipsize safely.
  Message copy, edit, retry, branch, and trace controls expose 48 dp targets;
  action groups wrap on narrow messages, sent attachment names stay bounded,
  and trace summaries localize without overflowing their message column. The
  message editor derives its height from the keyboard-visible viewport, keeps
  both actions at 48 dp in compact landscape, and rejects whitespace-only
  resubmissions without dismissing the draft.
- LLM settings intercept Android Back and the close affordance when edits are
  pending, then require an explicit discard confirmation. Saving
  temporarily disables route dismissal, while model-refresh and save failures
  remain visible at the top of the form and in a floating snackbar.
  The form uses the shared page and section surfaces, caps its desktop reading
  width at 760 dp, keeps connection essentials expanded, and folds advanced
  model routing and low-frequency groups behind semantic 48 dp headers. Its
  quiet filled fields avoid repeated card-within-field outlines on mobile.
  Settled 1.5K and 2K AVD captures show the same hierarchy and materially
  equivalent proportions without clipped labels or horizontal overflow.
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
