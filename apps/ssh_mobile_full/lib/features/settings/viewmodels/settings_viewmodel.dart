import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/ai_storage_adapter.dart';
import 'package:app_ui/app_ui.dart';

class SettingsViewModel extends ChangeNotifier {
  final AppSettings _appSettings;
  final AppAiStorageAdapter _aiStorage;

  SettingsViewModel({
    required AppSettings appSettings,
    required AppAiStorageAdapter aiStorage,
  }) : _appSettings = appSettings,
       _aiStorage = aiStorage {
    // 监听底层 AppSettings 的更新，联动通知监听 SettingsViewModel 的视图
    _appSettings.addListener(notifyListeners);
    _aiStorage.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _appSettings.removeListener(notifyListeners);
    _aiStorage.removeListener(notifyListeners);
    super.dispose();
  }

  // APP设置暴露
  AppLanguage get language => _appSettings.language;
  ThemeMode get themeMode => _appSettings.themeMode;
  bool get isEnglish => _appSettings.isEnglish;
  bool get isDarkMode => _appSettings.isDarkMode;
  bool get showServerNamesInNotifications =>
      _appSettings.showServerNamesInNotifications;

  // 秘钥缓存设置暴露
  bool get secretCacheEnabled => _aiStorage.isSecretCacheEnabled;
  Duration get secretCacheTtl => _aiStorage.secretCacheTtl;
  int get secretCacheTtlMinutes => _aiStorage.secretCacheTtlMinutes;
  List<int> get secretCacheTtlOptionsMinutes =>
      _aiStorage.secretCacheTtlOptionsMinutes;

  Future<void> changeLanguage(AppLanguage lang) async {
    if (lang != _appSettings.language) {
      await _appSettings.toggleLanguage();
    }
  }

  void changeThemeMode(ThemeMode mode) {
    _appSettings.setThemeMode(mode);
  }

  bool get oledDark => _appSettings.oledDark;
  AppColorPalette get colorPalette => _appSettings.colorPalette;
  bool get developerMode => _appSettings.developerMode;
  bool get developerPanelFloating => _appSettings.developerPanelFloating;

  Future<void> setOledDark(bool value) async {
    await _appSettings.setOledDark(value);
  }

  Future<void> setColorPalette(AppColorPalette palette) async {
    await _appSettings.setColorPalette(palette);
  }

  Future<void> setDeveloperMode(bool value) async {
    await _appSettings.setDeveloperMode(value);
  }

  Future<void> setDeveloperPanelFloating(bool value) async {
    await _appSettings.setDeveloperPanelFloating(value);
  }

  Future<void> configureSecretCache(bool enabled, int ttlMinutes) async {
    await _aiStorage.setSecretCacheEnabled(enabled);
    await _aiStorage.setSecretCacheTtl(Duration(minutes: ttlMinutes));
  }

  Future<void> clearSecretCache() async {
    _aiStorage.clearSecretCache();
  }

  Future<void> setShowServerNamesInNotifications(bool value) async {
    await _appSettings.setShowServerNamesInNotifications(value);
  }

  Future<String> exportBackup() async {
    return await _aiStorage.exportAppDataJson();
  }

  Future<void> importBackup(String json) async {
    await _aiStorage.importAppDataJson(json);
  }

  bool _isImporting = false;
  bool _isExporting = false;
  String? _lastOperationMessage;

  bool get isImporting => _isImporting;
  bool get isExporting => _isExporting;
  String? get lastOperationMessage => _lastOperationMessage;

  Future<bool> exportAppData(
    Future<String?> Function(String fileName, List<int> bytes) saveFileCallback,
  ) async {
    _isExporting = true;
    _lastOperationMessage = null;
    notifyListeners();
    try {
      final jsonText = await _aiStorage.exportAppDataJson();
      final now = DateTime.now();
      final fileName =
          'ssh_mobile_backup_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.json';
      final path = await saveFileCallback(fileName, utf8.encode(jsonText));
      if (path != null) {
        _lastOperationMessage = 'success';
        return true;
      }
      return false;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Export app data failed',
        error: e,
        stackTrace: stackTrace,
      );
      _lastOperationMessage = e.toString();
      rethrow;
    } finally {
      _isExporting = false;
      notifyListeners();
    }
  }

  Future<bool> importAppData(
    Future<List<int>?> Function() pickFileCallback,
  ) async {
    _isImporting = true;
    _lastOperationMessage = null;
    notifyListeners();
    try {
      final bytes = await pickFileCallback();
      if (bytes == null) {
        return false;
      }
      await _aiStorage.importAppDataJson(utf8.decode(bytes));
      _lastOperationMessage = 'success';
      return true;
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Import app data failed',
        error: e,
        stackTrace: stackTrace,
      );
      _lastOperationMessage = e.toString();
      rethrow;
    } finally {
      _isImporting = false;
      notifyListeners();
    }
  }
}
