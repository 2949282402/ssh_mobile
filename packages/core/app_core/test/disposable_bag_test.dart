import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('按后进先出释放 subscription、timer、disposable 和 callback', () async {
    final events = <String>[];
    var subscriptionCanceled = false;
    final controller = StreamController<void>(
      onCancel: () {
        subscriptionCanceled = true;
      },
    );
    final timer = Timer(const Duration(hours: 1), () {});
    final bag = DisposableBag();

    bag.addSubscription(controller.stream.listen((_) {}));
    bag.addTimer(timer);
    bag.addDisposable(_RecordingDisposable(events, 'disposable'));
    bag.addCallback(() => events.add('callback'));

    await bag.dispose();

    expect(events, <String>['callback', 'disposable']);
    expect(subscriptionCanceled, isTrue);
    expect(timer.isActive, isFalse);
    expect(bag.isDisposed, isTrue);
    expect(bag.length, 0);
    await controller.close();
  });

  test('重复释放幂等且禁止继续加入资源', () async {
    var callbackCount = 0;
    final bag = DisposableBag()
      ..addCallback(() {
        callbackCount++;
      });

    await bag.dispose();
    await bag.dispose();

    expect(callbackCount, 1);
    expect(() => bag.addCallback(() {}), throwsStateError);
  });
}

final class _RecordingDisposable implements Disposable {
  _RecordingDisposable(this.events, this.name);

  final List<String> events;
  final String name;

  @override
  Future<void> dispose() async {
    events.add(name);
  }
}
