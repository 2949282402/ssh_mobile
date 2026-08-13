import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';

void main() {
  test('session exposes lifecycle and native-owned media state only', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    final frames = <RealtimeVideoFrame>[];
    final frameSubscription = session.remoteVideo.listen(frames.add);
    addTearDown(() async {
      await frameSubscription.cancel();
      await client.dispose();
    });

    expect(session.state, RealtimeSessionState.idle);
    expect(session.audioState, RealtimeAudioState.unavailable);
    expect(await session.start(), isA<SdkSuccess<void>>());
    expect(session.state, RealtimeSessionState.starting);
    expect(backend.startCalls, 1);

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.negotiating,
      ),
    );
    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.connected,
      ),
    );
    backend.emit(
      RealtimeRemoteVideoFrameEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        bytes: Uint8List.fromList(<int>[1, 2, 3]),
        timestamp: DateTime.utc(2026, 8, 12),
      ),
    );
    backend.emit(
      const RealtimeAudioStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeAudioState.active,
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.connected);
    expect(session.audioState, RealtimeAudioState.active);
    expect(frames.single.bytes, orderedEquals(<int>[1, 2, 3]));

    expect(await session.stop(), isA<SdkSuccess<void>>());
    expect(session.state, RealtimeSessionState.connected);
    expect(backend.stopCalls, 1);

    backend.emit(
      const RealtimeSessionStateChangedEvent(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
        state: RealtimeSessionState.stopped,
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(session.state, RealtimeSessionState.stopped);
  });

  test(
    'client disposal stops an active native session before closing the backend',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );

      await session.start();
      await client.dispose();

      expect(session.state, RealtimeSessionState.stopped);
      expect(backend.stopCalls, 1);
    },
  );

  test(
    'session rejects duplicate IDs and calls after client disposal',
    () async {
      final client = RealtimeClientImpl(backend: _FakeRealtimeBackend());
      client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );

      expect(
        () => client.createSession(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-b',
        ),
        throwsStateError,
      );
      expect(
        () => client.createSession(realtimeId: 'not-an-id', peerId: 'peer-a'),
        throwsArgumentError,
      );

      await client.dispose();
      expect(
        () => client.createSession(
          realtimeId: 'ffeeddccbbaa99887766554433221100',
          peerId: 'peer-a',
        ),
        throwsA(isA<SdkClientDisposedException>()),
      );
    },
  );

  test('session applies a snapshot and records its revision', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    addTearDown(() => client.dispose());

    backend.emit(
      const RealtimeSnapshotBackendEvent(
        RealtimeSnapshot(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 7,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.connected);
    expect(session.revision, 7);
  });

  test(
    'client dispatches snapshot and revision to the matching session',
    () async {
      final backend = _FakeRealtimeBackend();
      final client = RealtimeClientImpl(backend: backend);
      final session = client.createSession(
        realtimeId: '00112233445566778899aabbccddeeff',
        peerId: 'peer-a',
      );
      addTearDown(() => client.dispose());

      backend.emit(
        const RealtimeSnapshotBackendEvent(
          RealtimeSnapshot(
            realtimeId: '00112233445566778899aabbccddeeff',
            peerId: 'peer-a',
            state: RealtimeSessionState.connected,
            revision: 5,
          ),
        ),
      );
      backend.emit(
        const RealtimeSessionStateChangedEvent(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'peer-a',
          state: RealtimeSessionState.connected,
          revision: 6,
        ),
      );
      await Future<void>.delayed(Duration.zero);

      expect(session.state, RealtimeSessionState.connected);
      expect(session.revision, 6);
    },
  );

  test('client ignores snapshots for a different session peer', () async {
    final backend = _FakeRealtimeBackend();
    final client = RealtimeClientImpl(backend: backend);
    final session = client.createSession(
      realtimeId: '00112233445566778899aabbccddeeff',
      peerId: 'peer-a',
    );
    addTearDown(() => client.dispose());

    backend.emit(
      const RealtimeSnapshotBackendEvent(
        RealtimeSnapshot(
          realtimeId: '00112233445566778899aabbccddeeff',
          peerId: 'other-peer',
          state: RealtimeSessionState.connected,
          revision: 9,
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    expect(session.state, RealtimeSessionState.idle);
    expect(session.revision, 0);
  });
}

final class _FakeRealtimeBackend implements RealtimeSessionBackend {
  final StreamController<RealtimeBackendEvent> _events =
      StreamController<RealtimeBackendEvent>.broadcast();
  int startCalls = 0;
  int stopCalls = 0;

  @override
  Stream<RealtimeBackendEvent> get events => _events.stream;

  @override
  Future<SdkResult<void>> start({
    required String realtimeId,
    required String peerId,
  }) async {
    startCalls++;
    return const SdkSuccess<void>(null);
  }

  @override
  Future<SdkResult<void>> stop({required String realtimeId}) async {
    stopCalls++;
    return const SdkSuccess<void>(null);
  }

  void emit(RealtimeBackendEvent event) => _events.add(event);

  @override
  Future<void> dispose() => _events.close();
}
