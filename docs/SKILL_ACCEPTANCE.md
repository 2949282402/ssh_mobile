# 本地 AI Skills 结构化升级验收指南

本文档提供针对本次本地 AI Skills 结构化升级的系统验收标准。验收覆盖创建、更新、References、Frontmatter 同步、记忆检索召回、审批预览、性能及隐私脱敏。

---

## 1. 验收标准与测试矩阵

### 1.1 创建 Skill 验收 (Create Skill)
- **输入来源**:
  - UI 界面直接创建（由 `AiSkillsViewModel` 触发）。
  - AI 代理调用 `client_save_experience_skill` 触发。
- **验收要点**:
  - 必须由 `SkillDomainService` 统一进行数据清洗与构建。
  - References 必须被 trim、去空、去重。
  - `client_save_experience_skill` 调用必须触发 `local_skill_change` 审批，若未传入 `approvedWrite: true` 则必须拦截报错。
- **测试用例**: `test/services/skill_domain_service_test.dart` 中的 `"buildCreateSkill constructs canonical record fields"` 及 `test/services/ai_tool_service_test.dart`。

### 1.2 更新 Skill 验收 (Update Skill)
- **输入来源**:
  - UI 界面修改保存。
  - AI 代理调用 `client_update_skill` 触发。
- **验收要点**:
  - 必须支持局部更新（未传入字段不清空，以当前已保存数据为 fallback）。
  - Frontmatter 同步：只有在 `name` 或 `description` 确实发生变化时，才同步/更新 Markdown 文本中的 frontmatter yaml 头部；若原本没有 frontmatter，不额外插入 Header。
  - `client_update_skill` 调用必须触发 `local_skill_change` 审批。
  - 用户传入空字符串时必须能够 fallback 而不是无条件清空。
- **测试用例**: `test/services/skill_domain_service_test.dart` 中的 `"buildUpdateSkill performs partial update"` 及 `"buildUpdateSkill with empty or whitespace values fallbacks to existing or frontmatter"`。

### 1.3 审批与预览 (Approval Preview & Privacy)
- **验收要点**:
  - 审批类型统一为 `local_skill_change`。
  - 审批预览能够清晰地反映前后改动的 Name、Description、Enabled 状态，以及 References 增加/删除/修改的计数变化。
  - 审批预览内容与敏感字段处理走 `ToolSecretPolicy.previewText()`。
  - 日志中不得包含完整的正文 content 和 references content 详情，仅保留摘要或计数。
- **测试用例**: `test/services/skill_domain_service_test.dart` 中的 `"generatePreview detects modified changes"`。

### 1.4 内存检索召回与 Fallback (Recall & Index)
- **验收要点**:
  - 检索使用 `SkillIndexService` 进行在内存中的高效倒排/分词缓存匹配，以优化检索效率。
  - 召回必须与原本的检索算分逻辑保持一致（包含对英文字符分词、中文 bigram 滑窗分词、以及命令/路径加权逻辑）。
  - 必须具备健壮的 fallback 机制：若 `SkillIndexService` 初始化或执行期间发生任何异常崩溃，自动捕获并无缝降级到逐个 Skill 全量扫描检索逻辑。
  - 必须具备 Revision Key 控制，当 Skill 列表和更新状态未发生任何改变时，拒绝重复重建索引以实现零开销。
- **测试用例**: `test/services/skill_index_service_test.dart` 中的 `"performance benchmark"` 与 `"does not rebuild index when revision key matches"`，以及 `test/services/operational_memory_retriever_test.dart` 中的 `"fallbacks to legacy search when SkillIndexService throws Exception"`。

---

## 2. 自动化测试执行
在项目根目录下，执行以下命令以确认所有相关测试均通过：

```bash
# 运行 Skill 领域服务测试
flutter test test/services/skill_domain_service_test.dart

# 运行 Skill 内存索引服务测试
flutter test test/services/skill_index_service_test.dart

# 运行 运维记忆检索召回服务测试
flutter test test/services/operational_memory_retriever_test.dart

# 运行 AI 工具服务整体测试（涵盖审批流拦截与预览）
flutter test test/services/ai_tool_service_test.dart

# 运行 UI ViewModel 测试
flutter test test/features/ai_skills/viewmodels/ai_skills_viewmodel_test.dart
```

确保控制台输出 `All tests passed!` 且没有任何 warning 和编译期报错。
