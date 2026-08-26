import 'dart:async';
import 'dart:io';

import 'package:app_ui/app_ui.dart';
import 'package:feature_rag/feature_rag.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';

import '../fakes/rag_test_fakes.dart';

final class _FakeRagRepository implements RagRepository {
  List<RagDocumentMetadata> docs = [];
  bool shouldFail = false;
  Completer<RagRepositorySnapshot>? snapshotCompleter;
  Completer<void>? saveStateCompleter;

  @override
  Future<RagRepositorySnapshot> loadSnapshot() async {
    if (shouldFail) {
      throw Exception('Database snapshot failed');
    }
    if (snapshotCompleter != null) {
      return snapshotCompleter!.future;
    }
    return RagRepositorySnapshot(
      documents: docs,
      index: null,
      cacheEntries: const [],
    );
  }

  @override
  Future<void> saveState({
    required List<RagDocumentMetadata> documents,
    required RagIndexMetadata index,
    required List<RagCacheMetadata> cacheEntries,
  }) async {
    if (saveStateCompleter != null) {
      await saveStateCompleter!.future;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('RagKnowledgeScreen renders skeleton when initial loading', (
    tester,
  ) async {
    final repo = _FakeRagRepository();
    final completer = Completer<RagRepositorySnapshot>();
    repo.snapshotCompleter = completer;
    final settings = FakeRagSettings()..isEnglish = true;
    final logger = RecordingRagLogger();
    final tempDir = Directory.systemTemp.createTempSync('rag-screen-test-1-');
    addTearDown(() => tempDir.deleteSync(recursive: true));
    final service = RagService(
      repository: repo,
      settings: settings,
      logger: logger,
      cacheStore: RagCacheStore(directoryFactory: () async => tempDir),
    );
    final viewModel = RagKnowledgeViewModel(
      ragService: service,
      settings: settings,
    );

    await tester.pumpWidget(
      MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: viewModel),
          ListenableProvider<RagSettingsPort>.value(value: settings),
        ],
        child: const MaterialApp(home: RagKnowledgeScreen()),
      ),
    );

    await tester.pump();
    expect(find.byType(AppSkeletonizer), findsOneWidget);

    completer.complete(
      const RagRepositorySnapshot(documents: [], index: null, cacheEntries: []),
    );
    await tester.pumpAndSettle();
    expect(find.byType(AppSkeletonizer), findsNothing);
  });

  testWidgets(
    'RagKnowledgeScreen renders empty state when initialized with no docs',
    (tester) async {
      final repo = _FakeRagRepository();
      final settings = FakeRagSettings()..isEnglish = true;
      final logger = RecordingRagLogger();
      final tempDir = Directory.systemTemp.createTempSync('rag-screen-test-2-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final service = RagService(
        repository: repo,
        settings: settings,
        logger: logger,
        cacheStore: RagCacheStore(directoryFactory: () async => tempDir),
      );
      final viewModel = RagKnowledgeViewModel(
        ragService: service,
        settings: settings,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: viewModel),
            ListenableProvider<RagSettingsPort>.value(value: settings),
          ],
          child: const MaterialApp(home: RagKnowledgeScreen()),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(AppSkeletonizer), findsNothing);
      expect(find.text('No documents uploaded yet'), findsOneWidget);
    },
  );

  testWidgets(
    'RagKnowledgeScreen renders error and retry button on init failure',
    (tester) async {
      final repo = _FakeRagRepository()..shouldFail = true;
      final settings = FakeRagSettings()..isEnglish = true;
      final logger = RecordingRagLogger();
      final tempDir = Directory.systemTemp.createTempSync('rag-screen-test-3-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final service = RagService(
        repository: repo,
        settings: settings,
        logger: logger,
        cacheStore: RagCacheStore(directoryFactory: () async => tempDir),
      );
      final viewModel = RagKnowledgeViewModel(
        ragService: service,
        settings: settings,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: viewModel),
            ListenableProvider<RagSettingsPort>.value(value: settings),
          ],
          child: const MaterialApp(home: RagKnowledgeScreen()),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(AppSkeletonizer), findsNothing);
      expect(find.text('Failed to initialize knowledge base'), findsOneWidget);
      expect(find.byType(FilledButton), findsOneWidget);
    },
  );

  testWidgets(
    'RagKnowledgeScreen renders real documents when initialized with items',
    (tester) async {
      final repo = _FakeRagRepository()
        ..docs = [
          RagDocumentMetadata(
            id: 'doc-1',
            name: 'ServerOps.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1024,
            uploadedAt: DateTime.now(),
            chunkCount: 3,
          ),
        ];
      final settings = FakeRagSettings()..isEnglish = true;
      final logger = RecordingRagLogger();
      final tempDir = Directory.systemTemp.createTempSync('rag-screen-test-4-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final service = RagService(
        repository: repo,
        settings: settings,
        logger: logger,
        cacheStore: RagCacheStore(directoryFactory: () async => tempDir),
      );
      final viewModel = RagKnowledgeViewModel(
        ragService: service,
        settings: settings,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: viewModel),
            ListenableProvider<RagSettingsPort>.value(value: settings),
          ],
          child: const MaterialApp(home: RagKnowledgeScreen()),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(AppSkeletonizer), findsNothing);
      expect(find.text('ServerOps.pdf'), findsOneWidget);
    },
  );

  testWidgets(
    'RagKnowledgeScreen shows processing overlay and not skeleton when processing',
    (tester) async {
      final repo = _FakeRagRepository()
        ..docs = [
          RagDocumentMetadata(
            id: 'doc-1',
            name: 'ServerOps.pdf',
            mimeType: 'application/pdf',
            sizeBytes: 1024,
            uploadedAt: DateTime.now(),
            chunkCount: 3,
          ),
        ];
      final settings = FakeRagSettings()..isEnglish = true;
      final logger = RecordingRagLogger();
      final tempDir = Directory.systemTemp.createTempSync('rag-screen-test-5-');
      addTearDown(() => tempDir.deleteSync(recursive: true));
      final service = RagService(
        repository: repo,
        settings: settings,
        logger: logger,
        cacheStore: RagCacheStore(directoryFactory: () async => tempDir),
      );
      final viewModel = RagKnowledgeViewModel(
        ragService: service,
        settings: settings,
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider.value(value: viewModel),
            ListenableProvider<RagSettingsPort>.value(value: settings),
          ],
          child: const MaterialApp(home: RagKnowledgeScreen()),
        ),
      );
      await tester.pumpAndSettle();

      final saveCompleter = Completer<void>();
      repo.saveStateCompleter = saveCompleter;

      unawaited(viewModel.deleteDocument('doc-1'));
      await tester.pump();

      expect(find.text('Uploading & indexing...'), findsOneWidget);
      expect(find.byType(AppSkeletonizer), findsNothing);

      saveCompleter.complete();
      await tester.pumpAndSettle();
      expect(find.text('Uploading & indexing...'), findsNothing);
    },
  );
}
