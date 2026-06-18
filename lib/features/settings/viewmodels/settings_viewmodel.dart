import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';

import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/storage_service.dart';

class SettingsViewModel extends ChangeNotifier {
  final AppSettings _appSettings;
  final StorageService _storageService;

  SettingsViewModel({
    required AppSettings appSettings,
    required StorageService storageService,
  })  : _appSettings = appSettings,
        _storageService = storageService {
    // 监听底层 AppSettings 的更新，联动通知监听 SettingsViewModel 的视图
    _appSettings.addListener(notifyListeners);
    _storageService.addListener(notifyListeners);
  }

  @override
  void dispose() {
    _appSettings.removeListener(notifyListeners);
    _storageService.removeListener(notifyListeners);
    super.dispose();
  }

  // APP设置暴露
  AppLanguage get language => _appSettings.language;
  ThemeMode get themeMode => _appSettings.themeMode;
  String get fontFamilyId => _appSettings.fontFamilyId;
  int get sftpDownloadLimitBytes => _appSettings.sftpDownloadLimitBytes;
  int get sftpTextPreviewLimitBytes => _appSettings.sftpTextPreviewLimitBytes;
  int get sftpRichPreviewLimitBytes => _appSettings.sftpRichPreviewLimitBytes;
  int get sftpTextEditLimitBytes => _appSettings.sftpTextEditLimitBytes;
  bool get isEnglish => _appSettings.isEnglish;
  bool get isDarkMode => _appSettings.isDarkMode;
  bool get showServerNamesInNotifications =>
      _appSettings.showServerNamesInNotifications;
  AppFontChoice get fontChoice => _appSettings.fontChoice;

  // 秘钥缓存设置暴露
  bool get secretCacheEnabled => _storageService.isSecretCacheEnabled;
  Duration get secretCacheTtl => _storageService.secretCacheTtl;
  int get secretCacheTtlMinutes => _storageService.secretCacheTtlMinutes;
  List<int> get secretCacheTtlOptionsMinutes =>
      _storageService.secretCacheTtlOptionsMinutes;

  Future<void> changeLanguage(AppLanguage lang) async {
    if (lang != _appSettings.language) {
      await _appSettings.toggleLanguage();
    }
  }

  void changeThemeMode(ThemeMode mode) {
    _appSettings.setThemeMode(mode);
  }

  Future<void> changeFontFamily(String familyId) async {
    await _appSettings.setFontFamilyId(familyId);
  }

  Future<void> setSftpLimits({
    int? downloadLimit,
    int? textPreviewLimit,
    int? richPreviewLimit,
    int? textEditLimit,
  }) async {
    if (downloadLimit != null) {
      await _appSettings.setSftpDownloadLimitBytes(downloadLimit);
    }
    if (textPreviewLimit != null) {
      await _appSettings.setSftpTextPreviewLimitBytes(textPreviewLimit);
    }
    if (richPreviewLimit != null) {
      await _appSettings.setSftpRichPreviewLimitBytes(richPreviewLimit);
    }
    if (textEditLimit != null) {
      await _appSettings.setSftpTextEditLimitBytes(textEditLimit);
    }
  }

  Future<void> configureSecretCache(bool enabled, int ttlMinutes) async {
    await _storageService.setSecretCacheEnabled(enabled);
    await _storageService.setSecretCacheTtl(Duration(minutes: ttlMinutes));
  }

  Future<void> clearSecretCache() async {
    _storageService.clearSecretCache();
  }

  Future<void> setShowServerNamesInNotifications(bool value) async {
    await _appSettings.setShowServerNamesInNotifications(value);
  }

  Future<String> exportBackup() async {
    return await _storageService.exportAppDataJson();
  }

  Future<void> importBackup(String json) async {
    await _storageService.importAppDataJson(json);
  }

  bool _isImporting = false;
  bool _isExporting = false;
  String? _lastOperationMessage;

  bool get isImporting => _isImporting;
  bool get isExporting => _isExporting;
  String? get lastOperationMessage => _lastOperationMessage;

  Future<bool> exportAppData(
      Future<String?> Function(String fileName, List<int> bytes)
          saveFileCallback) async {
    _isExporting = true;
    _lastOperationMessage = null;
    notifyListeners();
    try {
      final jsonText = await _storageService.exportAppDataJson();
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
      Future<List<int>?> Function() pickFileCallback) async {
    _isImporting = true;
    _lastOperationMessage = null;
    notifyListeners();
    try {
      final bytes = await pickFileCallback();
      if (bytes == null) {
        return false;
      }
      await _storageService.importAppDataJson(utf8.decode(bytes));
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
