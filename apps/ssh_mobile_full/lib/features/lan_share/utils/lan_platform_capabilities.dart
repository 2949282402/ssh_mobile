import 'package:flutter/foundation.dart';

/// Whether LAN Share may query and request mobile runtime permissions.
///
/// Desktop targets do not expose these permissions through permission_handler;
/// keep device identity/settings available there without invoking the plugin.
bool supportsLanShareRuntimePermissions({
  required TargetPlatform platform,
  required bool isWeb,
}) =>
    !isWeb &&
    (platform == TargetPlatform.android || platform == TargetPlatform.iOS);
