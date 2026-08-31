最新更新时间：2026-08-30

# app_ui 维护约束

- 共享 UI 只从 `lib/app_ui.dart` 暴露；不引入 Feature、SSH、网络、数据库或
  App Service，业务数据由调用方转成 Widget 参数。新 Widget 说明职责，并在
  State `dispose` 释放 Animation/Scroll 等 Controller。
- 主题组合入口与控件构建器可分文件，但不得为行数阈值机械拆分连贯样式。
- Contract：允许共享主题、响应式指标、无业务 Widget、测试和文档；不拥有
  数据库或后台资源。Public API、调用方和视觉测试同步变更。

## 验证（代码变更）

`flutter analyze --no-pub`、`flutter test --no-pub` 及受影响的 Full App 回归；
local aggregate CI 仅按用户明确要求运行。
