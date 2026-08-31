part of '../ssh_service.dart';

/// Tracks asynchronous SSH work and terminal metadata writes for shutdown.
extension _SshServiceOperations on SshService {
  void _schedulePersistenceOperation(
    Future<void> Function() operation, {
    required String description,
  }) {
    if (_shutdownRequested) return;
    late final Future<void> tracked;
    tracked = operation()
        .catchError((Object error, StackTrace stackTrace) {
          AppLogService.instance.error(
            description,
            error: error,
            stackTrace: stackTrace,
          );
        })
        .whenComplete(() => _persistenceOperations.remove(tracked));
    _persistenceOperations.add(tracked);
    unawaited(tracked);
  }

  Future<T> _trackSshOperation<T>(Future<T> Function() operation) {
    if (_shutdownRequested) {
      return Future<T>.error(
        StateError('SshService is shutting down or already closed.'),
      );
    }
    final result = Future<T>.sync(operation);
    late final Future<void> barrier;
    barrier = result
        .then<void>((_) {}, onError: (_, _) {})
        .whenComplete(() => _ownedSshOperations.remove(barrier));
    _ownedSshOperations.add(barrier);
    return result;
  }
}
