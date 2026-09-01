最新更新时间：2026-09-01

# app_ui 维护约束

- 共享 UI 只从 `lib/app_ui.dart` 暴露；不引入 Feature、SSH、网络、数据库或
  App Service，业务数据由调用方转成 Widget 参数。新 Widget 说明职责，并在
  State `dispose` 释放 Animation/Scroll 等 Controller。
- 主题组合入口与控件构建器可分文件，但不得为行数阈值机械拆分连贯样式。
- Contract：允许共享主题、响应式指标、无业务 Widget、测试和文档；不拥有
  数据库或后台资源。Public API、调用方和视觉测试同步变更。

## Design System 设计规范与约束

### 1. Visual Language & Workspace Standard
- 整体 UI 风格标准：
  - `professional`（专业严谨）
  - `quiet`（克制沉静）
  - `dense`（高信息密度）
  - `technical`（工程技术质感）
  - `content-first`（内容与数据优先）
- 严禁（Forbidden）：
  - `gradient`（禁止无意义的背景与控件装饰渐变）
  - `glass effect`（禁止毛玻璃、拟物化模糊或浮夸滤镜）
  - `excessive shadow`（禁止弥散性大阴影与发光效果）
  - `huge radius`（禁止 18px / 26px / 28px 等非规范大圆角）
  - `floating card stack`（禁止无意义的多层卡片嵌套与浮岛堆叠）

### 2. Typography Policy
- 严禁（Forbidden）：
  - 页面与组件内自由定义随机 `fontSize` 或随意指定 `fontWeight` 导致风格漂移。
- 必须遵循（Required）：
  - 使用统一 `AppTypography` / `context.typography` 令牌：
    - `pageTitle`（fontSize: 20, weight: w600）
    - `sectionTitle`（fontSize: 15, weight: w600）
    - `body`（fontSize: 14, weight: w400）
    - `bodyMedium`（fontSize: 13, weight: w500）
    - `metadata`（fontSize: 12, weight: w400）
    - `caption`（fontSize: 11, weight: w400）
    - `code`（fontSize: 13, monospace）
    - `codeSmall`（fontSize: 11, monospace）
    - `button`（fontSize: 13, weight: w500）

### 3. Spacing Policy
- 严禁（Forbidden）：
  - 随意硬编码魔法间距数字（如 padding 13、margin 17、gap 22 等）。
- 必须遵循（Required）：
  - 使用统一 `AppSpacing` / `context.spacing` 令牌与预设间距：
    - `xs = 4.0`
    - `sm = 8.0`
    - `md = 12.0`
    - `lg = 16.0`
    - `xl = 24.0`
    - `xxl = 32.0`
    - 预设 `AppSpacing.insetsSm`, `insetsMd`, `insetsLg`, `vGapSm`, `hGapSm` 等。

### 4. Component Policy
- Feature 页面严禁直接自定义创建非受控的浮岛 Card、私有 Dialog、私有 Loading 或私有 EmptyState 插画。
- 必须统一采用 `app_ui` 标准组件体系：
  - **Surface**: `AppPageSurface`（页面主容器）、`AppContentSurface`（内容承载容器）、`AppSurface`。
  - **Toolbar**: `AppToolbar`（40~48dp 标准高）、`AppToolbarAction`（16~18dp 紧凑操作）、`AppToolbarGroup`（分组与分割线）。
  - **EmptyState**: `AppEmptyState`（信息优先、24~28dp 紧凑小图标、无巨型按钮或插画）。
  - **Loading**: `AppLoadingIndicator`（克制微型加载器）、`AppInlineProgress`（行内紧凑进度条）、`AppSkeletonizer` / `AppSkeletonRow`（骨架屏）。
  - **Dialog & BottomSheet**: `AppDialog`（标准对话框容器）、`AppConfirmDialog`（操作确认）、`AppErrorDialog`（错误反馈）、`AppBottomSheet`（移动端标准半屏弹窗）。

### 5. Surface & Hierarchy Policy
- 统一页面层级结构：
  ```text
  Page Surface
   ├─ Header / Toolbar
   └─ Content Surface
         ├─ Row
         ├─ Divider
         └─ Row
  ```
- 禁止 `Card -> Card -> Container -> Card` 的无节制嵌套。
- 高密度 Developer Tool 列表优先采用 `Surface + Row + Divider` 结构，仅在网格视图（Grid）下使用平铺卡片。

### 6. Toolbar & Navigation Specification
- 类似 VS Code / JetBrains：高度统一（40~48dp）、小尺寸图标（16~18dp）、清晰分组、少量文字按钮。
- 移动端 Bottom Navigation 保持扁平无浮岛胶囊，无巨大圆角；桌面端 NavigationRail 紧贴工具栏风格，无浮动卡片与弥散阴影。

### 7. Radius Token Scale
- 严格遵循统一的 Developer Scale 令牌：
  - `radiusXs = 4.0` (微状态点、行内微标签)
  - `radiusSmall = 6.0` (按钮、输入框、Tab 药丸、高亮选中态)
  - `radiusMedium = 8.0` (面板、控制区、标准卡片、对话框)
  - `radiusLarge = 12.0` (抽屉 BottomSheet、大容器)
  - `radiusDialog = 16.0` (大号对话框)
  - `radiusPill = 999.0` (状态 Tag/Badge)

### 8. Status Color Token
- 统一语义色彩契约（`AppStatusColors`）：
  - Success -> green (`0xFF10B981` / `0xFF34D399`)
  - Warning -> amber (`0xFFF59E0B` / `0xFFFBBF24`)
  - Error -> red (`0xFFEF4444` / `0xFFF87171`)
  - Info -> blue (`0xFF3B82F6` / `0xFF60A5FA`)
  - Neutral -> gray (`0xFF6B7280` / `0xFF9CA3AF`)
- 严禁各 Feature 自由硬编码私有状态颜色。

### 9. Animation Convergence
- 动效极简克制：快速（100~150ms）、平稳、低干扰。
- 禁止：页面 slide/bounce、Card stagger、无意义的晃动与过度渐变。
- 保留：基本的 hover 反馈、selection 切换与 loading 微光。

### 10. Adaptive Architecture & Touch Targets
- **WindowSizeClass** 负责视口尺寸自适应（Row/Column、Master/Detail、Sidebar/Toolbar 展开程度）。
- **Platform / Input Capability** 负责交互能力（鼠标 Hover、右键菜单、键盘快捷键、触控手势）。
- 移动端 touch target 严格满足 >= 44~48 logical px。

## 验证（代码变更）

`flutter analyze --no-pub`、`flutter test --no-pub` 及受影响的 Full App 回归；
local aggregate CI 仅按用户明确要求运行。
