import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';

/// Returns a human-readable device name for the current platform.
///
/// Examples: "vivo X100", "iPhone 15 Pro", "MacBook Pro", "DESKTOP-XYZ".
/// Falls back to [Platform.operatingSystem] if the info cannot be read.
Future<String> getDeviceName() async {
  try {
    final plugin = DeviceInfoPlugin();
    if (Platform.isAndroid) {
      final info = await plugin.androidInfo;
      // Combine brand + model, e.g. "vivo X100"
      final brand = _capitalize(info.brand);
      final model = info.model;
      // Avoid duplicating brand in model string (some OEMs include it)
      if (model.toLowerCase().startsWith(info.brand.toLowerCase())) {
        return model;
      }
      return '$brand $model';
    } else if (Platform.isIOS) {
      final info = await plugin.iosInfo;
      // e.g. "iPhone 15 Pro"
      return info.name.isNotEmpty ? info.name : info.utsname.machine;
    } else if (Platform.isMacOS) {
      final info = await plugin.macOsInfo;
      return info.computerName.isNotEmpty ? info.computerName : info.model;
    } else if (Platform.isWindows) {
      final info = await plugin.windowsInfo;
      return info.computerName.isNotEmpty ? info.computerName : 'Windows';
    } else if (Platform.isLinux) {
      final info = await plugin.linuxInfo;
      return info.prettyName.isNotEmpty ? info.prettyName : 'Linux';
    }
  } catch (e) {
    debugPrint('[DeviceNameUtil] Failed to get device name: $e');
  }
  return Platform.operatingSystem;
}

String _capitalize(String s) =>
    s.isEmpty ? s : s[0].toUpperCase() + s.substring(1).toLowerCase();
