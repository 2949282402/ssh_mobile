import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/app/lan_share_feature_adapters.dart';

void main() {
  test(
    'LAN network access adapter borrows one App-owned facade for every generation',
    () async {
      final facade = _RecordingFacade();
      final adapter = AppLanShareNetworkAccessAdapter(facade);

      final first = await adapter.borrowFacade();
      final second = await adapter.borrowFacade();

      expect(first, same(facade));
      expect(second, same(facade));
      expect(facade.startCalls, 0);
      expect(facade.disposeCalls, 0);
    },
  );
}

final class _RecordingFacade extends Fake implements NetworkFacade {
  int startCalls = 0;
  int disposeCalls = 0;

  @override
  Future<SdkResult<void>> start(SdkRuntimeConfig config) async {
    startCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<void> dispose() async {
    disposeCalls++;
  }
}
