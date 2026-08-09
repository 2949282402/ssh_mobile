import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:app_core/app_core.dart';

import '../domain/developer_ports.dart';

/// Developer Log 路由的 ViewModel，负责筛选、选择、复制和删除操作。
///
/// ViewModel 只依赖日志与设置的只读/受控 Port；日志存储、脱敏和持久化
/// 仍由 App Scope Owner 管理，避免 Developer Feature 反向依赖 App Shell。
final class DeveloperLogViewModel extends ChangeNotifier {
  final DeveloperLogPort _logService;
  final DeveloperSettingsPort _settings;

  DeveloperLogLevel _selectedLevel = DeveloperLogLevel.all;
  final Set<int> _selectedIds = {};

  /// 创建开发者日志页面状态。
  DeveloperLogViewModel({
    required DeveloperLogPort logService,
    required DeveloperSettingsPort settings,
  }) : _logService = logService,
       _settings = settings {
    _logService.addListener(_onLogsChanged);
  }

  /// 释放日志监听，避免路由退出后继续触发 UI 通知。
  @override
  void dispose() {
    _logService.removeListener(_onLogsChanged);
    super.dispose();
  }

  void _onLogsChanged() {
    _pruneStaleSelections(notify: false);
    notifyListeners();
  }

  /// 当前选择的日志级别。
  DeveloperLogLevel get selectedLevel => _selectedLevel;

  /// 当前选择的日志 ID。
  Set<int> get selectedIds => _selectedIds;

  /// 是否进入多选模式。
  bool get selectionMode => _selectedIds.isNotEmpty;

  /// 当前页面语言。
  AppLanguage get language => _settings.language;

  /// 是否存在日志。
  bool get hasEntries => _logService.entries.isNotEmpty;

  /// 各级别日志条数。
  Map<DeveloperLogLevel, int> get levelCounts => _logService.levelCounts;

  /// 当前筛选结果。
  List<DeveloperLogEntry> get filteredEntries =>
      _logService.entriesForLevel(_selectedLevel);

  /// 当前已选择的日志。
  List<DeveloperLogEntry> get selectedEntries {
    if (_selectedIds.isEmpty) return const <DeveloperLogEntry>[];
    return [
      for (final entry in _logService.entries)
        if (_selectedIds.contains(entry.id)) entry,
    ];
  }

  /// 修改日志筛选级别。
  void setSelectedLevel(DeveloperLogLevel level) {
    if (_selectedLevel == level) return;
    _selectedLevel = level;
    notifyListeners();
  }

  /// 切换单条日志的选中状态。
  void toggleEntrySelection(DeveloperLogEntry entry) {
    if (!_selectedIds.add(entry.id)) {
      _selectedIds.remove(entry.id);
    }
    notifyListeners();
  }

  /// 选中单条日志并进入多选模式。
  void selectEntry(DeveloperLogEntry entry) {
    _selectedIds.add(entry.id);
    notifyListeners();
  }

  /// 清除当前选择。
  void clearSelection() {
    _selectedIds.clear();
    notifyListeners();
  }

  /// 清理日志已被外部删除后的失效选择。
  void pruneStaleSelections() {
    _pruneStaleSelections();
  }

  void _pruneStaleSelections({bool notify = true}) {
    final entryIds = _logService.entryIds;
    final staleIds = [
      for (final id in _selectedIds)
        if (!entryIds.contains(id)) id,
    ];
    if (staleIds.isNotEmpty) {
      _selectedIds.removeAll(staleIds);
      if (notify) notifyListeners();
    }
  }

  /// 复制当前选中日志或筛选结果。
  Future<bool> copySelectedOrFilteredLogs() async {
    final entries = selectionMode ? selectedEntries : filteredEntries;
    if (entries.isEmpty) return false;
    await Clipboard.setData(
      ClipboardData(text: entries.reversed.map((e) => e.text).join('\n\n')),
    );
    return true;
  }

  /// 复制单条日志。
  Future<void> copySingleLog(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  /// 删除当前选择并返回删除数量。
  int deleteSelectedLogs() {
    final count = _selectedIds.length;
    _logService.deleteEntriesById(_selectedIds);
    _selectedIds.clear();
    notifyListeners();
    return count;
  }

  /// 清空日志并重置筛选状态。
  void clearLogs() {
    FocusManager.instance.primaryFocus?.unfocus();
    _logService.clear();
    _selectedLevel = DeveloperLogLevel.all;
    _selectedIds.clear();
    notifyListeners();
  }
}
