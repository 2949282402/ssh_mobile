// Playbook 执行历史的持久化模型。
//
// 命令、标准输出和错误输出都通过 Repository 加密后写入数据库；这里的
// 模型只负责表达 Service 当前快照，不直接暴露数据库生成类型。

import '../features/playbook/models/playbook.dart';

/// 一次 Playbook 执行的可持久化快照。
final class PlaybookRunSnapshot {
  const PlaybookRunSnapshot({
    required this.id,
    required this.playbookId,
    required this.connectionId,
    required this.status,
    required this.startedAt,
    required this.finishedAt,
    required this.summary,
    required this.errorMessage,
    required this.steps,
  });

  final String id;
  final String playbookId;
  final String? connectionId;
  final String status;
  final DateTime startedAt;
  final DateTime? finishedAt;
  final String summary;
  final String? errorMessage;
  final List<PlaybookRunStepSnapshot> steps;
}

/// 一次执行中单个步骤的历史快照。
final class PlaybookRunStepSnapshot {
  const PlaybookRunStepSnapshot({
    required this.id,
    required this.stepIndex,
    required this.step,
  });

  final String id;
  final int stepIndex;
  final PlaybookStep step;
}
