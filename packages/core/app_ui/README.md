最新更新时间：2026-08-08

# app_ui

`app_ui` 是 SSH Mobile 的共享 UI 基础包，负责跨 Feature 复用的主题、响应式布局计算和无业务依赖的通用 Widget。

## 边界

- 只依赖 Flutter 与 UI 组件库，不依赖任何 Feature、数据库、SSH、网络或应用服务。
- 通过 `lib/app_ui.dart` 暴露公共 API，调用方不得引用 `lib/src/`。
- Feature 专属 Widget、业务模型、页面文案和状态逻辑继续留在所属 Feature。
- `AppPageSurface`、`ConnectionProgressDialog`、`DestructiveConfirmDialog`、`OverflowScrollText`、`TactileFeedback`、`AppTheme` 和响应式工具在本 Step 迁入此包。

## 生命周期

本包只创建 Flutter Widget 自己拥有的 Controller/AnimationController，并在对应 State 的 `dispose` 中释放；不持有 App Scope 或后台资源。
