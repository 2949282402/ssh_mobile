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

### 2. Surface & Hierarchy Policy
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

### 3. Toolbar & Navigation Specification
- 类似 VS Code / JetBrains：高度统一（40~48dp）、小尺寸图标（16~18dp）、清晰分组、少量文字按钮。
- 移动端 Bottom Navigation 保持扁平无浮岛胶囊，无巨大圆角；桌面端 NavigationRail 紧贴工具栏风格，无浮动卡片与弥散阴影。

### 4. Empty State & Loading State
- 空状态（Empty State）：信息优先、小图标（24~28dp）、减少装饰、左对齐/居中紧凑布局，无大装饰图与巨型按钮。
- 加载状态（Loading State）：列表使用骨架行（`AppSkeletonRow` / `Bone`），操作使用行内进度（`AppInlineProgress`），页面初始化使用克制指示器（`AppLoadingIndicator`）。

### 5. Dialog & BottomSheet
- Desktop 对话框：Title -> Description -> [Cancel] [Confirm] 紧凑排列，`radiusMedium`（8px），无装饰性大 Icon 与弥散阴影。
- Mobile 弹出：统一采用标准 `BottomSheet`，带拖拽手柄并保持操作触控区。

### 6. Radius Token Scale
- 严格遵循统一的 Developer Scale 令牌：
  - `radiusXs = 4.0` (微状态点、行内微标签)
  - `radiusSmall = 6.0` (按钮、输入框、Tab 药丸、高亮选中态)
  - `radiusMedium = 8.0` (面板、控制区、标准卡片、对话框)
  - `radiusLarge = 12.0` (抽屉 BottomSheet、大容器)
  - `radiusDialog = 16.0` (大号对话框)
  - `radiusPill = 999.0` (状态 Tag/Badge)

### 7. Status Color Token
- 统一语义色彩契约（`AppStatusColors`）：
  - Success -> green (`0xFF10B981` / `0xFF34D399`)
  - Warning -> amber (`0xFFF59E0B` / `0xFFFBBF24`)
  - Error -> red (`0xFFEF4444` / `0xFFF87171`)
  - Info -> blue (`0xFF3B82F6` / `0xFF60A5FA`)
  - Neutral -> gray (`0xFF6B7280` / `0xFF9CA3AF`)
- 严禁各 Feature 自由硬编码私有状态颜色。

### 8. Animation Convergence
- 动效极简克制：快速（100~150ms）、平稳、低干扰。
- 禁止：页面 slide/bounce、Card stagger、无意义的晃动与过度渐变。
- 保留：基本的 hover 反馈、selection 切换与 loading 微光。

### 9. Adaptive Architecture & Touch Targets
- **WindowSizeClass** 负责视口尺寸自适应（Row/Column、Master/Detail、Sidebar/Toolbar 展开程度）。
- **Platform / Input Capability** 负责交互能力（鼠标 Hover、右键菜单、键盘快捷键、触控手势）。
- 移动端 touch target 严格满足 >= 44~48 logical px。

## 验证（代码变更）

`flutter analyze --no-pub`、`flutter test --no-pub` 及受影响的 Full App 回归；
local aggregate CI 仅按用户明确要求运行。
