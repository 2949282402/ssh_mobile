import 'package:drift/native.dart';
import 'package:feature_ai/feature_ai.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../test_utils/test_storage_adapter.dart';

/// Step22 之后的存储边界测试：AI 数据库由 AI Module/Repository 自己拥有，
/// 测试夹具也不得通过已经删除的统一业务数据库暴露数据库句柄。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'AI Repository persists chat records in its independent database',
    () async {
      final database = AiDatabase.forTesting(NativeDatabase.memory());
      final repository = DriftAiRepository(
        database,
        const _PlaintextProtection(),
      );
      addTearDown(database.dispose);

      final now = DateTime.utc(2026, 8, 9, 12);
      await repository.saveChat(
        AiChatRecord(
          id: 'chat-1',
          title: 'Independent AI chat',
          model: 'test-model',
          createdAt: now,
          updatedAt: now,
          messages: const [],
        ),
      );

      expect(
        (await repository.loadChats()).single.title,
        'Independent AI chat',
      );
    },
  );

  test('App AI storage adapter owns its AI database lifecycle', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    SharedPreferences.setMockInitialValues(<String, Object>{});
    final storage = TestStorageAdapter();
    await storage.init();
    addTearDown(storage.dispose);

    final now = DateTime.utc(2026, 8, 9, 12);
    await storage.saveAiChat(
      AiChatRecord(
        id: 'chat-2',
        title: 'Adapter chat',
        model: 'test-model',
        createdAt: now,
        updatedAt: now,
        messages: const [],
      ),
    );

    expect((await storage.loadAiChats()).single.id, 'chat-2');
    await storage.shutdown();
  });
}

/// 测试专用的可逆保护实现；这里只验证 Repository 的生命周期和读写，
/// 生产环境仍由 App Shell 注入真实数据保护能力。
final class _PlaintextProtection implements AiTextProtectionPort {
  const _PlaintextProtection();

  @override
  Future<String> encrypt(String plainText) async => plainText;

  @override
  Future<String> decrypt(String storedText) async => storedText;
}
