import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  test('LAN runtime permissions are limited to native mobile targets', () {
    expect(
      supportsLanShareRuntimePermissions(
        platform: TargetPlatform.android,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      supportsLanShareRuntimePermissions(
        platform: TargetPlatform.iOS,
        isWeb: false,
      ),
      isTrue,
    );
    expect(
      supportsLanShareRuntimePermissions(
        platform: TargetPlatform.windows,
        isWeb: false,
      ),
      isFalse,
    );
    expect(
      supportsLanShareRuntimePermissions(
        platform: TargetPlatform.macOS,
        isWeb: false,
      ),
      isFalse,
    );
    expect(
      supportsLanShareRuntimePermissions(
        platform: TargetPlatform.android,
        isWeb: true,
      ),
      isFalse,
    );
  });
}
