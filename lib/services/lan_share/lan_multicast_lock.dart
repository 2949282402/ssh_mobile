import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps Android Wi-Fi multicast reception enabled while active discovery runs.
abstract interface class LanMulticastLock {
  Future<void> acquire();

  Future<void> release();
}

class PlatformLanMulticastLock implements LanMulticastLock {
  static const MethodChannel _channel = MethodChannel(
    'ssh_mobile/lan_discovery',
  );

  bool _held = false;

  @override
  Future<void> acquire() async {
    if (!Platform.isAndroid || _held) return;
    await _channel.invokeMethod<void>('acquireMulticastLock');
    _held = true;
  }

  @override
  Future<void> release() async {
    if (!Platform.isAndroid || !_held) return;
    try {
      await _channel.invokeMethod<void>('releaseMulticastLock');
    } finally {
      _held = false;
    }
  }
}
