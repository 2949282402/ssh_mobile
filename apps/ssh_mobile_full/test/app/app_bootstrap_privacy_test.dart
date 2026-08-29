import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/app/app_bootstrap.dart';
import 'package:ssh_mobile/app/app_runtime.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pre-runtime zone failures do not print error details or stacks',
    () async {
      final previousDebugPrint = debugPrint;
      final messages = <String>[];

      try {
        final safeMessage = Completer<void>();
        debugPrint = (String? message, {int? wrapWidth}) {
          if (message != null) {
            messages.add(message);
            if (message == 'Uncaught zone error before AppRuntime logging' &&
                !safeMessage.isCompleted) {
              safeMessage.complete();
            }
          }
        };
        unawaited(
          AppBootstrap.run(
            runtimeFactory: () => Future<AppRuntime>.error(
              StateError('bootstrap-error-marker'),
              StackTrace.fromString('bootstrap-stack-marker'),
            ),
            startApp: (_) {},
          ),
        );
        await safeMessage.future.timeout(const Duration(seconds: 1));
      } finally {
        debugPrint = previousDebugPrint;
      }

      expect(messages, hasLength(1));
      expect(messages.single, 'Uncaught zone error before AppRuntime logging');
      expect(messages.single, isNot(contains('bootstrap-error-marker')));
      expect(messages.single, isNot(contains('bootstrap-stack-marker')));
    },
  );
}
