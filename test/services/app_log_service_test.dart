import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/app_log_service.dart';

void main() {
  tearDown(() {
    AppLogService.instance.clear();
  });

  test('redacts credentials from message and details', () {
    final logs = AppLogService.instance;
    logs.clear();

    logs.error(
      'request failed password=super-secret Bearer abc.def.ghi',
      details: 'private_key=my-key token=my-token',
      error: 'boom',
    );

    final entry = logs.entries.first;
    expect(entry.message, isNot(contains('super-secret')));
    expect(entry.message, isNot(contains('abc.def.ghi')));
    expect(entry.details, isNot(contains('my-key')));
    expect(entry.details, isNot(contains('my-token')));
    expect(entry.message, contains('[REDACTED]'));
  });

  test('level counts update when entries are deleted', () {
    final logs = AppLogService.instance;
    logs.clear();
    logs.info('one');
    logs.warning('two');
    final warningId = logs.entries.first.id;

    expect(logs.levelCounts[AppLogLevel.all], 2);

    logs.deleteEntriesById({warningId});

    expect(logs.levelCounts[AppLogLevel.all], 1);
    expect(logs.entries.single.message, 'one');
  });
}
