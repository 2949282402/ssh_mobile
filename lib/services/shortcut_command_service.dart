import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

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

  final Map<String, int> _usage = {};
  final List<ShortcutCommand> _customCommands = [];
  bool _initialized = false;

  bool get initialized => _initialized;
  List<ShortcutCommand> get customCommands =>
      List.unmodifiable(_customCommands);

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
        } catch (_) {}
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
        } catch (_) {}
      }
    } catch (_) {
      _usage.clear();
      _customCommands.clear();
    } finally {
      _initialized = true;
      notifyListeners();
    }
  }

  int usageFor(String id) => _usage[id] ?? 0;

  List<ShortcutCommand> sortByUsage(List<ShortcutCommand> commands) {
    final indexed = commands.indexed.toList();
    indexed.sort((a, b) {
      final usageCompare = usageFor(b.$2.id).compareTo(usageFor(a.$2.id));
      if (usageCompare != 0) return usageCompare;
      return a.$1.compareTo(b.$1);
    });
    return indexed.map((item) => item.$2).toList();
  }

  Future<void> recordUse(String id) async {
    _usage[id] = usageFor(id) + 1;
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usageKey, jsonEncode(_usage));
  }

  Future<void> addCustomCommand(String label, String code) async {
    final trimmedLabel = label.trim();
    if (trimmedLabel.isEmpty || code.isEmpty) return;

    _customCommands.add(
      ShortcutCommand(
        id: 'custom_${DateTime.now().microsecondsSinceEpoch}',
        label: trimmedLabel,
        code: code,
        custom: true,
      ),
    );
    notifyListeners();
    await _saveCustomCommands();
  }

  Future<void> removeCustomCommand(String id) async {
    _customCommands.removeWhere((command) => command.id == id);
    _usage.remove(id);
    notifyListeners();

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_usageKey, jsonEncode(_usage));
    await _saveCustomCommands();
  }

  Future<void> _saveCustomCommands() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _customKey,
      jsonEncode(_customCommands.map((item) => item.toJson()).toList()),
    );
  }
}
