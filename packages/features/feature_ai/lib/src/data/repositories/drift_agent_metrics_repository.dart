// AI 数据库仓储已统一收敛到 ai_repository.dart。
//
// 保留这个迁移期路径，避免外部测试或旧分支 import 立即失效；文件不再
// 保留迁移期的数据访问实现，实际 Owner 由 AiModule 持有。

export 'ai_repository.dart';
