import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_log_service.dart';

class ShortcutCommand {
  final String id;
  final String label;
  final String code;
  final bool custom;

  const ShortcutCommand({
    required this.id,
    required this.label,
    required this.code,
    this.custom = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'code': code,
        'custom': custom,
      };

  factory ShortcutCommand.fromJson(Map<String, dynamic> json) {
    return ShortcutCommand(
      id: json['id'] as String,
      label: json['label'] as String,
      code: json['code'] as String,
      custom: json['custom'] as bool? ?? false,
    );
  }
}

class ShortcutCommandService extends ChangeNotifier {
  static const _usageKey = 'shortcut_command_usage';
  static const _customKey = 'custom_shortcut_commands';
  static const _orderKey = 'shortcut_command_order';

  final Map<String, int> _usage = {};
  final List<String> _orderIds = [];
  final List<ShortcutCommand> _customCommands = [];
  List<ShortcutCommand> _customCommandsView = const [];
  Timer? _usageSaveTimer;
  int _orderVersion = 0;
  bool _initialized = false;

  bool get initialized => _initialized;
  List<ShortcutCommand> get customCommands => _customCommandsView;
  int get orderVersion => _orderVersion;

  Future<void> init() async {
    try {
      final prefs = await SharedPreferences.getInstance().timeout(
        const Duration(seconds: 3),
      );

      final usageJson = prefs.getString(_usageKey);
      if (usageJson != null && usageJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(usageJson) as Map<String, dynamic>;
          _usage
            ..clear()
            ..addAll(
              decoded.map(
                (key, value) => MapEntry(key, (value as num).toInt()),
              ),
            );
        } catch (e, stackTrace) {
          AppLogService.instance.add(
            'warning',
            'Failed to decode shortcut usage data: $e',
            stackTrace: stackTrace,
          );
        }
      }

      final orderJson = prefs.getString(_orderKey);
      if (orderJson != null && orderJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(orderJson) as List<dynamic>;
          _orderIds
            ..clear()
            ..addAll(decoded.whereType<String>());
        } catch (e, stackTrace) {
          AppLogService.instance.add(
            'warning',
            'Failed to decode shortcut order data: $e',
            stackTrace: stackTrace,
          );
        }
      }

      final customJson = prefs.getString(_customKey);
      if (customJson != null && customJson.isNotEmpty) {
        try {
          final decoded = jsonDecode(customJson) as List<dynamic>;
          _customCommands
            ..clear()
            ..addAll(
              decoded.map(
                (item) => ShortcutCommand.fromJson(
                  item as Map<String, dynamic>,
                ),
              ),
            );
          _refreshCustomCommandsView();
        } catch (e, stackTrace) {
          AppLogService.instance.add(
            'warning',
            'Failed to decode custom shortcut commands data: $e',
            stackTrace: stackTrace,
          );
        }
      }
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to initialize ShortcutCommandService',
        error: e,
        stackTrace: stackTrace,
      );
      _usage.clear();
      _orderIds.clear();
      _customCommands.clear();
      _refreshCustomCommandsView();
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  int usageFor(String id) => _usage[id] ?? 0;

  List<ShortcutCommand> sortByUsage(List<ShortcutCommand> commands) {
    if (_orderIds.isEmpty) return List.unmodifiable(commands);
    final byId = {for (final command in commands) command.id: command};
    final ordered = <ShortcutCommand>[];
    final used = <String>{};
    for (final id in _orderIds) {
      final command = byId[id];
      if (command == null || !used.add(id)) continue;
      ordered.add(command);
    }
    for (final command in commands) {
      if (used.add(command.id)) ordered.add(command);
    }
    return ordered;
  }

  Future<void> recordUse(String id) async {
    _usage[id] = usageFor(id) + 1;
    _scheduleUsageSave();
  }

  Future<void> reorderCommands(List<String> ids) async {
    final seen = <String>{};
    _orderIds
      ..clear()
      ..addAll(ids.where((id) => seen.add(id)));
    _orderVersion++;
    notifyListeners();
    await _saveOrder();
  }

  Future<void> addCustomCommand(String label, String code) async {
    final trimmedLabel = label.trim();
    if (trimmedLabel.isEmpty || code.isEmpty) return;

    final command = ShortcutCommand(
      id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
      label: trimmedLabel,
      code: code,
      custom: true,
    );
    _customCommands.add(command);
    _orderIds.add(command.id);
    _orderVersion++;
    _refreshCustomCommandsView();
    notifyListeners();
    AppLogService.instance.info(
      'Custom shortcut command added',
      details: 'label=$trimmedLabel code=$code',
    );
    await _saveOrder();
    await _saveCustomCommands();
  }

  Future<void> removeCustomCommand(String id) async {
    _customCommands.removeWhere((command) => command.id == id);
    _usage.remove(id);
    _orderIds.removeWhere((value) => value == id);
    _orderVersion++;
    _refreshCustomCommandsView();
    notifyListeners();

    AppLogService.instance.info(
      'Custom shortcut command removed',
      details: 'id=$id',
    );
    await _saveUsage();
    await _saveOrder();
    await _saveCustomCommands();
  }

  void _refreshCustomCommandsView() {
    _customCommandsView = List.unmodifiable(_customCommands);
  }

  void _scheduleUsageSave() {
    _usageSaveTimer?.cancel();
    _usageSaveTimer = Timer(const Duration(milliseconds: 800), () {
      _usageSaveTimer = null;
      unawaited(_saveUsage());
    });
  }

  Future<void> _saveUsage() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_usageKey, jsonEncode(_usage));
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to save shortcut usage data',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _saveOrder() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_orderKey, jsonEncode(_orderIds));
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to save shortcut order data',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  Future<void> _saveCustomCommands() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _customKey,
        jsonEncode(_customCommands.map((item) => item.toJson()).toList()),
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Failed to save custom shortcut commands',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  @override
  void dispose() {
    _usageSaveTimer?.cancel();
    unawaited(_saveUsage());
    super.dispose();
  }
}
