import 'dart:async';

import 'disposable.dart';

/// 以栈式顺序集中释放一组异步或同步资源。
///
/// Bag 只持有释放回调，不接管资源的其他业务行为；释放时采用后进先出，
/// 适配“后创建的资源依赖先创建的资源”的常见初始化顺序。即使某个回调
/// 抛错，也会继续释放其余资源，最后再抛出第一个错误。
final class DisposableBag implements Disposable {
  final List<Future<void> Function()> _disposers = <Future<void> Function()>[];
  bool _isDisposed = false;

  /// 当前 Bag 是否已经释放。
  bool get isDisposed => _isDisposed;

  /// 当前仍等待释放的资源数量。
  int get length => _disposers.length;

  /// 注册一个 StreamSubscription，并在释放时等待其取消完成。
  void addSubscription<T>(StreamSubscription<T> subscription) {
    _add(subscription.cancel);
  }

  /// 注册一个 Timer，并在释放时取消它。
  void addTimer(Timer timer) {
    _add(timer.cancel);
  }

  /// 注册一个遵循统一生命周期合约的对象。
  void addDisposable(Disposable disposable) {
    _add(disposable.dispose);
  }

  /// 注册一个自定义释放回调，支持同步或异步实现。
  void addCallback(FutureOr<void> Function() callback) {
    _add(callback);
  }

  void _add(FutureOr<void> Function() disposer) {
    if (_isDisposed) {
      throw StateError('Cannot add a resource after DisposableBag.dispose');
    }
    _disposers.add(() async {
      await disposer();
    });
  }

  @override
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    Object? firstError;
    StackTrace? firstStackTrace;
    for (final disposer in _disposers.reversed) {
      try {
        await disposer();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    _disposers.clear();

    final error = firstError;
    if (error != null) {
      Error.throwWithStackTrace(error, firstStackTrace ?? StackTrace.current);
    }
  }
}
