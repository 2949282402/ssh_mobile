import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_context_builder.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_message_mapper.dart';
import 'package:ssh_mobile/features/ai_chat/services/ai_chat_token_estimator.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late StorageService storageService;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    FlutterSecureStorage.setMockInitialValues({});
    storageService = StorageService();
    await storageService.init();
  });

  tearDown(() {
    storageService.dispose();
  });

  group('AiChatTokenEstimator Tests', () {
    const contextBuilder = AiChatContextBuilder();
    const mapper = AiChatMessageMapper(contextBuilder: contextBuilder);

    test('contextTokensFor caches result, invalidates on message changes', () {
      final estimator = AiChatTokenEstimator(messageMapper: mapper);

      final chat1 = AiChatRecord(
        id: 'chat-1',
        title: 'Title',
        model: 'gpt-4o',
        messages: [
          AiChatMessageRecord(
            role: 'user',
            text: 'hello',
            createdAt: DateTime.now(),
          ),
        ],
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

      final tokens1 = estimator.contextTokensFor(chat1, sending: false);
      expect(tokens1, greaterThan(0));

      // Same key should hit cache
      final tokens2 = estimator.contextTokensFor(chat1, sending: false);
      expect(tokens2, equals(tokens1));

      // Add a message -> invalidates cache
      final chat2 = chat1.copyWith(
        messages: [
          ...chat1.messages,
          AiChatMessageRecord(
            role: 'assistant',
            text: 'hi',
            createdAt: DateTime.now(),
          ),
        ],
      );

      final tokens3 = estimator.contextTokensFor(chat2, sending: false);
      expect(tokens3, greaterThan(tokens1));
    });

    test(
      'contextTokensFor throttles query within 1500ms when sending is true',
      () async {
        final estimator = AiChatTokenEstimator(messageMapper: mapper);

        final chat = AiChatRecord(
          id: 'chat-1',
          title: 'Title',
          model: 'gpt-4o',
          messages: [
            AiChatMessageRecord(
              role: 'user',
              text: 'hello',
              createdAt: DateTime.now(),
            ),
          ],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final tokens1 = estimator.contextTokensFor(chat, sending: true);

        // Modify last message -> normally invalidates, but within 1500ms when sending should hit cache
        final chatModified = AiChatRecord(
          id: 'chat-1',
          title: 'Title',
          model: 'gpt-4o',
          messages: [
            AiChatMessageRecord(
              role: 'user',
              text: 'hello modified!',
              createdAt: DateTime.now(),
            ),
          ],
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        );

        final tokens2 = estimator.contextTokensFor(chatModified, sending: true);
        expect(tokens2, equals(tokens1)); // Throttled/Cached

        // invalidate forces re-estimate
        estimator.invalidate();
        final tokens3 = estimator.contextTokensFor(chatModified, sending: true);
        expect(tokens3, isNot(equals(tokens1)));
      },
    );
  });
}
