import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:ssh_mobile/services/shortcut_command_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('loads defaults and persists customized quick keys', () async {
    final service = ShortcutCommandService();
    await service.init();
    addTearDown(service.dispose);

    expect(
      service.quickCommandIds,
      ShortcutCommandService.defaultQuickCommandIds,
    );

    await service.setQuickCommandIds(['tab', 'home', 'ctrl_d', 'tab']);
    expect(service.quickCommandIds, ['tab', 'home', 'ctrl_d']);

    final reloaded = ShortcutCommandService();
    await reloaded.init();
    addTearDown(reloaded.dispose);
    expect(reloaded.quickCommandIds, ['tab', 'home', 'ctrl_d']);
  });

  test('rejects an empty quick-key selection', () async {
    final service = ShortcutCommandService();
    await service.init();
    addTearDown(service.dispose);

    await service.setQuickCommandIds(const []);

    expect(
      service.quickCommandIds,
      ShortcutCommandService.defaultQuickCommandIds,
    );
  });
}
