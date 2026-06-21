part of '../app_database.dart';

class AiChatWithMessages {
  final AiChat chat;
  final List<AiChatMessage> messages;

  const AiChatWithMessages({
    required this.chat,
    required this.messages,
  });
}

@DriftAccessor(tables: [AiChats, AiChatMessages])
class AiChatDao extends DatabaseAccessor<AppDatabase> with _$AiChatDaoMixin {
  AiChatDao(super.db);

  Future<List<AiChatWithMessages>> loadChats() async {
    final rows = await (select(aiChats)
          ..orderBy([
            (row) => OrderingTerm(
                  expression: row.updatedAt,
                  mode: OrderingMode.desc,
                ),
          ]))
        .get();
    final result = <AiChatWithMessages>[];
    for (final chat in rows) {
      final messages = await (select(aiChatMessages)
            ..where((row) => row.chatId.equals(chat.id))
            ..orderBy([
              (row) => OrderingTerm.asc(row.createdAt),
              (row) => OrderingTerm.asc(row.id),
            ]))
          .get();
      result.add(AiChatWithMessages(chat: chat, messages: messages));
    }
    return result;
  }

  Future<void> saveChat(
    AiChatsCompanion chat,
    List<AiChatMessagesCompanion> messages,
  ) async {
    await transaction(() async {
      await into(aiChats).insertOnConflictUpdate(chat);
      await (delete(aiChatMessages)
            ..where((row) => row.chatId.equals(chat.id.value)))
          .go();
      if (messages.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(aiChatMessages, messages);
        });
      }
    });
  }

  Future<void> replaceAllChats(
    List<AiChatsCompanion> chats,
    Map<String, List<AiChatMessagesCompanion>> messagesByChatId,
  ) async {
    await transaction(() async {
      await delete(aiChatMessages).go();
      await delete(aiChats).go();
      if (chats.isNotEmpty) {
        await batch((batch) {
          batch.insertAll(aiChats, chats);
          for (final entry in messagesByChatId.entries) {
            final messages = entry.value;
            if (messages.isNotEmpty) {
              batch.insertAll(aiChatMessages, messages);
            }
          }
        });
      }
    });
  }

  Future<void> deleteChat(String id) async {
    await (delete(aiChats)..where((row) => row.id.equals(id))).go();
  }
}
