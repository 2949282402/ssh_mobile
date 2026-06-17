import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import '../../../services/background_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/storage_service.dart';

class StartupViewModel extends ChangeNotifier {
  final StorageService _storageService;
  final AppSettings _appSettings;

  bool _checkingPowerStatus = false;
  bool _powerStatusChecked = false;
  bool _powerStatusCheckScheduled = false;
  bool _shouldShowPowerGuide = false;
  bool _isExempt = false;

  StartupViewModel({
    required StorageService storageService,
    required AppSettings appSettings,
  })  : _storageService = storageService,
        _appSettings = appSettings {
    _storageService.addListener(_onServiceChanged);
    _appSettings.addListener(_onServiceChanged);
  }

  @override
  void dispose() {
    _storageService.removeListener(_onServiceChanged);
    _appSettings.removeListener(_onServiceChanged);
    super.dispose();
  }

  void _onServiceChanged() {
    notifyListeners();
  }

  // Getters
  bool get storageInitialized => _storageService.initialized;
  bool get settingsInitialized => _appSettings.initialized;
  AppLanguage get language => _appSettings.language;

  bool get isAndroidTarget =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;
  bool get checkingPowerStatus => _checkingPowerStatus;
  bool get powerStatusChecked => _powerStatusChecked;
  bool get powerStatusCheckScheduled => _powerStatusCheckScheduled;
  bool get shouldShowPowerGuide => _shouldShowPowerGuide;
  bool get isExempt => _isExempt;

  Future<void> checkPowerGuideStatus() async {
    if (_powerStatusChecked || _checkingPowerStatus) return;
    if (!isAndroidTarget) {
      _powerStatusChecked = true;
      _shouldShowPowerGuide = false;
      notifyListeners();
      return;
    }

    _checkingPowerStatus = true;
    notifyListeners();

    bool exempt = false;
    try {
      exempt = await BackgroundServiceManager.isIgnoringBatteryOptimizations()
          .timeout(const Duration(seconds: 2));
    } catch (_) {
      exempt = false;
    }

    _isExempt = exempt;
    _checkingPowerStatus = false;
    _powerStatusChecked = true;
    _shouldShowPowerGuide = !exempt;
    notifyListeners();
  }

  Future<void> refreshBatteryExemptionStatus() async {
    try {
      final exempt =
          await BackgroundServiceManager.isIgnoringBatteryOptimizations()
              .timeout(const Duration(seconds: 2));
      _isExempt = exempt;
      notifyListeners();
    } catch (_) {
      _isExempt = false;
      notifyListeners();
    }
  }

  Future<void> requestBatteryExemption() async {
    await BackgroundServiceManager.requestBatteryOptimizationExemption()
        .timeout(const Duration(seconds: 2), onTimeout: () {});
    await refreshBatteryExemptionStatus();
  }

  void openAppSettings() {
    BackgroundServiceManager.openAppSettings();
  }

  void enterAppForThisLaunch() {
    _shouldShowPowerGuide = false;
    notifyListeners();
  }

  Future<void> markPowerGuideSeen() async {
    await _storageService.markPowerGuideSeen();
    enterAppForThisLaunch();
  }

  void schedulePowerGuideCheck(VoidCallback callback) {
    if (_powerStatusChecked ||
        _checkingPowerStatus ||
        _powerStatusCheckScheduled) {
      return;
    }
    _powerStatusCheckScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _powerStatusCheckScheduled = false;
      callback();
    });
  }
}
