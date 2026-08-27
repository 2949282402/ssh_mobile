import 'dart:async';
import 'dart:io' show Platform, ProcessInfo;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../domain/developer_diagnostics_models.dart';
import '../domain/developer_ports.dart';

/// Developer Panel 路由的 ViewModel，收集帧率、内存和模块活动快照。
///
/// 帧计时、Timer 和 diagnostics 监听都由该路由持有；底层模块状态只通过
/// [DeveloperDiagnosticsPort] 读取，避免面板直接依赖任意 Feature 实现。
final class DeveloperPanelViewModel extends ChangeNotifier {
  static final Stopwatch _globalUptime = Stopwatch()..start();

  /// 创建开发者面板状态并注入只读 diagnostics contract。
  DeveloperPanelViewModel({required DeveloperDiagnosticsPort diagnostics})
    : _diagnostics = diagnostics {
    _diagnostics.addListener(_onDiagnosticsChanged);
  }

  final DeveloperDiagnosticsPort _diagnostics;
  final List<FrameTiming> _frameTimings = [];
  Timer? _memoryTimer;
  bool _active = false;
  bool _disposed = false;
  bool _memoryReadInFlight = false;
  bool _diagnosticsSubscribed = true;
  bool _frameTimingsRegistered = false;

  // ── Observable state ──

  double _fps = 0;
  double get fps => _fps;

  int _frameCount = 0;
  int get frameCount => _frameCount;

  int _jankCount = 0;
  int get jankCount => _jankCount;

  /// Rolling-average UI-thread (build) time per frame, in milliseconds.
  double _avgBuildMs = 0;
  double get avgBuildMs => _avgBuildMs;

  /// Rolling-average GPU-thread (raster) time per frame, in milliseconds.
  double _avgRasterMs = 0;
  double get avgRasterMs => _avgRasterMs;

  int _memoryBytes = 0;
  int get memoryBytes => _memoryBytes;

  double get memoryMB => _memoryBytes / (1024 * 1024);

  /// 操作系统级内存分类（Java/Native/Graphics/Code），不可用时为 null。
  DeveloperNativeMemorySnapshot? _nativeMemory;

  /// 当前操作系统级内存分类快照。
  DeveloperNativeMemorySnapshot? get nativeMemory => _nativeMemory;

  /// 当前被观察模块的短状态。
  List<DeveloperComponentStatus> get componentStatuses =>
      _diagnostics.componentStatuses;

  /// 当前模块、连接、数据库和已知资源的只读诊断快照。
  DeveloperDiagnosticsSnapshot get diagnosticsSnapshot => _diagnostics.snapshot;

  Duration get uptime => _globalUptime.elapsed;

  String get platformName {
    try {
      return '${Platform.operatingSystem} ${Platform.operatingSystemVersion}';
    } catch (_) {
      return 'Web / Unknown';
    }
  }

  String get dartVersion => Platform.version;

  String get buildMode {
    if (kDebugMode) return 'debug';
    if (kProfileMode) return 'profile';
    if (kReleaseMode) return 'release';
    return 'unknown';
  }

  String get flutterVersion {
    // Best-effort from Platform.version on native
    try {
      const version = String.fromEnvironment('FLUTTER_VERSION');
      if (version.isNotEmpty) return version;
    } catch (_) {}
    return '—';
  }

  // ── Telemetry actions ──

  Future<int> replayTelemetry() async {
    final count = await _diagnostics.replayTelemetry();
    notifyListeners();
    return count;
  }

  Future<void> flushTelemetry() async {
    await _diagnostics.flushTelemetry();
    notifyListeners();
  }

  Future<bool> refreshTelemetryPolicy() async {
    final result = await _diagnostics.refreshTelemetryPolicy();
    notifyListeners();
    return result;
  }

  // ── Lifecycle ──

  void start() {
    if (_active) return;
    _active = true;

    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _frameTimingsRegistered = true;
    _startMemoryPolling();

    // 首次启动立即读取，避免面板打开后两秒才出现内存值。
    _readMemory();
  }

  void stop() {
    if (!_active) return;
    _active = false;

    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _frameTimingsRegistered = false;
    _memoryTimer?.cancel();
    _memoryTimer = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _diagnostics.removeListener(_onDiagnosticsChanged);
    _diagnosticsSubscribed = false;
    stop();
    assert(() {
      if (_diagnosticsSubscribed ||
          _frameTimingsRegistered ||
          _memoryTimer != null) {
        throw StateError(
          'DeveloperPanelViewModel resources were not released.',
        );
      }
      return true;
    }());
    super.dispose();
  }

  void _onDiagnosticsChanged() {
    if (!_disposed) notifyListeners();
  }

  // ── Frame timing ──

  /// 超过该毫秒数的帧计为卡顿帧。
  static const double jankThresholdMs = 16.67;

  void _onFrameTimings(List<FrameTiming> timings) {
    _frameTimings.addAll(timings);

    // 保留约两秒的滚动窗口（60 FPS 下最多 120 帧）。
    const maxFrames = 120;
    if (_frameTimings.length > maxFrames) {
      _frameTimings.removeRange(0, _frameTimings.length - maxFrames);
    }

    _frameCount += timings.length;
    _jankCount += timings
        .where((t) => t.totalSpan.inMicroseconds / 1000 > jankThresholdMs)
        .length;

    if (_frameTimings.isNotEmpty) {
      final buildUs = _frameTimings
          .map((t) => t.buildDuration.inMicroseconds)
          .reduce((a, b) => a + b);
      final rasterUs = _frameTimings
          .map((t) => t.rasterDuration.inMicroseconds)
          .reduce((a, b) => a + b);
      _avgBuildMs = buildUs / _frameTimings.length / 1000;
      _avgRasterMs = rasterUs / _frameTimings.length / 1000;
    }

    _computeFps();
  }

  void _computeFps() {
    if (_frameTimings.length < 2) {
      _fps = 0;
    } else {
      final totalUs = _frameTimings
          .map((t) => t.totalSpan.inMicroseconds)
          .reduce((a, b) => a + b);
      if (totalUs > 0) {
        _fps = (_frameTimings.length - 1) / (totalUs * 1e-6);
        _fps = (_fps * 10).roundToDouble() / 10; // 保留一位小数。
      }
    }
    if (!_disposed) notifyListeners();
  }

  // ── Memory ──

  void _startMemoryPolling() {
    _memoryTimer?.cancel();
    _memoryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _readMemory();
    });
  }

  Future<void> _readMemory() async {
    if (_disposed || _memoryReadInFlight) return;
    _memoryReadInFlight = true;
    try {
      _memoryBytes = ProcessInfo.currentRss;
    } catch (_) {
      _memoryBytes = -1; // Web 或不支持的平台无法读取 RSS。
    }
    try {
      _nativeMemory = await _diagnostics.readNativeMemory();
    } catch (_) {
      _nativeMemory = null;
    } finally {
      _memoryReadInFlight = false;
    }
    if (!_disposed) notifyListeners();
  }
}
