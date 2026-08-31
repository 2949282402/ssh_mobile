import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/utils/device_name_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('formats Android brand and avoids duplicate model prefixes', () async {
    final samsung = await getDeviceName(
      targetPlatform: TargetPlatform.android,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        androidDeviceInfo: _androidInfo(brand: 'samsung', model: 'Galaxy S24'),
      ),
    );
    final branded = await getDeviceName(
      targetPlatform: TargetPlatform.android,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        androidDeviceInfo: _androidInfo(brand: 'samsung', model: 'Samsung A55'),
      ),
    );

    expect(samsung, 'Samsung Galaxy S24');
    expect(branded, 'Samsung A55');
  });

  test('uses iOS name and machine fallback', () async {
    final named = await getDeviceName(
      targetPlatform: TargetPlatform.iOS,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        iosDeviceInfo: _iosInfo(name: 'Julian iPhone', machine: 'iPhone17,1'),
      ),
    );
    final unnamed = await getDeviceName(
      targetPlatform: TargetPlatform.iOS,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        iosDeviceInfo: _iosInfo(name: '', machine: 'iPhone17,1'),
      ),
    );

    expect(named, 'Julian iPhone');
    expect(unnamed, 'iPhone17,1');
  });

  test('uses macOS computer name and model fallback', () async {
    final named = await getDeviceName(
      targetPlatform: TargetPlatform.macOS,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        macOsDeviceInfo: _macInfo(
          computerName: 'Julian Mac',
          model: 'MacBookPro',
        ),
      ),
    );
    final unnamed = await getDeviceName(
      targetPlatform: TargetPlatform.macOS,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        macOsDeviceInfo: _macInfo(computerName: '', model: 'MacBookPro'),
      ),
    );

    expect(named, 'Julian Mac');
    expect(unnamed, 'MacBookPro');
  });

  test('uses Windows computer name and stable fallback', () async {
    final named = await getDeviceName(
      targetPlatform: TargetPlatform.windows,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        windowsDeviceInfo: _windowsInfo(computerName: 'DESKTOP-JULIAN'),
      ),
    );
    final unnamed = await getDeviceName(
      targetPlatform: TargetPlatform.windows,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        windowsDeviceInfo: _windowsInfo(computerName: ''),
      ),
    );

    expect(named, 'DESKTOP-JULIAN');
    expect(unnamed, 'Windows');
  });

  test('uses Linux pretty name and stable fallback', () async {
    final named = await getDeviceName(
      targetPlatform: TargetPlatform.linux,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        linuxDeviceInfo: _linuxInfo(prettyName: 'Ubuntu 24.04'),
      ),
    );
    final unnamed = await getDeviceName(
      targetPlatform: TargetPlatform.linux,
      deviceInfoPlugin: DeviceInfoPlugin.setMockInitialValues(
        linuxDeviceInfo: _linuxInfo(prettyName: ''),
      ),
    );

    expect(named, 'Ubuntu 24.04');
    expect(unnamed, 'Linux');
  });

  test('falls back to the operating system when a plugin call fails', () async {
    final name = await getDeviceName(
      targetPlatform: TargetPlatform.android,
      deviceInfoPlugin: DeviceInfoPlugin(),
    );

    expect(name, Platform.operatingSystem);
  });

  test(
    'unknown target platform falls back without querying device info',
    () async {
      final name = await getDeviceName(targetPlatform: TargetPlatform.fuchsia);

      expect(name, Platform.operatingSystem);
    },
  );
}

AndroidDeviceInfo _androidInfo({required String brand, required String model}) {
  return AndroidDeviceInfo.fromMap(<String, dynamic>{
    'version': <String, dynamic>{
      'sdkInt': 35,
      'baseOS': 'base',
      'previewSdkInt': 0,
      'release': '15',
      'codename': 'REL',
      'incremental': '1',
      'securityPatch': '2026-01-01',
    },
    'board': 'board',
    'bootloader': 'bootloader',
    'brand': brand,
    'device': 'device',
    'display': 'display',
    'fingerprint': 'fingerprint',
    'hardware': 'hardware',
    'host': 'host',
    'id': 'id',
    'manufacturer': brand,
    'model': model,
    'product': 'product',
    'name': model,
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
    'physicalRamSize': 3,
    'availableRamSize': 2,
  });
}

IosDeviceInfo _iosInfo({required String name, required String machine}) {
  return IosDeviceInfo.fromMap(<String, dynamic>{
    'name': name,
    'systemName': 'iOS',
    'systemVersion': '18.0',
    'model': 'iPhone',
    'modelName': 'iPhone Pro',
    'localizedModel': 'iPhone',
    'identifierForVendor': 'fixture',
    'freeDiskSize': 1,
    'totalDiskSize': 2,
    'isPhysicalDevice': true,
    'physicalRamSize': 3,
    'availableRamSize': 2,
    'isiOSAppOnMac': false,
    'isiOSAppOnVision': false,
    'utsname': <String, dynamic>{
      'sysname': 'Darwin',
      'nodename': 'fixture',
      'release': '1',
      'version': '1',
      'machine': machine,
    },
  });
}

MacOsDeviceInfo _macInfo({
  required String computerName,
  required String model,
}) {
  return MacOsDeviceInfo.fromMap(<String, dynamic>{
    'computerName': computerName,
    'hostName': 'fixture.local',
    'arch': 'arm64',
    'model': model,
    'modelName': model,
    'kernelVersion': '1',
    'osRelease': '15',
    'majorVersion': 15,
    'minorVersion': 0,
    'patchVersion': 0,
    'activeCPUs': 8,
    'memorySize': 16,
    'cpuFrequency': 1,
    'systemGUID': 'fixture',
  });
}

WindowsDeviceInfo _windowsInfo({required String computerName}) {
  return WindowsDeviceInfo(
    computerName: computerName,
    numberOfCores: 8,
    systemMemoryInMegabytes: 16 * 1024,
    userName: 'fixture',
    majorVersion: 10,
    minorVersion: 0,
    buildNumber: 22631,
    platformId: 2,
    csdVersion: '',
    servicePackMajor: 0,
    servicePackMinor: 0,
    suitMask: 0,
    productType: 1,
    reserved: 0,
    buildLab: 'fixture',
    buildLabEx: 'fixture',
    digitalProductId: Uint8List(0),
    displayVersion: '24H2',
    editionId: 'Professional',
    installDate: DateTime.utc(2026),
    productId: 'fixture',
    productName: 'Windows',
    registeredOwner: 'fixture',
    releaseId: '24H2',
    deviceId: 'fixture',
  );
}

LinuxDeviceInfo _linuxInfo({required String prettyName}) {
  return LinuxDeviceInfo(
    name: 'Ubuntu',
    id: 'ubuntu',
    prettyName: prettyName,
    machineId: 'fixture',
  );
}
