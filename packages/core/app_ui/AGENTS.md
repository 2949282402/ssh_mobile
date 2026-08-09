最新更新时间：2026-08-10

# app_ui Agent 指南

- 共享 UI 只通过 `lib/app_ui.dart` 暴露，不得从其他 Package 引用 `lib/src/`。
- 不在本包引入 Feature、SSH、网络、数据库或应用服务；需要业务数据时由调用方转换为 Widget 参数。
- 新 Widget 需要说明职责，并为 AnimationController、ScrollController 等资源实现完整的 `dispose`。
- 修改后至少执行 `flutter analyze --no-pub`、`flutter test --no-pub` 和根应用回归测试。
- 主题文件尺寸治理应优先按职责拆分；`AppTheme` 的组合入口和控件级构建器可以分文件，不能为了阈值机械拆解连贯样式定义。

## Step29 标准字段

- 允许修改范围：共享主题、响应式指标、无业务 Widget、对应测试和文档。
- 禁止依赖：Feature、SSH、网络、数据库、App Service 或其他 Package 的 `/src/`。
- Public API 修改要求：只通过 `package:app_ui/app_ui.dart` 暴露，并同步调用方和视觉测试。
- 数据库约束：不拥有数据库，不保存业务状态。
- 资源释放规则：Widget State 释放自身 Controller/AnimationController；Package 不拥有后台资源。
- 必须运行的测试：`flutter analyze --no-pub`、`flutter test --no-pub` 和 Full App 回归测试。
