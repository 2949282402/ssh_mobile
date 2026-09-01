import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('AppSpacing provides consistent spacing constants', () {
    expect(AppSpacing.spacingXs, 4.0);
    expect(AppSpacing.spacingSm, 8.0);
    expect(AppSpacing.spacingMd, 12.0);
    expect(AppSpacing.spacingLg, 16.0);
    expect(AppSpacing.spacingXl, 24.0);
    expect(AppSpacing.spacing2Xl, 32.0);

    expect(AppSpacing.xs, 4.0);
    expect(AppSpacing.sm, 8.0);
    expect(AppSpacing.md, 12.0);
    expect(AppSpacing.lg, 16.0);
    expect(AppSpacing.xl, 24.0);
    expect(AppSpacing.xxl, 32.0);
  });

  testWidgets('AppSpacing extension provides tokens via context', (
    tester,
  ) async {
    late AppSpacingTokens tokens;

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            tokens = context.spacing;
            return const SizedBox();
          },
        ),
      ),
    );

    expect(tokens.xs, 4.0);
    expect(tokens.sm, 8.0);
    expect(tokens.md, 12.0);
    expect(tokens.lg, 16.0);
    expect(tokens.xl, 24.0);
    expect(tokens.xxl, 32.0);
  });
}
