import 'dart:convert';

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

  test('loads, orders, edits, and persists shortcut commands', () async {
    const longId =
        'xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx';
    SharedPreferences.setMockInitialValues(<String, Object>{
      'shortcut_command_usage': '{"saved": 4.8, "unused": 2}',
      'shortcut_command_order': '["saved", "missing", "saved"]',
      'custom_shortcut_commands':
          '[{"id":"saved","label":"Saved","code":"echo saved","custom":true},'
          '{"id":"plain","label":"Plain","code":"pwd"}]',
      'terminal_keyboard_quick_keys': '["", "tab", "tab", "$longId", "home"]',
    });

    final service = ShortcutCommandService();
    var notifications = 0;
    service.addListener(() => notifications++);
    expect(service.initialized, isFalse);
    await service.init();

    expect(service.initialized, isTrue);
    expect(notifications, 1);
    expect(service.usageFor('saved'), 4);
    expect(service.usageFor('missing'), 0);
    expect(service.quickCommandIds, <String>['tab', 'home']);
    expect(service.customCommands.map((command) => command.id), <String>[
      'saved',
      'plain',
    ]);
    expect(service.customCommands.last.custom, isFalse);

    const commands = <ShortcutCommand>[
      ShortcutCommand(id: 'plain', label: 'Plain', code: 'pwd'),
      ShortcutCommand(id: 'saved', label: 'Saved', code: 'echo saved'),
      ShortcutCommand(id: 'new', label: 'New', code: 'echo new'),
    ];
    expect(service.sortByUsage(const <ShortcutCommand>[]), isEmpty);
    final sorted = service.sortByUsage(commands);
    expect(sorted.map((command) => command.id), <String>[
      'saved',
      'plain',
      'new',
    ]);

    await service.reorderCommands(<String>['new', 'new', 'saved']);
    expect(service.orderVersion, 1);
    expect(service.sortByUsage(commands).map((command) => command.id), <String>[
      'new',
      'saved',
      'plain',
    ]);

    await service.recordUse('saved');
    await service.recordUse('new');
    expect(service.usageFor('saved'), 5);
    expect(service.usageFor('new'), 1);
    await Future<void>.delayed(const Duration(milliseconds: 900));
    final prefs = await SharedPreferences.getInstance();
    expect(
      jsonDecode(prefs.getString('shortcut_command_usage')!),
      <String, dynamic>{'saved': 5, 'unused': 2, 'new': 1},
    );

    await service.addCustomCommand('  Added command  ', 'echo added');
    expect(service.customCommands, hasLength(3));
    final added = service.customCommands.last;
    expect(added.custom, isTrue);
    expect(added.label, 'Added command');
    expect(added.toJson(), containsPair('code', 'echo added'));
    expect(
      ShortcutCommand.fromJson(<String, dynamic>{
        'id': 'decoded',
        'label': 'Decoded',
        'code': 'echo decoded',
      }).custom,
      isFalse,
    );

    final beforeInvalidAdd = service.customCommands.length;
    await service.addCustomCommand('   ', 'echo ignored');
    await service.addCustomCommand('Ignored', '');
    expect(service.customCommands, hasLength(beforeInvalidAdd));

    await service.removeCustomCommand(added.id);
    await service.removeCustomCommand('does-not-exist');
    expect(service.customCommands, hasLength(2));
    expect(service.orderVersion, 4);

    final manyIds = <String>[
      '',
      longId,
      'first',
      'first',
      ...List<String>.generate(40, (index) => 'quick-$index'),
    ];
    await service.setQuickCommandIds(manyIds);
    expect(service.quickCommandIds, hasLength(32));
    expect(service.quickCommandIds.first, 'first');
    expect(service.quickCommandIds.toSet(), hasLength(32));
    final changedVersion = service.orderVersion;
    await service.setQuickCommandIds(service.quickCommandIds);
    expect(service.orderVersion, changedVersion);
    await service.resetQuickCommandIds();
    expect(
      service.quickCommandIds,
      ShortcutCommandService.defaultQuickCommandIds,
    );
    expect(service.orderVersion, changedVersion + 1);

    service.dispose();
  });

  test(
    'ignores malformed persisted shortcut state and restores defaults',
    () async {
      SharedPreferences.setMockInitialValues(<String, Object>{
        'shortcut_command_usage': '{not-json',
        'shortcut_command_order': '{not-a-list',
        'custom_shortcut_commands': '["not-a-command"]',
        'terminal_keyboard_quick_keys': '{not-a-list',
      });

      final service = ShortcutCommandService();
      await service.init();

      expect(service.initialized, isTrue);
      expect(service.customCommands, isEmpty);
      expect(
        service.quickCommandIds,
        ShortcutCommandService.defaultQuickCommandIds,
      );
      expect(service.sortByUsage(const <ShortcutCommand>[]), isEmpty);
      service.dispose();
    },
  );

  test('disposing a service cancels a pending usage write', () async {
    final service = ShortcutCommandService();
    await service.init();
    await service.recordUse('pending');
    service.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 900));

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('shortcut_command_usage'), contains('pending'));
  });
}
