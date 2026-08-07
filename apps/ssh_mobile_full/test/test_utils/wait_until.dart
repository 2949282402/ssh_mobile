import 'dart:async';

/// Periodically checks a [condition] until it evaluates to true or [timeout] is exceeded.
/// [interval] specifies how often to check the condition.
Future<void> waitUntil(
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 3),
  Duration interval = const Duration(milliseconds: 20),
  String description = 'condition',
}) async {
  final stopWatch = Stopwatch()..start();
  while (!condition()) {
    if (stopWatch.elapsed > timeout) {
      throw TimeoutException('Timed out waiting for $description');
    }
    await Future.delayed(interval);
  }
}
