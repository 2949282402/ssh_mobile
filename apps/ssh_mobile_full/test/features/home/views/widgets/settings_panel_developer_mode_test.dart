import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import '../../../../test_utils/test_storage_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late TestStorageAdapter storageService;
  late AppSettings appSettings;
  late SettingsViewModel viewModel;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storageService = TestStorageAdapter();
    await storageService.init();
    appSettings = AppSettings();
    await appSettings.init();
    viewModel = SettingsViewModel(
      appSettings: appSettings,
      aiStorage: storageService.aiStorage,
    );
  });

  tearDown(() {
    viewModel.dispose();
    storageService.dispose();
  });

  testWidgets(
    'toggling developer mode rebuilds subscribed UI and reveals panel entries',
    (tester) async {
      // Mirrors _SettingsPanel: it subscribes via context.select on a snapshot
      // that now includes developerMode, and shows the developer panel / log
      // entries only when settings.developerMode is true. A regression here
      // (developerMode dropped from the select snapshot) left the toggle
      // visually unresponsive because the panel never rebuilt.
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ChangeNotifierProvider<SettingsViewModel>.value(
              value: viewModel,
              child: Builder(
                builder: (context) {
                  final developerMode = context.select<SettingsViewModel, bool>(
                    (vm) => vm.developerMode,
                  );
                  return ListView(
                    children: [
                      SwitchListTile(
                        value: developerMode,
                        onChanged: viewModel.setDeveloperMode,
                      ),
                      if (developerMode) const Text('DeveloperPanelEntry'),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      );

      expect(viewModel.developerMode, isFalse);
      expect(find.text('DeveloperPanelEntry'), findsNothing);

      await tester.tap(find.byType(SwitchListTile));
      await tester.pumpAndSettle();

      expect(viewModel.developerMode, isTrue);
      // The subscribed UI rebuilt: the conditional entry is shown and the
      // Switch reflects the new value.
      expect(find.text('DeveloperPanelEntry'), findsOneWidget);
      final switchTile = tester.widget<SwitchListTile>(
        find.byType(SwitchListTile),
      );
      expect(switchTile.value, isTrue);
    },
  );
}
