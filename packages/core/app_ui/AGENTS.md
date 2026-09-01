最新更新时间：2026-09-01

# app_ui 维护约束

- 共享 UI 只从 `lib/app_ui.dart` 暴露；不引入 Feature、SSH、网络、数据库或
  App Service，业务数据由调用方转成 Widget 参数。新 Widget 说明职责，并在
  State `dispose` 释放 Animation/Scroll 等 Controller。
- 主题组合入口与控件构建器可分文件，但不得为行数阈值机械拆分连贯样式。
- Contract：允许共享主题、响应式指标、无业务 Widget、测试和文档；不拥有
  数据库或后台资源。Public API、调用方和视觉测试同步变更。

## Design System 设计规范与约束

### 1. Visual Language
- 整体风格定义为专业、克制、高信息密度、内容优先（Professional, Quiet, Dense, Technical, Content-First）的现代开发者工具。

### 2. Gradient Policy
- 普通页面背景、卡片、按钮、导航栏、图标徽章**严禁使用装饰性渐变（LinearGradient / RadialGradient）**。
- 仅允许在真实业务数据可视化（如 CPU/内存历史图表、监控波形）中使用必要的数据渐变。

### 3. Shadow & Elevation Policy
- 常规内容与面板采用 Level 0/1/2 扁平层级与 1px 微边框（`outlineVariant`），默认 `elevation = 0`，不添加弥散重阴影。
- 阴影（Elevation 2~4）仅允许用于对话框（Dialog）、浮层弹出菜单（Popup/Menu）、拖拽中元素（Dragging）与临时悬浮层（Transient Overlay）。

### 4. Card & List Policy
- 严禁出现无意义的多层 Card-in-Card 嵌套。
- 高密度数据结构优先采用统一容器与分割线模式（`Surface + Row + Divider`），仅在 Grid 模式下使用独立卡片。

### 5. Radius Token Scale
- 严格使用统一的 Developer Scale 设计令牌：
  - `radiusXs = 4.0` (行内标签、微状态点)
  - `radiusSmall = 6.0` (按钮、输入框、Tab 药丸、高亮选中态)
  - `radiusMedium = 8.0` (面板、控制区、标准卡片)
  - `radiusLarge = 12.0` (底部抽屉 BottomSheet、大卡片)
  - `radiusDialog = 16.0` (对话框)
  - `radiusPill = 999.0` (语义 Tag/Badge)
- 禁止重新引入 18 / 28 等大圆角作为普通控件装饰。

### 6. Color System
- Neutral-First 体系：90% 以上界面使用中性底色、中性 Surface、中性微边框与中性文字。
- Primary Accent 严格限制在：焦点框、选中态、主操作按钮与激活指示器。
- 语义色（Success/Warning/Error）仅表达真实系统状态，不作为装饰底色。

### 7. Adaptive Architecture
- **WindowSizeClass** 仅负责视口尺寸与信息布局（Row/Column、Master/Detail、Sidebar/Toolbar 展开程度、列数）。
- **Platform / Input Capability** (`isDesktopInputPlatform()`, `isTouchPlatform()`) 负责交互能力（鼠标 Hover、右键菜单、键盘快捷键、触控手势、触控目标）。
- 严禁将 `isDesktopLayout()`（即 `width >= 840`）作为假定操作系统或输入交互模式的唯一万能开关。
- 移动端 touch target 必须满足 >= 44~48 logical px（通过 `MaterialTapTargetSize.padded`、BoxConstraints 或 padding 保障）。

## 验证（代码变更）

`flutter analyze --no-pub`、`flutter test --no-pub` 及受影响的 Full App 回归；
local aggregate CI 仅按用户明确要求运行。
