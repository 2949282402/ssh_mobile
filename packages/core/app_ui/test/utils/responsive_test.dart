import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:app_ui/app_ui.dart';

void main() {
  test('compact keyboard layout is limited to short obscured viewports', () {
    expect(
      usesCompactKeyboardLayoutFor(viewportHeight: 411, keyboardInset: 260),
      isTrue,
    );
    expect(
      usesCompactKeyboardLayoutFor(viewportHeight: 891, keyboardInset: 300),
      isFalse,
    );
    expect(
      usesCompactKeyboardLayoutFor(viewportHeight: 411, keyboardInset: 0),
      isFalse,
    );
  });

  test('adaptive width thresholds keep phone layouts readable', () {
    expect(usesCompactRailForHeight(479.9), isTrue);
    expect(usesCompactRailForHeight(480), isFalse);
    expect(supportsServerGridForWidth(719.9), isFalse);
    expect(supportsServerGridForWidth(720), isTrue);
    expect(usesExpandedLayoutForWidth(839.9), isFalse);
    expect(usesExpandedLayoutForWidth(840), isTrue);
    expect(settingsDrawerWidthFor(viewportWidth: 280, desktop: false), 280);
    expect(
      settingsDrawerWidthFor(viewportWidth: 411, desktop: false),
      closeTo(378.12, 0.001),
    );
    expect(settingsDrawerWidthFor(viewportWidth: 1600, desktop: true), 560);
  });

  group('WindowSizeClass', () {
    test('classifies window widths into correct size classes', () {
      expect(WindowSizeClass.fromWidth(320), WindowSizeClass.compact);
      expect(WindowSizeClass.fromWidth(599), WindowSizeClass.compact);
      expect(WindowSizeClass.fromWidth(600), WindowSizeClass.medium);
      expect(WindowSizeClass.fromWidth(839), WindowSizeClass.medium);
      expect(WindowSizeClass.fromWidth(840), WindowSizeClass.expanded);
      expect(WindowSizeClass.fromWidth(1279), WindowSizeClass.expanded);
      expect(WindowSizeClass.fromWidth(1280), WindowSizeClass.large);
      expect(WindowSizeClass.fromWidth(1920), WindowSizeClass.large);
    });

    test('isExpandedOrLarger returns true for expanded and large', () {
      expect(WindowSizeClass.compact.isExpandedOrLarger, isFalse);
      expect(WindowSizeClass.medium.isExpandedOrLarger, isFalse);
      expect(WindowSizeClass.expanded.isExpandedOrLarger, isTrue);
      expect(WindowSizeClass.large.isExpandedOrLarger, isTrue);
    });
  });

  group('MobileUiMetrics', () {
    test('keeps standard metrics consistent', () {
      final metrics = MobileUiMetrics.fromMetrics(
        size: const Size(1280 / 3, 2856 / 3),
        devicePixelRatio: 3,
        mobileTargetOverride: false,
      );

      expect(metrics.controlScale, 1.0);
      expect(metrics.chromeScale, 1.0);
      expect(metrics.visualDensity, VisualDensity.standard);
      expect(metrics.navigationHeight, 56.0);
      expect(metrics.navigationHorizontalInset, 0.0);
      expect(metrics.navigationBottomInset, 0.0);
    });

    test(
      'mobile target returns standard metrics without resolution interpolation',
      () {
        final metrics = MobileUiMetrics.fromMetrics(
          size: const Size(1280 / 3, 2856 / 3),
          devicePixelRatio: 3,
          mobileTargetOverride: true,
        );

        expect(metrics.controlScale, 1.0);
        expect(metrics.chromeScale, 1.0);
        expect(metrics.navigationHeight, 56.0);
        expect(metrics.visualDensity, VisualDensity.standard);
      },
    );
  });
}
