import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/utils/responsive.dart';

void main() {
  test('adaptive width thresholds keep phone layouts readable', () {
    expect(usesCompactRailForHeight(479.9), isTrue);
    expect(usesCompactRailForHeight(480), isFalse);
    expect(supportsServerGridForWidth(719.9), isFalse);
    expect(supportsServerGridForWidth(720), isTrue);
    expect(usesExpandedLayoutForWidth(839.9), isFalse);
    expect(usesExpandedLayoutForWidth(840), isTrue);
  });

  group('MobileUiMetrics', () {
    test('keeps desktop metrics unchanged', () {
      final metrics = MobileUiMetrics.fromMetrics(
        size: const Size(1280 / 3, 2856 / 3),
        devicePixelRatio: 3,
        mobileTargetOverride: false,
      );

      expect(metrics.controlScale, 1);
      expect(metrics.chromeScale, 1);
      expect(metrics.visualDensity, VisualDensity.standard);
    });

    test('applies the narrow 1.5K correction', () {
      final metrics = MobileUiMetrics.fromMetrics(
        size: const Size(1280 / 3, 2856 / 3),
        devicePixelRatio: 3,
        mobileTargetOverride: true,
      );

      expect(metrics.controlScale, closeTo(0.84, 0.0001));
      expect(metrics.chromeScale, closeTo(0.952, 0.0001));
      expect(metrics.navigationHeight, closeTo(64.736, 0.001));
      expect(metrics.visualDensity.horizontal, closeTo(-0.4, 0.0001));
      expect(metrics.visualDensity.vertical, closeTo(-0.4, 0.0001));
    });

    test('uses standard chrome at the 2K boundary', () {
      final metrics = MobileUiMetrics.fromMetrics(
        size: const Size(1440 / 3.5, 3120 / 3.5),
        devicePixelRatio: 3.5,
        mobileTargetOverride: true,
      );

      expect(metrics.controlScale, closeTo(0.92, 0.0001));
      expect(metrics.chromeScale, 1);
      expect(metrics.navigationHeight, 68);
      expect(metrics.visualDensity, VisualDensity.standard);
    });

    test('interpolates monotonically between density classes', () {
      final low = MobileUiMetrics.fromMetrics(
        size: const Size(1240 / 3, 2700 / 3),
        devicePixelRatio: 3,
        mobileTargetOverride: true,
      );
      final middle = MobileUiMetrics.fromMetrics(
        size: const Size(1340 / 3.2, 2900 / 3.2),
        devicePixelRatio: 3.2,
        mobileTargetOverride: true,
      );
      final high = MobileUiMetrics.fromMetrics(
        size: const Size(1440 / 3.5, 3120 / 3.5),
        devicePixelRatio: 3.5,
        mobileTargetOverride: true,
      );

      expect(low.controlScale, lessThan(middle.controlScale));
      expect(middle.controlScale, lessThan(high.controlScale));
      expect(low.chromeScale, lessThan(middle.chromeScale));
      expect(middle.chromeScale, lessThan(high.chromeScale));
    });
  });
}
