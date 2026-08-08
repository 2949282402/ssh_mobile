part of '../storage_service.dart';

/// 迁移期间保留在 App Shell 的排序辅助函数。
///
/// AI 聊天和技能记录的持久化已由 feature_ai 接管，但旧的 Playbook
/// Repository 与 StorageService 仍调用这些稳定的去重排序行为。
List<AiChatRecord> upsertAiChatRecordsByUpdatedAt(
  Iterable<AiChatRecord> chats,
  AiChatRecord chat, {
  int? limit,
}) {
  final ordered = <AiChatRecord>[];
  var inserted = false;
  for (final item in chats) {
    if (item.id == chat.id) continue;
    if (!inserted && !chat.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(chat);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) ordered.add(chat);
  if (limit != null && ordered.length > limit) {
    ordered.removeRange(limit, ordered.length);
  }
  return ordered;
}

List<AiSkillRecord> upsertAiSkillRecordsByUpdatedAt(
  Iterable<AiSkillRecord> skills,
  AiSkillRecord skill,
) {
  final ordered = <AiSkillRecord>[];
  var inserted = false;
  for (final item in skills) {
    if (item.id == skill.id) continue;
    if (!inserted && !skill.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(skill);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) ordered.add(skill);
  return ordered;
}

List<Playbook> upsertPlaybooksByUpdatedAt(
  Iterable<Playbook> playbooks,
  Playbook playbook,
) {
  final ordered = <Playbook>[];
  var inserted = false;
  for (final item in playbooks) {
    if (item.id == playbook.id) continue;
    if (!inserted && !playbook.updatedAt.isBefore(item.updatedAt)) {
      ordered.add(playbook);
      inserted = true;
    }
    ordered.add(item);
  }
  if (!inserted) ordered.add(playbook);
  return ordered;
}
