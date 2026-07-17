import 'dart:io';

import 'package:flutter_displaymode/flutter_displaymode.dart';

import 'app_log_service.dart';

/// 屏幕显示刷新率（高刷新率/120Hz）配置服务。
class DisplayModeService {
  DisplayModeService._();

  /// 在支持的平台（Android）上请求开启最高可用刷新率（如 120Hz/90Hz）。
  ///
  /// - iOS 平台：由 `Info.plist` 中的 `CADisableMinimumFrameDurationOnPhone` 原生开启 ProMotion，
  ///   并在开启省电模式时由系统自动降级至 60Hz。
  /// - Android 平台：显式请求最高刷新率。当系统处于省电模式或发热限频时，
  ///   Android 系统会自动覆写并限制最高刷新率（如降至 60Hz），此方法具有充分的系统容错性。
  static Future<void> enableHighRefreshRate() async {
    if (!Platform.isAndroid) {
      return;
    }

    try {
      await FlutterDisplayMode.setHighRefreshRate();
      AppLogService.instance.info(
        'DisplayModeService: Requested high display refresh rate on Android successfully.',
      );
    } catch (e, stackTrace) {
      AppLogService.instance.warning(
        'DisplayModeService: Failed to set high display refresh rate: $e',
        details: stackTrace.toString(),
      );
    }
  }
}
