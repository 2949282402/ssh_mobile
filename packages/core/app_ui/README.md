最新更新时间：2026-09-01

# app_ui

`app_ui` 是 SSH Mobile 的共享 UI 基础包，负责跨 Feature 复用的 Design System 令牌（Typography、Spacing、Status Colors、Radius）、响应式布局计算和无业务依赖的通用 Developer Tool 工作区 Widget（Surface、Toolbar、Dialog、BottomSheet、EmptyState、Loading）。

## 边界

- 只依赖 Flutter 与 UI 组件库，不依赖任何 Feature、数据库、SSH、网络或应用服务。
- 通过 `lib/app_ui.dart` 暴露公共 API，调用方不得引用 `lib/src/`。
- Feature 专属 Widget、业务模型、页面文案和状态逻辑继续留在所属 Feature。
- `AppPageSurface`、`AppContentSurface`、`AppToolbar`、`AppDialog`、`AppConfirmDialog`、`AppErrorDialog`、`AppBottomSheet`、`AppEmptyState`、`AppLoadingIndicator`、`AppInlineProgress`、`AppSkeletonizer`、`AppTypography`、`AppSpacing`、`AppStatusColors`、`AppTheme` 和响应式工具在此包统一维护。
- `AppTheme` 的主题组合入口与控件级构建器分文件维护；两者仍属于同一个私有 library，公共主题 API 不变。

## New UI Page Checklist（新建 UI 页面规范检查清单）

创建或重构页面时，必须依次遵循以下 Design System 构件与令牌：

1. **`AppPageSurface`**：页面统一使用纯色中性底色作为工作区基底，消除渐变、毛玻璃或装饰性噪点。
2. **`AppToolbar`**：统一使用标准工具栏（40~48dp 高度），操作项必须使用 `AppToolbarAction`（支持移动端 >=44dp 响应式热区与桌面端 32dp 紧凑尺寸）与 `AppToolbarGroup`。
3. **`AppTypography`**：排版文本统一使用 `AppTypography.of(context)` / `context.typography`，禁止在 Feature 内散落硬编码 `fontSize:` 魔法数字。
4. **`AppSpacing`**：内外边距与间隙统一使用 `context.spacing` / `AppSpacing.*` 预设间距（`insetsSm`, `insetsMd`, `vGapSm`, `hGapSm` 等），禁止硬编码 `EdgeInsets.all(13)` 或 `SizedBox(height: 17)`。
5. **`AppEmptyState`**：列表、会话或详情无数据时统一使用 `AppEmptyState`（信息优先、24~28dp 紧凑图标、克制操作）。
6. **`AppLoading`**：数据加载与耗时等待统一使用 `AppLoadingIndicator` / `AppInlineProgress` / `AppSkeletonizer`，禁止在 Feature 中直接使用裸 `CircularProgressIndicator`。
7. **`AppDialog`**：对话框交互统一使用 `AppDialog` / `AppConfirmDialog` / `AppErrorDialog`，禁止在 Feature 中直接使用 Material `showDialog` + `AlertDialog`。

## 生命周期

本包只创建 Flutter Widget 自己拥有的 Controller/AnimationController，并在对应 State 的 `dispose` 中释放；不持有 App Scope 或后台资源。

## Package contract

- 职责：提供共享主题、Design System 令牌、响应式指标和无业务状态的公共 Workspace Widget。
- 不负责：Feature 页面、业务模型、数据库、SSH、网络或 App Service。
- Public API：`package:app_ui/app_ui.dart`；外部不得引用 `lib/src/`。
- 依赖：Flutter、`animations` 和 `shadcn_ui`。
- 数据库：不拥有数据库。
- 生命周期与资源 Owner：Widget State 拥有自身 Controller/AnimationController，
  并在 `dispose()` 中释放；Package 不持有后台资源。
- 测试命令：`flutter analyze --no-pub`、`flutter test --no-pub`。
