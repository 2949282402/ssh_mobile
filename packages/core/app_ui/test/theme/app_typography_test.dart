import 'package:app_ui/app_ui.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('AppTypography provides standard typography tokens', (
    tester,
  ) async {
    late AppTypography typography;

    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.lightTheme,
        home: Builder(
          builder: (context) {
            typography = AppTypography.of(context);
            return Scaffold(
              body: Column(
                children: [
                  Text('Page Title', style: typography.pageTitle),
                  Text('Section Title', style: typography.sectionTitle),
                  Text('Body', style: typography.body),
                  Text('Body Medium', style: typography.bodyMedium),
                  Text('Metadata', style: typography.metadata),
                  Text('Caption', style: typography.caption),
                  Text('Code', style: typography.code),
                  Text('Code Small', style: typography.codeSmall),
                  Text('Button', style: typography.button),
                ],
              ),
            );
          },
        ),
      ),
    );

    expect(typography.pageTitle.fontSize, 20.0);
    expect(typography.pageTitle.fontWeight, FontWeight.w600);
    expect(typography.sectionTitle.fontSize, 15.0);
    expect(typography.sectionTitle.fontWeight, FontWeight.w600);
    expect(typography.body.fontSize, 14.0);
    expect(typography.bodyMedium.fontSize, 13.0);
    expect(typography.metadata.fontSize, 12.0);
    expect(typography.caption.fontSize, 11.0);
    expect(typography.code.fontSize, 13.0);
    expect(typography.codeSmall.fontSize, 11.0);
    expect(typography.button.fontSize, 13.0);
  });
}
