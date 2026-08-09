import 'package:app_core/app_core.dart';
import 'package:flutter/foundation.dart';

import 'package:feature_developer/feature_developer.dart';

/// Developer Feature 测试使用的设置假对象。
final class FakeDeveloperSettings extends ChangeNotifier
    implements DeveloperSettingsPort {
  /// 创建测试设置。
  FakeDeveloperSettings({
    this.language = AppLanguage.zh,
    this.developerMode = true,
    this.floatingPanelEnabled = true,
  });

  @override
  AppLanguage language;

  @override
  bool developerMode;

  @override
  bool floatingPanelEnabled;
}

/// Developer Log 测试用的内存 Port，不涉及真实日志数据库。
final class FakeDeveloperLogPort extends ChangeNotifier
    implements DeveloperLogPort {
  final List<DeveloperLogEntry> _entries = [];

  /// 添加一条测试日志并通知页面。
  void add(DeveloperLogEntry entry) {
    _entries.insert(0, entry);
    notifyListeners();
  }

  @override
  List<DeveloperLogEntry> get entries => List.unmodifiable(_entries);

  @override
  Map<DeveloperLogLevel, int> get levelCounts => {
    for (final level in DeveloperLogLevel.values)
      level: level == DeveloperLogLevel.all
          ? _entries.length
          : _entries.where((entry) => entry.level == level).length,
  };

  @override
  List<DeveloperLogEntry> entriesForLevel(DeveloperLogLevel level) {
    if (level == DeveloperLogLevel.all) return entries;
    return List.unmodifiable(_entries.where((entry) => entry.level == level));
  }

  @override
  Set<int> get entryIds => _entries.map((entry) => entry.id).toSet();

  @override
  void deleteEntriesById(Set<int> ids) {
    _entries.removeWhere((entry) => ids.contains(entry.id));
    notifyListeners();
  }

  @override
  void clear() {
    _entries.clear();
    notifyListeners();
  }
}

/// Developer Panel 测试用的 diagnostics Port。
final class FakeDeveloperDiagnostics extends ChangeNotifier
    implements DeveloperDiagnosticsPort {
  /// 创建包含固定模块状态的 diagnostics 假对象。
  FakeDeveloperDiagnostics({List<DeveloperComponentStatus>? statuses})
    : _statuses =
          statuses ??
          [
            const DeveloperComponentStatus(
              id: DeveloperComponentId.ssh,
              state: '0 sessions',
            ),
            const DeveloperComponentStatus(
              id: DeveloperComponentId.rag,
              state: 'idle',
            ),
            const DeveloperComponentStatus(
              id: DeveloperComponentId.mcpServer,
              state: 'stopped',
            ),
            const DeveloperComponentStatus(
              id: DeveloperComponentId.performanceMonitor,
              state: 'idle',
            ),
            const DeveloperComponentStatus(
              id: DeveloperComponentId.logBuffer,
              state: '0 entries',
            ),
          ];

  final List<DeveloperComponentStatus> _statuses;

  @override
  List<DeveloperComponentStatus> get componentStatuses =>
      List.unmodifiable(_statuses);

  @override
  Future<DeveloperNativeMemorySnapshot?> readNativeMemory() async => null;
}
