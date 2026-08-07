最新更新时间：2026-08-08

# app_ui Agent 指南

- 共享 UI 只通过 `lib/app_ui.dart` 暴露，不得从其他 Package 引用 `lib/src/`。
- 不在本包引入 Feature、SSH、网络、数据库或应用服务；需要业务数据时由调用方转换为 Widget 参数。
- 新 Widget 需要说明职责，并为 AnimationController、ScrollController 等资源实现完整的 `dispose`。
- 修改后至少执行 `flutter analyze --no-pub`、`flutter test --no-pub` 和根应用回归测试。
