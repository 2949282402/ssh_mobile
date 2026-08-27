import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('TelemetryLogSink', () {
    late MemoryTelemetryStorage storage;
    late TelemetryClient client;
    late TelemetryLogSink sink;

    setUp(() {
      storage = MemoryTelemetryStorage();
      client = TelemetryClient(
        config: const TelemetryClientConfig(
          baseUrl: 'https://telemetry.test',
          deviceId: 'device-test',
          appVersion: '1.0.0',
          buildNumber: '1',
          platform: 'test',
          releaseChannel: 'test',
        ),
        storage: storage,
        initialPolicy: const TelemetryUploadPolicy(
          uploadEnabled: false,
          batchSizeThreshold: 50,
          timeIntervalSeconds: 60,
          maxBatchSize: 100,
          clientMaxLocalRecords: 1000,
          specialTriggers: [],
          policyVersion: 1,
        ),
      );
      sink = TelemetryLogSink(client: client);
    });

    tearDown(() async {
      await sink.close();
      await client.dispose();
    });

    test(
      'filters unstructured, low-severity, and non-allowlisted records',
      () async {
        sink.write(_record(level: LogLevel.info));
        sink.write(_record(level: LogLevel.warning));
        sink.write(_record(level: LogLevel.error));
        sink.write(
          _record(
            level: LogLevel.error,
            eventName: TelemetryEvents.sshSessionStarted.name,
          ),
        );

        await sink.pendingWrites;

        expect(await storage.fetchAllForReplay(), isEmpty);
      },
    );

    test('persists explicitly allowlisted structured error metadata', () async {
      sink.write(
        _record(
          eventName: TelemetryEvents.appErrorCaptured.name,
          errorCode: TelemetryErrorCodes.appUncaughtError.code,
          traceId: 'trace-preserved',
          attributes: const {
            'message': 'uncaught failure',
            'category': 'zone',
            'stage': 'bootstrap',
          },
        ),
      );

      await sink.pendingWrites;

      final records = await storage.fetchAllForReplay();
      expect(records, hasLength(1));
      final record = records.single;
      expect(record.eventName, TelemetryEvents.appErrorCaptured.name);
      expect(
        record.error?.errorCode,
        TelemetryErrorCodes.appUncaughtError.code,
      );
      expect(record.traceId, 'trace-preserved');
      expect(record.properties, {
        'message': 'uncaught failure',
        'category': 'zone',
        'stage': 'bootstrap',
      });
    });

    test(
      'forwards a custom critical diagnostic allowlist and copies details',
      () async {
        final critical = const TelemetryEventDefinition(
          name: 'test.critical',
          version: 1,
          recordType: TelemetryRecordType.diagnostic,
          feature: 'test',
          severity: TelemetrySeverity.critical,
          allowedProperties: {'message', 'details'},
          requiredProperties: {'message'},
          propertyTypes: {'message': 'string', 'details': 'string'},
        );
        final catalog = TelemetryCatalog(registerDefaults: false)
          ..registerEvent(critical);
        final criticalClient = TelemetryClient(
          config: client.config,
          storage: storage,
          catalog: catalog,
          initialPolicy: client.activePolicy,
        );
        final customSink = TelemetryLogSink(
          client: criticalClient,
          catalog: catalog,
          allowlistedEvents: {'test.critical'},
        );
        addTearDown(customSink.close);
        addTearDown(criticalClient.dispose);

        customSink.write(
          _record(eventName: 'test.critical', details: 'critical details'),
        );
        await customSink.pendingWrites;

        final records = await storage.fetchAllForReplay();
        expect(records, hasLength(1));
        expect(records.single.severity, TelemetrySeverity.critical);
        expect(records.single.properties, {
          'message': 'structured log message',
          'details': 'critical details',
        });
      },
    );

    test(
      'never forwards telemetry transport events even when explicitly listed',
      () async {
        final telemetryFailure = const TelemetryEventDefinition(
          name: 'telemetry.test.failed',
          version: 1,
          recordType: TelemetryRecordType.diagnostic,
          feature: 'telemetry',
          severity: TelemetrySeverity.error,
          allowedProperties: {'message'},
          requiredProperties: {'message'},
          propertyTypes: {'message': 'string'},
        );
        final catalog = TelemetryCatalog(registerDefaults: false)
          ..registerEvent(telemetryFailure);
        final customSink = TelemetryLogSink(
          client: client,
          catalog: catalog,
          allowlistedEvents: {'telemetry.test.failed'},
        );
        addTearDown(customSink.close);

        customSink.write(_record(eventName: 'telemetry.test.failed'));
        await customSink.pendingWrites;

        expect(await storage.fetchAllForReplay(), isEmpty);
      },
    );

    test(
      'absorbs a storage failure without creating a telemetry error record',
      () async {
        final failingStorage = _FailingInsertStorage();
        final failingClient = TelemetryClient(
          config: client.config,
          storage: failingStorage,
          initialPolicy: client.activePolicy,
        );
        final failingSink = TelemetryLogSink(client: failingClient);
        addTearDown(failingSink.close);
        addTearDown(failingClient.dispose);

        failingSink.write(
          _record(eventName: TelemetryEvents.appErrorCaptured.name),
        );
        await failingSink.pendingWrites;
        expect(await failingStorage.fetchAllForReplay(), isEmpty);

        failingSink.write(
          _record(eventName: TelemetryEvents.appErrorCaptured.name),
        );
        await failingSink.pendingWrites;
        expect(await failingStorage.fetchAllForReplay(), hasLength(1));
      },
    );

    test(
      'fails closed when structured attributes contain an unknown key',
      () async {
        sink.write(
          _record(
            eventName: TelemetryEvents.appErrorCaptured.name,
            errorCode: TelemetryErrorCodes.appUncaughtError.code,
            attributes: const {
              'message': 'uncaught failure',
              'unknown': 'must not be uploaded',
            },
          ),
        );

        await sink.pendingWrites;

        expect(await storage.fetchAllForReplay(), isEmpty);
      },
    );

    test('redacts adversarial diagnostic text before durable storage', () async {
      sink.write(
        _record(
          eventName: TelemetryEvents.appErrorCaptured.name,
          errorCode: TelemetryErrorCodes.appUncaughtError.code,
          attributes: const {
            'message':
                'password=plain-placeholder Bearer bearer-placeholder '
                'eyJhbGciOiJub25lIn0.eyJzdWIiOiJwbGFjZWhvbGRlciJ9.sig',
            'details':
                'ssh://placeholder-user@192.0.2.10:22/home/placeholder '
                'command=cat /tmp/placeholder-content',
          },
          error: StateError(
            'request failed password=exception-placeholder token=token-placeholder',
          ),
          stackTrace: StackTrace.fromString(
            'Authorization: Bearer stack-placeholder\n'
            'at /home/placeholder/lib/client.dart:1:1',
          ),
        ),
      );

      await sink.pendingWrites;

      final records = await storage.fetchAllForReplay();
      expect(records, hasLength(1));
      final json = records.single.toJson().toString();
      expect(json, isNot(contains('plain-placeholder')));
      expect(json, isNot(contains('bearer-placeholder')));
      expect(json, isNot(contains('eyJhbGciOiJub25lIn0')));
      expect(json, isNot(contains('placeholder-user')));
      expect(json, isNot(contains('192.0.2.10')));
      expect(json, isNot(contains('/home/placeholder')));
      expect(json, isNot(contains('cat /tmp/placeholder-content')));
      expect(json, isNot(contains('exception-placeholder')));
      expect(json, isNot(contains('token-placeholder')));
      expect(json, isNot(contains('stack-placeholder')));
    });
  });
}

final class _FailingInsertStorage extends MemoryTelemetryStorage {
  bool _failNext = true;

  @override
  Future<void> insertRecord(TelemetryEventRecord record) async {
    if (_failNext) {
      _failNext = false;
      throw StateError('placeholder storage failure');
    }
    await super.insertRecord(record);
  }
}

LogRecord _record({
  LogLevel level = LogLevel.error,
  String? eventName,
  String? errorCode,
  String? traceId,
  Map<String, dynamic> attributes = const {},
  String? details,
  Object? error,
  StackTrace? stackTrace,
}) {
  return LogRecord(
    timestamp: DateTime.utc(2026, 8, 28),
    level: level,
    message: 'structured log message',
    source: 'test',
    eventName: eventName,
    errorCode: errorCode,
    traceId: traceId,
    attributes: attributes,
    details: details,
    error: error,
    stackTrace: stackTrace,
  );
}
