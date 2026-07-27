import 'package:flutter/services.dart';

/// OS-level memory breakdown for the current process.
///
/// On Android this is populated from `Debug.getMemoryInfo().getMemoryStat`
/// via the `ssh_mobile/native_memory` platform channel. Values are in bytes.
/// This is the finest-grained memory attribution available in a release build:
/// it splits the process working set into OS categories (Java heap, native
/// heap, graphics, code). It does NOT attribute memory to individual app
/// features (SSH, RAG, …) — that requires per-feature instrumentation.
class NativeMemorySnapshot {
  const NativeMemorySnapshot({
    required this.available,
    required this.javaHeapBytes,
    required this.nativeHeapBytes,
    required this.graphicsBytes,
    required this.codeBytes,
    required this.totalPssBytes,
  });

  /// Whether the detailed `getMemoryStat` API is supported (Android M+).
  final bool available;

  final int javaHeapBytes;
  final int nativeHeapBytes;
  final int graphicsBytes;
  final int codeBytes;
  final int totalPssBytes;

  double get javaHeapMB => javaHeapBytes / (1024 * 1024);
  double get nativeHeapMB => nativeHeapBytes / (1024 * 1024);
  double get graphicsMB => graphicsBytes / (1024 * 1024);
  double get codeMB => codeBytes / (1024 * 1024);
  double get totalPssMB => totalPssBytes / (1024 * 1024);
}

/// Reads the OS-level memory category breakdown for the current process.
///
/// Returns `null` when the platform channel is unavailable (non-Android, or
/// running in an environment without a registered handler, e.g. `flutter test`).
class NativeMemoryService {
  NativeMemoryService._();

  static const MethodChannel _channel = MethodChannel(
    'ssh_mobile/native_memory',
  );

  static final NativeMemoryService instance = NativeMemoryService._();

  Future<NativeMemorySnapshot?> snapshot() async {
    try {
      final result = await _channel.invokeMethod<Map<dynamic, dynamic>>(
        'getMemoryStats',
      );
      if (result == null) return null;
      return NativeMemorySnapshot(
        available: result['available'] == true,
        javaHeapBytes: _toInt(result['javaHeap']),
        nativeHeapBytes: _toInt(result['nativeHeap']),
        graphicsBytes: _toInt(result['graphics']),
        codeBytes: _toInt(result['code']),
        totalPssBytes: _toInt(result['totalPss']),
      );
    } on Object {
      return null;
    }
  }
}

int _toInt(Object? value) => value is num ? value.toInt() : 0;
