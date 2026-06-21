part of '../app_database.dart';

const int _aiChatRetentionLimit = 80;

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
      await _deleteChatsBeyondRetention(_aiChatRetentionLimit);
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
      await _deleteChatsBeyondRetention(_aiChatRetentionLimit);
    });
  }

  Future<void> deleteChat(String id) async {
    await (delete(aiChats)..where((row) => row.id.equals(id))).go();
  }

  Future<List<AiChatMessage>> loadAllMessagesForReencryption() {
    return select(aiChatMessages).get();
  }

  Future<void> updateMessageSensitiveFields({
    required String id,
    required String textContent,
    String? contextText,
    required String attachmentsJson,
    required String tracesJson,
    required String todoStepsJson,
  }) {
    return (update(aiChatMessages)..where((row) => row.id.equals(id))).write(
      AiChatMessagesCompanion(
        textContent: Value(textContent),
        contextText: Value(contextText),
        attachmentsJson: Value(attachmentsJson),
        tracesJson: Value(tracesJson),
        todoStepsJson: Value(todoStepsJson),
      ),
    );
  }

  Future<void> _deleteChatsBeyondRetention(int limit) async {
    final orderedIds = await (selectOnly(aiChats)
          ..addColumns([aiChats.id])
          ..orderBy([
            OrderingTerm(
              expression: aiChats.updatedAt,
              mode: OrderingMode.desc,
            ),
          ]))
        .map((row) => row.read(aiChats.id))
        .get()
        .then((ids) => ids.whereType<String>().toList(growable: false));
    final staleIds = orderedIds.skip(limit).toList(growable: false);
    if (staleIds.isNotEmpty) {
      await (delete(aiChats)..where((row) => row.id.isIn(staleIds))).go();
    }
  }
}
