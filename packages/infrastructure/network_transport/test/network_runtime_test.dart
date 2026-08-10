// NetworkRuntime 的并发初始化、失败重试和资源释放测试。
//
// 测试使用 Fake NativeNetworkAdapter，避免单元测试必须加载真实平台的 FFI
// 动态库，同时验证 Runtime 对 native handle 的 Owner 责任。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_transport/network_transport.dart';

void main() {
  test(
    'Capability initialization is lazy and concurrent calls share native init',
    () async {
      final creation = Completer<NativeNetworkHandle>();
      final adapter = _FakeNativeNetworkAdapter(() => creation.future);
      final runtime = NetworkRuntimeImpl(nativeAdapter: adapter);

      expect(adapter.createCalls, 0);
      final quicInitialization = runtime.ensureCapability(
        NetworkCapability.quic,
      );
      final relayInitialization = runtime.ensureCapability(
        NetworkCapability.webSocketRelay,
      );

      expect(adapter.createCalls, 1);
      expect(runtime.state, NetworkRuntimeState.starting);

      final handle = _FakeNativeNetworkHandle();
      creation.complete(handle);
      await Future.wait<void>(<Future<void>>[
        quicInitialization,
        relayInitialization,
      ]);

      expect(runtime.state, NetworkRuntimeState.ready);
      expect(runtime.diagnostics.nativeHandles, 1);
      expect(runtime.diagnostics.activeConnections, 0);
      expect(runtime.isCapabilityReady(NetworkCapability.quic), isTrue);
      expect(
        runtime.isCapabilityReady(NetworkCapability.webSocketRelay),
        isTrue,
      );
      await runtime.dispose();
      expect(handle.closeCalls, 1);
      expect(runtime.diagnostics.nativeHandles, 0);
      expect(runtime.diagnostics.state, NetworkRuntimeState.disposed);
    },
  );

  test(
    'Capability failure is retryable and successful initialization is idempotent',
    () async {
      final handle = _FakeNativeNetworkHandle();
      final adapter = _FakeNativeNetworkAdapter(
        () async => throw StateError('first native initialization failed'),
      );
      final runtime = NetworkRuntimeImpl(nativeAdapter: adapter);

      try {
        await runtime.ensureCapability(NetworkCapability.quic);
        fail('Expected the first Capability initialization to fail.');
      } on StateError {
        // 失败后的 in-flight 状态必须被清除，下一次调用才能重试。
      }
      expect(runtime.state, NetworkRuntimeState.idle);

      adapter.nextCreation = () async => handle;
      await runtime.ensureCapability(NetworkCapability.quic);
      await runtime.ensureCapability(NetworkCapability.quic);
      expect(adapter.createCalls, 2);
      expect(runtime.isCapabilityReady(NetworkCapability.quic), isTrue);
      expect(runtime.diagnostics.readyCapabilities, [NetworkCapability.quic]);

      await runtime.dispose();
      expect(handle.closeCalls, 1);
    },
  );

  test('Unsupported capabilities fail without creating native resources', () {
    final adapter = _FakeNativeNetworkAdapter(
      () async => _FakeNativeNetworkHandle(),
    );
    final runtime = NetworkRuntimeImpl(nativeAdapter: adapter);

    expect(
      () => runtime.ensureCapability(NetworkCapability.tcp),
      throwsUnsupportedError,
    );
    expect(adapter.createCalls, 0);
  });

  test('Command gateway shares the Runtime-owned native handle', () async {
    final handle = _FakeNativeNetworkHandle();
    final runtime = NetworkRuntimeImpl(
      nativeAdapter: _FakeNativeNetworkAdapter(() async => handle),
    );

    final gateway = await runtime.openCommandGateway();

    expect(
      gateway.sendCommand(Uint8List.fromList(<int>[1])),
      TransportOperationStatus.success,
    );
    await runtime.dispose();
    expect(
      gateway.sendCommand(Uint8List.fromList(<int>[1])),
      TransportOperationStatus.stopped,
    );
  });

  test(
    'Dispose waits for a pending native handle and rejects later use',
    () async {
      final creation = Completer<NativeNetworkHandle>();
      final adapter = _FakeNativeNetworkAdapter(() => creation.future);
      final runtime = NetworkRuntimeImpl(nativeAdapter: adapter);
      final initialization = runtime.ensureCapability(NetworkCapability.quic);
      final handle = _FakeNativeNetworkHandle();

      final disposeFuture = runtime.dispose();
      expect(runtime.state, NetworkRuntimeState.stopping);
      expect(identical(disposeFuture, runtime.dispose()), isTrue);

      creation.complete(handle);
      await initialization;
      await disposeFuture;

      expect(runtime.state, NetworkRuntimeState.disposed);
      expect(runtime.diagnostics.nativeHandles, 0);
      expect(runtime.isCapabilityReady(NetworkCapability.quic), isFalse);
      expect(handle.closeCalls, 1);
      expect(
        () => runtime.ensureCapability(NetworkCapability.quic),
        throwsStateError,
      );
    },
  );
}

/// 可控制 native 创建结果的测试 adapter。
final class _FakeNativeNetworkAdapter implements NativeNetworkAdapter {
  /// 创建一个返回 [initialCreation] 的 Fake。
  _FakeNativeNetworkAdapter(this._initialCreation);

  final Future<NativeNetworkHandle> Function() _initialCreation;
  Future<NativeNetworkHandle> Function()? nextCreation;
  int createCalls = 0;

  @override
  Future<NativeNetworkHandle> create() {
    createCalls += 1;
    final creation = nextCreation;
    if (creation != null) return creation();
    return _initialCreation();
  }
}

/// 记录 close 次数并提供空事件流的测试 handle。
final class _FakeNativeNetworkHandle implements NativeNetworkHandle {
  final StreamController<Uint8List> _events =
      StreamController<Uint8List>.broadcast();
  bool _closed = false;
  int closeCalls = 0;

  @override
  Stream<Uint8List> get rawEvents => _events.stream;

  @override
  TransportOperationStatus sendCommand(Uint8List command) => _closed
      ? TransportOperationStatus.stopped
      : command.isEmpty
      ? TransportOperationStatus.invalidArgument
      : TransportOperationStatus.success;

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    closeCalls += 1;
    await _events.close();
  }

  @override
  Future<void> dispose() => close();
}
