import 'package:flutter/foundation.dart';

/// 启动探针与资源计数工具类 (仅在 Debug/Profile 模式下记录)
class StartupInstrumentation {
  static final StartupInstrumentation instance = StartupInstrumentation._();

  StartupInstrumentation._();

  final Stopwatch _stopwatch = Stopwatch();
  final Map<String, int> _timings = {};
  final Map<String, int> _serviceConstructCounts = {};
  final Map<String, int> _serviceEnsureCounts = {};
  final Map<String, int> _resourceCounts = {};

  bool get enabled => kDebugMode || kProfileMode;

  void recordMainStart() {
    if (!enabled) return;
    _stopwatch.reset();
    _stopwatch.start();
    _timings['main_start'] = 0;
  }

  void recordRunAppStart() {
    if (!enabled) return;
    _timings['run_app_start'] = _stopwatch.elapsedMilliseconds;
  }

  void recordCoreReady() {
    if (!enabled) return;
    _timings['core_ready'] = _stopwatch.elapsedMilliseconds;
  }

  void recordHomeReady() {
    if (!enabled) return;
    _timings['home_ready'] = _stopwatch.elapsedMilliseconds;
  }

  void recordServiceConstructed(String name) {
    if (!enabled) return;
    _serviceConstructCounts[name] = (_serviceConstructCounts[name] ?? 0) + 1;
  }

  void recordServiceInitialized(String name) {
    if (!enabled) return;
    _serviceEnsureCounts[name] = (_serviceEnsureCounts[name] ?? 0) + 1;
  }

  void incrementResource(String category) {
    if (!enabled) return;
    _resourceCounts[category] = (_resourceCounts[category] ?? 0) + 1;
  }

  void decrementResource(String category) {
    if (!enabled) return;
    final current = _resourceCounts[category] ?? 0;
    if (current > 0) {
      _resourceCounts[category] = current - 1;
    }
  }

  int getTiming(String key) => _timings[key] ?? -1;
  int getConstructCount(String name) => _serviceConstructCounts[name] ?? 0;
  int getEnsureCount(String name) => _serviceEnsureCounts[name] ?? 0;
  int getResourceCount(String category) => _resourceCounts[category] ?? 0;

  Map<String, dynamic> snapshot() {
    return {
      'timings_ms': Map<String, int>.from(_timings),
      'service_constructs': Map<String, int>.from(_serviceConstructCounts),
      'service_ensures': Map<String, int>.from(_serviceEnsureCounts),
      'resources': Map<String, int>.from(_resourceCounts),
    };
  }

  void reset() {
    _stopwatch.stop();
    _stopwatch.reset();
    _timings.clear();
    _serviceConstructCounts.clear();
    _serviceEnsureCounts.clear();
    _resourceCounts.clear();
  }
}
