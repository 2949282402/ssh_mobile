import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssh_mobile/services/ai_tool_service.dart';
import 'package:ssh_mobile/services/llm_chat_service.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/performance_monitor_tool_service.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/server_diagnostics_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';

void main() {
  group('LlmChatService token estimates', () {
    test('counts ASCII in four-character chunks and non-ASCII per rune', () {
      expect(LlmChatService.estimateTextTokens(''), 0);
      expect(LlmChatService.estimateTextTokens('abcd'), 1);
      expect(LlmChatService.estimateTextTokens('abcde'), 2);
      expect(LlmChatService.estimateTextTokens('中文'), 2);
      expect(LlmChatService.estimateTextTokens('abcd中文'), 3);
    });

    test('adds per-message overhead', () {
      final tokens = LlmChatService.estimateMessagesTokens([
        {'role': 'user', 'content': 'abcd'},
        {'role': 'assistant', 'content': '中文'},
      ]);

      expect(tokens, 4 + 1 + 1 + 4 + 3 + 2);
    });
  });

  group('OpenAI-compatible URL resolution', () {
    test('appends chat completion path to a versioned base URL', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/',
          '/chat/completions',
        ),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('switches between full chat and models endpoints', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/chat/completions',
          '/models',
        ),
        'https://api.example.com/v1/models',
      );
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1/models',
          '/chat/completions',
        ),
        'https://api.example.com/v1/chat/completions',
      );
    });

    test('drops accidental query strings and fragments', () {
      expect(
        LlmChatService.resolveOpenAiCompatibleUrl(
          'https://api.example.com/v1?debug=1#frag',
          '/models',
        ),
        'https://api.example.com/v1/models',
      );
    });
  });

  test('recognizes provider errors for unsupported function tools', () {
    expect(
      LlmChatService.looksLikeToolUnsupportedError(
        '{"error":"tool_choice is not supported"}',
      ),
      isTrue,
    );
    expect(
      LlmChatService.looksLikeToolUnsupportedError('invalid model'),
      isFalse,
    );
  });

  group('LlmChatService cancellation & compression', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      SharedPreferences.setMockInitialValues({});
      FlutterSecureStorage.setMockInitialValues({});
    });

    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('LlmCancellationToken propagates cancellation immediately', () {
      final token = LlmCancellationToken();
      expect(token.isCancelled, isFalse);
      
      token.cancel();
      expect(token.isCancelled, isTrue);
      expect(() => token.throwIfCancelled(), throwsA(isA<LlmCancelledException>()));
    });

    test('stream with cancelled token during compression throws LlmCancelledException', () async {
      final storage = StorageService();
      await storage.init();
      
      await storage.saveAiConnectionSettings(
        baseUrl: 'https://api.example.com',
        model: 'demo-model',
        apiKey: 'dummy-key',
      );

      final ssh = SshService(storage);
      final sftp = SftpService(storage);
      final diagnostics = ServerDiagnosticsService(
        storageService: storage,
        sshService: ssh,
      );
      final monitor = PerformanceMonitorService(ssh, storage);
      final tools = AiToolService(
        storageService: storage,
        sshService: ssh,
        sftpService: sftp,
        serverDiagnosticsService: diagnostics,
        performanceMonitorToolService: PerformanceMonitorToolService(monitor),
      );

      final llm = LlmChatService(
        storageService: storage,
        toolService: tools,
      );

      final token = LlmCancellationToken();
      token.cancel();

      final messages = [
        {'role': 'user', 'content': 'hello'},
      ];

      expect(
        () => llm.stream(
          messages: messages,
          cancellationToken: token,
          forceContextCompression: true,
        ).toList(),
        throwsA(isA<LlmCancelledException>()),
      );
      
      storage.dispose();
    });
  });
}
