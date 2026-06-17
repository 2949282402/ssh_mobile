import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';

class DeveloperLogViewModel extends ChangeNotifier {
  final AppLogService _logService;
  final AppSettings _appSettings;

  AppLogLevel _selectedLevel = AppLogLevel.all;
  final Set<int> _selectedIds = {};

  DeveloperLogViewModel({
    required AppLogService logService,
    required AppSettings appSettings,
  })  : _logService = logService,
        _appSettings = appSettings {
    _logService.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    _logService.removeListener(_onLogsChanged);
    super.dispose();
  }

  void _onLogsChanged() {
    _pruneStaleSelections(notify: false);
    notifyListeners();
  }

  // Getters
  AppLogLevel get selectedLevel => _selectedLevel;
  Set<int> get selectedIds => _selectedIds;
  bool get selectionMode => _selectedIds.isNotEmpty;
  AppLanguage get language => _appSettings.language;

  bool get hasEntries => _logService.entries.isNotEmpty;
  Map<AppLogLevel, int> get levelCounts => _logService.levelCounts;
  List<AppLogEntry> get filteredEntries =>
      _logService.entriesForLevel(_selectedLevel);

  List<AppLogEntry> get selectedEntries {
    if (_selectedIds.isEmpty) return const <AppLogEntry>[];
    return [
      for (final entry in _logService.entries)
        if (_selectedIds.contains(entry.id)) entry,
    ];
  }

  // Setters & Actions
  void setSelectedLevel(AppLogLevel level) {
    if (_selectedLevel == level) return;
    _selectedLevel = level;
    notifyListeners();
  }

  void toggleEntrySelection(AppLogEntry entry) {
    if (!_selectedIds.add(entry.id)) {
      _selectedIds.remove(entry.id);
    }
    notifyListeners();
  }

  void selectEntry(AppLogEntry entry) {
    _selectedIds.add(entry.id);
    notifyListeners();
  }

  void clearSelection() {
    _selectedIds.clear();
    notifyListeners();
  }

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

  Future<bool> copySelectedOrFilteredLogs() async {
    final entries = selectionMode ? selectedEntries : filteredEntries;
    if (entries.isEmpty) return false;
    await Clipboard.setData(
      ClipboardData(text: entries.reversed.map((e) => e.text).join('\n\n')),
    );
    return true;
  }

  Future<void> copySingleLog(String text) async {
    await Clipboard.setData(ClipboardData(text: text));
  }

  int deleteSelectedLogs() {
    final count = _selectedIds.length;
    _logService.deleteEntriesById(_selectedIds);
    _selectedIds.clear();
    notifyListeners();
    return count;
  }

  void clearLogs() {
    FocusManager.instance.primaryFocus?.unfocus();
    _logService.clear();
    _selectedLevel = AppLogLevel.all;
    _selectedIds.clear();
    notifyListeners();
  }
}
