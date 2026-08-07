import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('LogBuffer 只保留上限内的最新记录', () {
    final buffer = LogBuffer<String>(maxEntries: 2);

    buffer
      ..add('first')
      ..add('second')
      ..add('third');

    expect(buffer.oldestFirst, ['second', 'third']);
    expect(buffer.newestFirst, ['third', 'second']);
    expect(buffer.length, 2);
  });

  test('LogBuffer 可以按条件删除并清空', () {
    final buffer = LogBuffer<int>(maxEntries: 4);
    buffer.addAll([1, 2, 3]);

    buffer.removeWhere((entry) => entry.isEven);
    expect(buffer.oldestFirst, [1, 3]);

    buffer.clear();
    expect(buffer, isEmpty);
  });

  test('LogBuffer 拒绝无效容量，避免无界或不可用缓冲区', () {
    expect(
      () => LogBuffer<String>(maxEntries: 0),
      throwsA(isA<ArgumentError>()),
    );
  });
}
