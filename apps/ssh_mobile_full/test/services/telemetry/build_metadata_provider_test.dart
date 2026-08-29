import 'dart:typed_data';

import 'package:app_core/app_core.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/telemetry/build_metadata_provider.dart';

final class _RecordingLogger implements AppLogger {
  final List<LogRecord> records = <LogRecord>[];

  @override
  void log(LogRecord record) {
    records.add(record);
  }

  @override
  AppLogger scope(String name) => this;
}

final class _ThrowingDeviceInfoPlugin extends DeviceInfoPlugin {
  @override
  Future<LinuxDeviceInfo> get linuxInfo {
    return Future<LinuxDeviceInfo>.error(
      StateError('device-info-error-marker'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('loads version metadata and each supported platform model', () async {
    final deviceInfo = _deviceInfo(
      androidModel: 'Android phone',
      iosName: 'Test iPhone',
      iosModel: 'iPhone',
      macModel: 'MacBookPro',
      macComputerName: 'Test Mac',
      windowsComputerName: 'Test-PC',
      linuxPrettyName: 'Debian GNU/Linux',
    );

    final expectedModels = <String, String>{
      'android': 'Acme Android phone',
      'ios': 'Test iPhone',
      'macos': 'MacBookPro',
      'windows': 'Test-PC',
      'linux': 'Debian GNU/Linux',
    };
    for (final entry in expectedModels.entries) {
      final metadata = await DeviceInfoBuildMetadataProvider(
        appVersion: '2.3.4',
        buildNumber: '42',
        releaseChannel: 'beta',
        platform: entry.key,
        deviceInfo: deviceInfo,
      ).load();

      expect(metadata.appVersion, '2.3.4');
      expect(metadata.buildNumber, '42');
      expect(metadata.releaseChannel, 'beta');
      expect(metadata.platform, entry.key);
      expect(metadata.deviceModel, entry.value);
    }
  });

  test(
    'uses safe platform fallbacks when optional model values are empty',
    () async {
      final deviceInfo = _deviceInfo(
        androidModel: '',
        iosName: '',
        iosModel: 'iPhone fallback',
        macModel: '',
        macComputerName: 'Mac fallback',
        windowsComputerName: '',
        linuxPrettyName: '',
      );

      expect(
        (await DeviceInfoBuildMetadataProvider(
          platform: 'android',
          deviceInfo: deviceInfo,
        ).load()).deviceModel,
        'Acme',
      );
      expect(
        (await DeviceInfoBuildMetadataProvider(
          platform: 'ios',
          deviceInfo: deviceInfo,
        ).load()).deviceModel,
        'iPhone fallback',
      );
      expect(
        (await DeviceInfoBuildMetadataProvider(
          platform: 'macos',
          deviceInfo: deviceInfo,
        ).load()).deviceModel,
        'Mac fallback',
      );
      expect(
        (await DeviceInfoBuildMetadataProvider(
          platform: 'windows',
          deviceInfo: deviceInfo,
        ).load()).deviceModel,
        'Windows',
      );
      expect(
        (await DeviceInfoBuildMetadataProvider(
          platform: 'linux',
          deviceInfo: deviceInfo,
        ).load()).deviceModel,
        'Linux',
      );
    },
  );

  test('falls back without exposing device errors to the logger', () async {
    final logger = _RecordingLogger();
    final metadata = await DeviceInfoBuildMetadataProvider(
      platform: 'linux',
      deviceInfo: _ThrowingDeviceInfoPlugin(),
      logger: logger,
    ).load();

    expect(metadata.deviceModel, 'linux');
    expect(logger.records, hasLength(1));
    final record = logger.records.single;
    expect(record.level, LogLevel.warning);
    expect(record.source, 'build_metadata');
    expect(
      record.message,
      'Device model unavailable; using platform fallback.',
    );
    expect(record.details, isNull);
    expect(record.error, isNull);
    expect(record.stackTrace, isNull);
    expect(record.message, isNot(contains('device-info-error-marker')));
  });
}

DeviceInfoPlugin _deviceInfo({
  required String androidModel,
  required String iosName,
  required String iosModel,
  required String macModel,
  required String macComputerName,
  required String windowsComputerName,
  required String linuxPrettyName,
}) {
  final android = AndroidDeviceInfo.fromMap({
    'version': {
      'baseOS': null,
      'sdkInt': 35,
      'release': '15',
      'codename': 'REL',
      'incremental': '1',
      'previewSdkInt': 0,
      'securityPatch': null,
    },
    'board': 'board',
    'bootloader': 'bootloader',
    'brand': 'Acme',
    'device': 'device',
    'display': 'display',
    'fingerprint': 'fingerprint',
    'hardware': 'hardware',
    'host': 'host',
    'id': 'id',
    'manufacturer': 'Acme',
    'model': androidModel,
    'product': 'product',
    'name': 'name',
    'supported32BitAbis': <String>[],
    'supported64BitAbis': <String>[],
    'supportedAbis': <String>[],
    'tags': 'tags',
    'type': 'user',
    'isPhysicalDevice': true,
    'freeDiskSize': 1,
    'totalDiskSize': 2,
    'systemFeatures': <String>[],
    'isLowRamDevice': false,
    'physicalRamSize': 1,
    'availableRamSize': 1,
  });
  final ios = IosDeviceInfo.fromMap({
    'name': iosName,
    'systemName': 'iOS',
    'systemVersion': '18',
    'model': iosModel,
    'modelName': iosModel,
    'localizedModel': iosModel,
    'identifierForVendor': null,
    'freeDiskSize': 1,
    'totalDiskSize': 2,
    'isPhysicalDevice': true,
    'physicalRamSize': 1,
    'availableRamSize': 1,
    'isiOSAppOnMac': false,
    'isiOSAppOnVision': false,
    'utsname': {
      'sysname': 'Darwin',
      'nodename': 'device',
      'release': '1',
      'version': '1',
      'machine': 'iPhone',
    },
  });
  final mac = MacOsDeviceInfo.fromMap({
    'computerName': macComputerName,
    'hostName': 'host',
    'arch': 'arm64',
    'model': macModel,
    'modelName': macModel,
    'kernelVersion': '1',
    'osRelease': '1',
    'majorVersion': 1,
    'minorVersion': 0,
    'patchVersion': 0,
    'activeCPUs': 1,
    'memorySize': 1,
    'cpuFrequency': 1,
    'systemGUID': null,
  });
  final windows = WindowsDeviceInfo(
    computerName: windowsComputerName,
    numberOfCores: 1,
    systemMemoryInMegabytes: 1,
    userName: 'user',
    majorVersion: 1,
    minorVersion: 0,
    buildNumber: 1,
    platformId: 1,
    csdVersion: '',
    servicePackMajor: 0,
    servicePackMinor: 0,
    suitMask: 0,
    productType: 1,
    reserved: 0,
    buildLab: '',
    buildLabEx: '',
    digitalProductId: Uint8List(0),
    displayVersion: '1',
    editionId: '1',
    installDate: DateTime.utc(2026),
    productId: '1',
    productName: 'Windows',
    registeredOwner: 'owner',
    releaseId: '1',
    deviceId: 'device',
  );
  final linux = LinuxDeviceInfo(
    name: 'Linux',
    id: 'linux',
    prettyName: linuxPrettyName,
    machineId: 'machine',
  );
  return DeviceInfoPlugin.setMockInitialValues(
    androidDeviceInfo: android,
    iosDeviceInfo: ios,
    macOsDeviceInfo: mac,
    windowsDeviceInfo: windows,
    linuxDeviceInfo: linux,
  );
}
