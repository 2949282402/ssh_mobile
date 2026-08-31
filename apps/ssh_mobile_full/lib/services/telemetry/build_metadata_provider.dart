// 真实构建元数据提供者。
//
// 取代工厂里的硬编码 `'1.0.0'/'100'/'prod'`。为了在无网络（无法新增
// package_info_plus 依赖）的离线环境下工作，当前使用 `device_info_plus`
// 读取设备型号名称作为 platform 后缀，配合 pubspec 声明的版本常量；发布渠道
// 从 `--dart-define=TELEMETRY_RELEASE_CHANNEL=...` 读取并在无效时回退。
// 接入 package_info_plus 后可无缝替换 [BaseBuildMetadataProvider]。

import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:device_info_plus/device_info_plus.dart';

/// 客户端构建元数据。
class AppBuildMetadata {
  const AppBuildMetadata({
    required this.appVersion,
    required this.buildNumber,
    required this.platform,
    required this.releaseChannel,
    required this.deviceModel,
  });

  final String appVersion;
  final String buildNumber;
  final String platform;
  final String releaseChannel;
  final String deviceModel;
}

/// 构建元数据提供者契约。
abstract interface class BuildMetadataProvider {
  /// 读取当前 App 的构建元数据；失败时应抛出或返回合理回退值。
  Future<AppBuildMetadata> load();
}

/// 离线环境下可用的实现。
///
/// 版本/构建号来自 pubspec 常量（与 `apps/ssh_mobile_full/pubspec.yaml` 的
/// `version:` 保持同步）；平台与设备型号来自 [DeviceInfoPlugin]。测试可以
/// 注入自定义 [DeviceInfoPlugin] 替身。
class DeviceInfoBuildMetadataProvider implements BuildMetadataProvider {
  DeviceInfoBuildMetadataProvider({
    this.appVersion = defaultAppVersion,
    this.buildNumber = defaultBuildNumber,
    String? releaseChannel,
    String? platform,
    DeviceInfoPlugin? deviceInfo,
    this.logger,
  }) : releaseChannel = _normalizeReleaseChannel(
         releaseChannel ?? defaultReleaseChannel,
       ),
       platform = platform ?? Platform.operatingSystem,
       deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  /// 与 `apps/ssh_mobile_full/pubspec.yaml` 的 `version:` 同步。
  static const String defaultAppVersion = '1.0.0';

  /// 与 `version: 1.0.0+1` 的 build 字段同步。
  static const String defaultBuildNumber = '1';

  /// 数据库列宽对齐的非回退渠道（MySQL `release_channel VARCHAR(32)`）。
  static const String fallbackReleaseChannel = 'prod';

  /// 编译时发布渠道；未通过
  /// `--dart-define=TELEMETRY_RELEASE_CHANNEL=...` 指定时使用 [fallbackReleaseChannel]。
  static const String defaultReleaseChannel = String.fromEnvironment(
    'TELEMETRY_RELEASE_CHANNEL',
    defaultValue: fallbackReleaseChannel,
  );

  static const int _maxReleaseChannelLength = 32;

  static String _normalizeReleaseChannel(String value) {
    if (value.isEmpty || value.length > _maxReleaseChannelLength) {
      return fallbackReleaseChannel;
    }
    return value;
  }

  final String appVersion;
  final String buildNumber;
  final String releaseChannel;
  final String platform;
  final DeviceInfoPlugin deviceInfo;
  final AppLogger? logger;

  @override
  Future<AppBuildMetadata> load() async {
    final model = await _loadDeviceModel();
    return AppBuildMetadata(
      appVersion: appVersion,
      buildNumber: buildNumber,
      platform: platform,
      releaseChannel: releaseChannel,
      deviceModel: model,
    );
  }

  Future<String> _loadDeviceModel() async {
    try {
      if (platform == 'android') {
        final info = await deviceInfo.androidInfo;
        return '${info.brand} ${info.model}'.trim();
      } else if (platform == 'ios') {
        final info = await deviceInfo.iosInfo;
        return info.name.isNotEmpty ? info.name : info.model;
      } else if (platform == 'macos') {
        final info = await deviceInfo.macOsInfo;
        return info.model.isNotEmpty ? info.model : info.computerName;
      } else if (platform == 'windows') {
        final info = await deviceInfo.windowsInfo;
        return info.computerName.isNotEmpty ? info.computerName : 'Windows';
      } else if (platform == 'linux') {
        final info = await deviceInfo.linuxInfo;
        return info.prettyName.isNotEmpty ? info.prettyName : 'Linux';
      }
    } catch (_) {
      // Device metadata is optional. Keep the failure out of telemetry and
      // logs; the injected AppLogger receives only a safe diagnostic label.
      try {
        logger?.log(
          LogRecord(
            timestamp: DateTime.now().toUtc(),
            level: LogLevel.warning,
            message: 'Device model unavailable; using platform fallback.',
            source: 'build_metadata',
          ),
        );
      } catch (_) {
        // Logging must not make the metadata fallback fail.
      }
    }
    return platform;
  }
}
