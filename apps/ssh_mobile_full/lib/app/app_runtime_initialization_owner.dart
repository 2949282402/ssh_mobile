import 'dart:async';

/// Cancellation signal shared with App Scope startup initializers.
final class AppRuntimeInitializationCancellation {
  final Completer<void> _cancelled = Completer<void>();

  /// Whether construction rollback has requested cancellation.
  bool get isCancelled => _cancelled.isCompleted;

  /// Completes when construction rollback requests cancellation.
  Future<void> get whenCancelled => _cancelled.future;

  void _cancel() {
    if (!_cancelled.isCompleted) _cancelled.complete();
  }
}

/// Error reporter used while the App-owned logger is still alive.
typedef AppRuntimeInitializationErrorReporter =
    void Function(String description, Object error, StackTrace stackTrace);

/// Owns non-blocking AppRuntime initialization tasks until shutdown.
///
/// Tasks are registered lazily and start only after AppRuntime ownership has
/// transferred successfully. Construction rollback can still cancel a started
/// owner, invokes every task cancellation in reverse order, and waits only for
/// a bounded interval. Late task errors are never reported after cancellation,
/// so they cannot call a released logger.
final class AppRuntimeInitializationOwner {
  AppRuntimeInitializationOwner({
    required this.onError,
    this.cancellationTimeout = const Duration(seconds: 3),
  });

  final AppRuntimeInitializationErrorReporter onError;
  final Duration cancellationTimeout;
  final AppRuntimeInitializationCancellation cancellation =
      AppRuntimeInitializationCancellation();
  final List<_AppRuntimeInitializer> _initializers = <_AppRuntimeInitializer>[];
  final List<Future<void>> _operations = <Future<void>>[];
  bool _started = false;
  bool _diagnosticsOpen = true;
  Future<bool>? _cancelFuture;

  /// Registers an initializer without starting it.
  void add({
    required String description,
    required FutureOr<void> Function(
      AppRuntimeInitializationCancellation cancellation,
    )
    start,
    FutureOr<void> Function()? cancel,
  }) {
    if (_started || cancellation.isCancelled) {
      throw StateError('Runtime initializers can no longer be registered.');
    }
    _initializers.add(
      _AppRuntimeInitializer(
        description: description,
        start: start,
        cancel: cancel,
      ),
    );
  }

  /// Starts every registered initializer exactly once.
  void start() {
    if (_started || cancellation.isCancelled) return;
    _started = true;
    for (final initializer in _initializers) {
      final operation = Future<void>.sync(() => initializer.start(cancellation))
          .then<void>(
            (_) {},
            onError: (Object error, StackTrace stackTrace) {
              if (!cancellation.isCancelled) {
                _report(initializer.description, error, stackTrace);
              }
            },
          );
      _operations.add(operation);
      unawaited(operation);
    }
  }

  /// Waits for all tasks during normal AppRuntime shutdown.
  Future<void> wait() async {
    if (_operations.isEmpty) return;
    await Future.wait<void>(_operations);
  }

  /// Cancels tasks and returns whether all of them settled before the bound.
  Future<bool> cancelAndWait() => _cancelFuture ??= _cancelAndWait();

  Future<bool> _cancelAndWait() async {
    cancellation._cancel();
    if (!_started) {
      _diagnosticsOpen = false;
      return true;
    }
    var completed = false;
    final settling = _cancelInitializers().then((_) async {
      await Future.wait<void>(_operations);
      completed = true;
    });
    await Future.any<void>(<Future<void>>[
      settling,
      Future<void>.delayed(cancellationTimeout),
    ]);
    _diagnosticsOpen = false;
    return completed;
  }

  Future<void> _cancelInitializers() async {
    for (final initializer in _initializers.reversed) {
      final cancel = initializer.cancel;
      if (cancel == null) continue;
      try {
        await cancel();
      } catch (error, stackTrace) {
        _report('Runtime initializer cancellation failed', error, stackTrace);
      }
    }
  }

  void _report(String description, Object error, StackTrace stackTrace) {
    if (!_diagnosticsOpen) return;
    try {
      onError(description, error, stackTrace);
    } catch (_) {
      // Diagnostics must not alter construction or shutdown ownership.
    }
  }
}

final class _AppRuntimeInitializer {
  const _AppRuntimeInitializer({
    required this.description,
    required this.start,
    required this.cancel,
  });

  final String description;
  final FutureOr<void> Function(
    AppRuntimeInitializationCancellation cancellation,
  )
  start;
  final FutureOr<void> Function()? cancel;
}
