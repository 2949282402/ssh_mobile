part of 'ssh_native_stream_adapters.dart';

/// App Shell 的 [SshNativeStream] 实现。
final class _AppSshNativeStream implements SshNativeStream {
  _AppSshNativeStream({
    required this.connector,
    required this.peerId,
    required this.handle,
  });

  final AppSshNativeStreamConnector connector;
  final String peerId;
  final NativeStreamHandle handle;
  final StreamController<Uint8List> _incoming = StreamController<Uint8List>();
  final Completer<void> _done = Completer<void>();
  bool _closed = false;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Future<void> get done => _done.future;

  @override
  Future<void> send(Uint8List data) async {
    if (_closed) throw StateError('SSH native stream is closed.');
    if (!connector._sendData(handle, peerId, data)) {
      // 字节未被真正投递到 native 时，立即以错误终止流并向上抛出，
      // 让 dartssh2 的 socket.done 拿到失败而不是永久挂起。
      final error = StateError(
        'SSH native stream send was dropped: the gateway is closed '
        'or rejected the command.',
      );
      connector._failStream(handle, error);
      throw error;
    }
  }

  @override
  Future<void> close() async {
    if (_closed) return _done.future;
    _closed = true;
    connector._closeStream(handle, peerId);
    // 单订阅 StreamController 在无监听者时 await close() 会永久挂起，必须 unawaited。
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
    return _done.future;
  }

  @override
  void destroy() {
    if (_closed) return;
    _closed = true;
    connector._closeStream(handle, peerId);
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  void _onData(Uint8List data) {
    if (_closed) return;
    _incoming.add(data);
  }

  void _onClosed() {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }

  /// native 拒绝打开（CommandResult accepted=false）时以错误终止流，
  /// 让调用方立即拿到可操作失败而不是永久挂起。
  void _fail(Object error, [StackTrace? stackTrace]) {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) {
      _incoming.addError(error, stackTrace ?? StackTrace.current);
      unawaited(_incoming.close());
    }
    if (!_done.isCompleted) {
      _done.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  void _abort() {
    if (_closed) return;
    _closed = true;
    if (!_incoming.isClosed) unawaited(_incoming.close());
    if (!_done.isCompleted) _done.complete();
  }
}
