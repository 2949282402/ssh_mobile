import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/native_memory_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('ssh_mobile/native_memory');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('returns null when the platform has no memory snapshot', () async {
    messenger.setMockMethodCallHandler(channel, (_) async => null);

    expect(await NativeMemoryService.instance.snapshot(), isNull);
  });

  test(
    'maps numeric memory fields and defaults malformed values to zero',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getMemoryStats');
        return <String, Object?>{
          'available': false,
          'javaHeap': 1.5,
          'nativeHeap': 'bad',
          'graphics': 3,
        };
      });

      final snapshot = await NativeMemoryService.instance.snapshot();
      expect(snapshot, isNotNull);
      expect(snapshot!.available, isFalse);
      expect(snapshot.javaHeapBytes, 1);
      expect(snapshot.nativeHeapBytes, 0);
      expect(snapshot.graphicsBytes, 3);
      expect(snapshot.codeBytes, 0);
      expect(snapshot.totalPssBytes, 0);
      expect(snapshot.javaHeapMB, closeTo(1 / (1024 * 1024), 1e-12));
      expect(snapshot.nativeHeapMB, 0);
      expect(snapshot.graphicsMB, closeTo(3 / (1024 * 1024), 1e-12));
      expect(snapshot.codeMB, 0);
      expect(snapshot.totalPssMB, 0);
    },
  );

  test('swallows unavailable platform channels', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw MissingPluginException('missing'),
    );

    expect(await NativeMemoryService.instance.snapshot(), isNull);
  });
}
