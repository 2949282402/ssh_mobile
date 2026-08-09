最新更新时间：2026-08-10

# app_ui

`app_ui` 是 SSH Mobile 的共享 UI 基础包，负责跨 Feature 复用的主题、响应式布局计算和无业务依赖的通用 Widget。

## 边界

- 只依赖 Flutter 与 UI 组件库，不依赖任何 Feature、数据库、SSH、网络或应用服务。
- 通过 `lib/app_ui.dart` 暴露公共 API，调用方不得引用 `lib/src/`。
- Feature 专属 Widget、业务模型、页面文案和状态逻辑继续留在所属 Feature。
- `AppPageSurface`、`ConnectionProgressDialog`、`DestructiveConfirmDialog`、`OverflowScrollText`、`TactileFeedback`、`AppTheme` 和响应式工具在本 Step 迁入此包。
- `AppTheme` 的主题组合入口与控件级构建器分文件维护；两者仍属于同一个私有 library，公共主题 API 不变。

## 生命周期

本包只创建 Flutter Widget 自己拥有的 Controller/AnimationController，并在对应 State 的 `dispose` 中释放；不持有 App Scope 或后台资源。

## Package contract

- 职责：提供共享主题、响应式指标和无业务状态的公共 Widget。
- 不负责：Feature 页面、业务模型、数据库、SSH、网络或 App Service。
- Public API：`package:app_ui/app_ui.dart`；外部不得引用 `lib/src/`。
- 依赖：Flutter、`animations` 和 `shadcn_ui`。
- 数据库：不拥有数据库。
- 生命周期与资源 Owner：Widget State 拥有自身 Controller/AnimationController，
  并在 `dispose()` 中释放；Package 不持有后台资源。
- 测试命令：`flutter analyze --no-pub`、`flutter test --no-pub`。
