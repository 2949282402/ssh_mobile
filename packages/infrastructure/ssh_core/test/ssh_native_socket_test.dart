// SshNativeSocket 单元测试：验证 dartssh2 `SSHSocket` 契约在 native 字节流上的
// 字节往返、写 backpressure、关闭与销毁语义。

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart';

void main() {
  group('SshNativeSocket byte transport', () {
    test('forwards incoming native bytes to the socket stream', () async {
      final stream = _FakeSshNativeStream();
      final socket = SshNativeSocket(stream: stream);
      final received = <Uint8List>[];
      final subscription = socket.stream.listen(received.add);

      stream.push(Uint8List.fromList([1, 2, 3]));
      stream.push(Uint8List.fromList([4, 5]));

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(2));
      expect(received[0], orderedEquals([1, 2, 3]));
      expect(received[1], orderedEquals([4, 5]));

      await subscription.cancel();
      await socket.destroyAndDone();
    });

    test('socket.sink forwards bytes to the native stream send', () async {
      final stream = _FakeSshNativeStream();
      final socket = SshNativeSocket(stream: stream);

      socket.sink.add([10, 20, 30]);
      await socket.flush();

      expect(stream.sent, hasLength(1));
      expect(stream.sent[0], orderedEquals([10, 20, 30]));
      await socket.destroyAndDone();
    });

    test('flush waits for slow in-flight native sends', () async {
      final stream = _FakeSshNativeStream();
      final socket = SshNativeSocket(stream: stream);
      stream.sendDelay = const Duration(milliseconds: 20);

      socket.sink.add([1]);
      socket.sink.add([2, 2]);
      await socket.flush();

      expect(stream.sent, hasLength(2));
      expect(stream.sent[1], orderedEquals([2, 2]));
      await socket.destroyAndDone();
    });

    test('backpressure failure surfaces on the done future', () async {
      final stream = _FakeSshNativeStream()..failSends = true;
      final socket = SshNativeSocket(stream: stream);

      socket.sink.add([9]);

      await expectLater(socket.done, throwsStateError);
      await socket.destroyAndDone();
    });

    test('peer close completes done and closes the incoming stream', () async {
      final stream = _FakeSshNativeStream();
      final socket = SshNativeSocket(stream: stream);
      var streamDone = false;
      var incomingClosed = false;
      socket.done.then((_) => streamDone = true);
      socket.stream.listen((_) {}, onDone: () => incomingClosed = true);

      stream.closeFromPeer();

      await socket.done;
      expect(streamDone, isTrue);
      expect(incomingClosed, isTrue);
      await socket.destroyAndDone();
    });
  });

  group('SshNativeSocket close semantics', () {
    test(
      'close sends a graceful native stream close and completes done',
      () async {
        final stream = _FakeSshNativeStream();
        final socket = SshNativeSocket(stream: stream);

        await socket.close();

        expect(stream.closedGracefully, isTrue);
        expect(socket.done, completes);
        await socket.done;
      },
    );

    test(
      'destroy releases the native stream without a graceful close',
      () async {
        final stream = _FakeSshNativeStream();
        final socket = SshNativeSocket(stream: stream);

        socket.destroy();

        expect(stream.destroyed, isTrue);
        expect(stream.closedGracefully, isFalse);
        await socket.done;
      },
    );

    test('close is idempotent and safe after destroy', () async {
      final stream = _FakeSshNativeStream();
      final socket = SshNativeSocket(stream: stream);

      await socket.close();
      await socket.close();
      socket.destroy();
      await socket.done;
      expect(stream.destroyed || stream.closedGracefully, isTrue);
    });
  });
}

final class _FakeSshNativeStream implements SshNativeStream {
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();
  final List<Uint8List> sent = <Uint8List>[];
  Duration sendDelay = Duration.zero;
  bool failSends = false;
  bool closedGracefully = false;
  bool destroyed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  void push(Uint8List bytes) => _incoming.add(bytes);

  void closeFromPeer() {
    unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  @override
  Future<void> send(Uint8List data) async {
    if (sendDelay > Duration.zero) {
      await Future<void>.delayed(sendDelay);
    }
    if (failSends) throw StateError('native send failed');
    sent.add(Uint8List.fromList(data));
  }

  @override
  Future<void> close() async {
    closedGracefully = true;
    await _incoming.close();
    if (!_done.isCompleted) _done.complete();
  }

  @override
  void destroy() {
    destroyed = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }
}

extension _SshNativeSocketTestExt on SshNativeSocket {
  Future<void> destroyAndDone() async {
    destroy();
    try {
      await done;
    } catch (_) {
      // Expected when the transport failed.
    }
  }
}
