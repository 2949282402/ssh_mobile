import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/data/database/app_database.dart' as db;
import 'package:ssh_mobile/features/ai_chat/models/agent_trace_event.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    AppLogService.instance.clear();
  });

  test('saves and loads a single trace event', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    final event = _event(runId: 'run-1', sequence: 0, title: 'Started');
    await storage.saveAgentTraceEvent(event);

    final loaded = await storage.loadAgentTraceEvents('run-1');
    expect(loaded, hasLength(1));
    expect(loaded.single.title, 'Started');
  });

  test('batch save reads by run id ordered by sequence', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    await storage.saveAgentTraceEvents([
      _event(runId: 'run-1', sequence: 2, title: 'third'),
      _event(runId: 'run-1', sequence: 0, title: 'first'),
      _event(runId: 'run-1', sequence: 1, title: 'second'),
    ]);

    final loaded = await storage.loadAgentTraceEvents('run-1');
    expect(loaded.map((event) => event.title), ['first', 'second', 'third']);
  });

  test('loads recent run ids for chat by latest event time', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    final base = DateTime.utc(2026, 6, 22);
    await storage.saveAgentTraceEvents([
      _event(runId: 'old-run', sequence: 0, createdAt: base),
      _event(
        runId: 'new-run',
        sequence: 0,
        createdAt: base.add(const Duration(minutes: 1)),
      ),
      _event(
        runId: 'other-chat-run',
        chatId: 'other-chat',
        sequence: 0,
        createdAt: base.add(const Duration(minutes: 2)),
      ),
    ]);

    final runIds = await storage.loadRecentAgentTraceRunIdsForChat(
      'chat-1',
      limit: 10,
    );
    expect(runIds, ['new-run', 'old-run']);
  });

  test('trims old runs and caps events per run', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    final base = DateTime.utc(2026, 6, 22);
    for (var i = 0; i < agentTraceRunRetentionLimit + 5; i++) {
      await storage.saveAgentTraceEvent(
        _event(
          runId: 'run-$i',
          sequence: 0,
          createdAt: base.add(Duration(minutes: i)),
        ),
      );
    }

    final retained = await storage.loadRecentAgentTraceRunIdsForChat(
      'chat-1',
      limit: 300,
    );
    expect(retained, hasLength(agentTraceRunRetentionLimit));
    expect(retained.first, 'run-${agentTraceRunRetentionLimit + 4}');
    expect(retained, isNot(contains('run-0')));

    await storage.saveAgentTraceEvents([
      for (var i = 0; i < agentTraceEventsPerRunLimit + 5; i++)
        _event(runId: 'dense-run', sequence: i),
    ]);
    final dense = await storage.loadAgentTraceEvents('dense-run');
    expect(dense, hasLength(agentTraceEventsPerRunLimit));
    expect(dense.last.sequence, agentTraceEventsPerRunLimit - 1);
  });

  test('cache is invalidated when retention trims stale runs', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    final base = DateTime.utc(2026, 6, 22);
    await storage.saveAgentTraceEvent(
      _event(runId: 'stale-run', sequence: 0, createdAt: base),
    );
    expect(await storage.loadAgentTraceEvents('stale-run'), hasLength(1));

    for (var i = 0; i < agentTraceRunRetentionLimit; i++) {
      await storage.saveAgentTraceEvent(
        _event(
          runId: 'new-run-$i',
          sequence: 0,
          createdAt: base.add(Duration(minutes: i + 1)),
        ),
      );
    }

    expect(await storage.loadAgentTraceEvents('stale-run'), isEmpty);
  });

  test('batch save caps events per run instead of per batch', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    await storage.saveAgentTraceEvents([
      for (var i = 0; i < agentTraceEventsPerRunLimit + 2; i++)
        _event(runId: 'dense-a', sequence: i),
      for (var i = 0; i < 3; i++) _event(runId: 'dense-b', sequence: i),
    ]);

    expect(
      await storage.loadAgentTraceEvents('dense-a'),
      hasLength(agentTraceEventsPerRunLimit),
    );
    expect(await storage.loadAgentTraceEvents('dense-b'), hasLength(3));
  });

  test('truncates long content and empty batch save is harmless', () async {
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    await storage.saveAgentTraceEvents(const []);
    await storage.saveAgentTraceEvent(
      _event(
        runId: 'run-long',
        sequence: 0,
        content: 'x' * (agentTraceContentMaxChars + 16),
      ),
    );

    final loaded = await storage.loadAgentTraceEvents('run-long');
    expect(loaded.single.truncated, isTrue);
    expect(loaded.single.content.length, agentTraceContentMaxChars);
  });

  test('encrypts content_json in Drift and deletes events for run', () async {
    const marker = 'TRACE_SECRET_MARKER_20260622';
    final database = db.AppDatabase.forTesting();
    addTearDown(database.close);
    final storage = StorageService(database: database);
    addTearDown(storage.dispose);
    await storage.init();

    await storage.saveAgentTraceEvent(
      _event(runId: 'run-secret', sequence: 0, content: marker),
    );

    final raw = await database
        .customSelect('SELECT content_json FROM agent_trace_events')
        .getSingle();
    expect(raw.read<String>('content_json'), isNot(contains(marker)));
    expect(
      (await storage.loadAgentTraceEvents('run-secret')).single.content,
      contains(marker),
    );

    await storage.deleteAgentTraceEvents('run-secret');
    expect(await storage.loadAgentTraceEvents('run-secret'), isEmpty);
  });
}

AgentTraceEvent _event({
  required String runId,
  required int sequence,
  String chatId = 'chat-1',
  String title = 'Trace',
  String content = '{}',
  DateTime? createdAt,
}) {
  return AgentTraceEvent(
    id: '$runId-$sequence',
    runId: runId,
    chatId: chatId,
    createdAt: createdAt ?? DateTime.utc(2026, 6, 22, 10, 0, sequence),
    sequence: sequence,
    kind: 'tool_request',
    title: title,
    content: content,
  );
}
