import 'package:app_core/app_core.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_ai/feature_ai.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

final class _FakeAiStorage implements AiStoragePort {
  List<AiSkillRecord> skills = const [];

  @override
  Future<List<AiSkillRecord>> loadAiSkills() async => skills;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class _FakeAiSettings extends ChangeNotifier implements AiSettingsPort {
  @override
  AppLanguage language = AppLanguage.en;

  @override
  bool get isEnglish => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets(
    'AiSkillsScreen renders AppSkeletonizer when loading with empty skills',
    (tester) async {
      final storage = _FakeAiStorage();
      final settings = _FakeAiSettings();
      final viewModel = AiSkillsViewModel(
        storageService: storage,
        appSettings: settings,
      );

      await tester.pumpWidget(
        ChangeNotifierProvider.value(
          value: viewModel,
          child: const MaterialApp(home: AiSkillsScreen()),
        ),
      );

      expect(find.byType(AppSkeletonizer), findsOneWidget);
    },
  );
}
