import 'dart:async';
import 'dart:io' show Platform, ProcessInfo;

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';

import '../../../services/native_memory_service.dart';

class DeveloperPanelViewModel extends ChangeNotifier {
  static final Stopwatch _globalUptime = Stopwatch()..start();

  final List<FrameTiming> _frameTimings = [];
  Timer? _memoryTimer;
  bool _active = false;

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

  /// OS-level memory category breakdown (Java/Native/Graphics/Code), or `null`
  /// when unavailable (non-Android or no platform channel).
  NativeMemorySnapshot? _nativeMemory;
  NativeMemorySnapshot? get nativeMemory => _nativeMemory;

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

  // ── Lifecycle ──

  void start() {
    if (_active) return;
    _active = true;

    SchedulerBinding.instance.addTimingsCallback(_onFrameTimings);
    _startMemoryPolling();

    // Force first memory read
    _readMemory();
  }

  void stop() {
    if (!_active) return;
    _active = false;

    SchedulerBinding.instance.removeTimingsCallback(_onFrameTimings);
    _memoryTimer?.cancel();
    _memoryTimer = null;
  }

  @override
  void dispose() {
    stop();
    super.dispose();
  }

  // ── Frame timing ──

  /// Threshold (ms) above which a frame is considered jank.
  static const double jankThresholdMs = 16.67;

  void _onFrameTimings(List<FrameTiming> timings) {
    _frameTimings.addAll(timings);

    // Keep a rolling window of ~2 seconds (120 frames at 60 fps)
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
        _fps = (_fps * 10).roundToDouble() / 10; // 1 decimal place
      }
    }
    notifyListeners();
  }

  // ── Memory ──

  void _startMemoryPolling() {
    _memoryTimer?.cancel();
    _memoryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _readMemory();
    });
  }

  Future<void> _readMemory() async {
    try {
      _memoryBytes = ProcessInfo.currentRss;
    } catch (_) {
      _memoryBytes = -1; // not available (web or unsupported platform)
    }
    try {
      _nativeMemory = await NativeMemoryService.instance.snapshot();
    } catch (_) {
      _nativeMemory = null;
    }
    notifyListeners();
  }
}
