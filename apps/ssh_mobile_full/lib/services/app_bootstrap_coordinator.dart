import 'dart:async';
import 'package:flutter/foundation.dart';
import '../utils/startup_instrumentation.dart';
import 'app_settings.dart';

enum BootstrapPhase { idle, initializing, ready, failed }

/// 应用启动协调器，负责应用启动的最简 Bootstrap 流程。
/// 仅等待 AppSettings 核心设置，Feature 数据库由各自 Module 按需初始化，
/// 避免非必要的网络、端口绑定、Secure Storage 和平台 IO 阻塞首屏渲染。
class AppBootstrapCoordinator extends ChangeNotifier {
  final AppSettings appSettings;

  BootstrapPhase _phase = BootstrapPhase.idle;
  Object? _error;
  Future<void>? _inFlightFuture;

  BootstrapPhase get phase => _phase;
  bool get isReady => _phase == BootstrapPhase.ready;
  Object? get error => _error;

  AppBootstrapCoordinator({required this.appSettings});

  Future<void> ensureBootstrap() {
    if (_phase == BootstrapPhase.ready) return Future.value();
    if (_inFlightFuture != null) return _inFlightFuture!;

    _phase = BootstrapPhase.initializing;
    _error = null;
    notifyListeners();

    _inFlightFuture = _doBootstrap();
    return _inFlightFuture!;
  }

  Future<void> _doBootstrap() async {
    try {
      StartupInstrumentation.instance.recordMainStart();
      await appSettings.ensureCoreLoaded();
      StartupInstrumentation.instance.recordCoreReady();
      _phase = BootstrapPhase.ready;
      notifyListeners();
    } catch (e) {
      _phase = BootstrapPhase.failed;
      _error = e;
      _inFlightFuture = null;
      notifyListeners();
      rethrow;
    }
  }
}
