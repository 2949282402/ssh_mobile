# 系统管理页与性能监控融合架构文档

> 最新更新时间：2026-07-26

本文记录当前“系统管理”控制台中的监控、快照和 root 管理架构。

- 状态：当前实现
- 更新日期：2026-07-17

---

## 1. 背景与目标

由于服务器“性能监控”（性能、CPU/Memory 采样、磁盘/健康快照、端口/服务快照）和“系统管理”（用户、会话、电源、systemd 服务控制、ss 端口管理）存在高频的功能交叉与 UI 重复。
合并之后，独立的“监控”主导航入口已删除，性能监控成为“系统管理”的第一个 Tab。Monitor 保留独立的多服务器采样状态；其余 Tab 共用单服务器选择和按需加载流程。

---

## 2. 状态与连接模型 (Selection vs Connection)

快照诊断（如查看端口/应用列表）和性能图表监控**不应要求 root 权限**，也**支持 Windows 服务器**。而系统管理操作（如增删用户、管理会话、开关机）**强依赖 Linux + root 权限**。

为了使这些 Tab 共存且不产生误伤，系统管理控制台实现了** UI 选择状态与 SSH Root 物理连接状态**的解耦：

*   **`PerformanceViewModel.selectedConnectionIds`（Monitor 多服务器选择）**
    *   **职责**：仅供 Monitor Tab 使用，支持 Linux/Windows 多服务器只读采样，不受系统管理单服务器选择影响。
*   **`SystemAdminViewModel.selectedConnectionId`（系统管理 UI 选中服务器 ID）**
    *   **职责**：供 Ports、Applications、Services、Users、Sessions 和 Power 六个 Tab 共用。快照读取和 root 管理入口均以此选择作为用户意图。
    *   **限制**：不要求 root，不要求 Linux，不需要提前建立 root 连接。允许用户选中非 root Linux 或 Windows 机器以只读形式查看快照数据。
*   **`SystemAdminViewModel.managementConnectionId`（Root SSH 物理连接 ID）**
    *   **职责**：代表 `SystemAdminService` 物理连接成功且通过 `id -u == 0`（即 root）校验的会话。用于 Users、Sessions、Power、Ports 管理模式、Services 管理模式。
    *   **限制**：强制要求 Linux + root。如果所选服务器非 root 或认证失败，此物理会话会断开或为 null，但 `selectedConnectionId` 不受影响。

root 管理连接必须跟随当前 `selectedConnectionId`，但连接建立或异步 Tab 激活不得反向改写选择。连接成功后也不得自动调用 `refreshAllData()`；当前 Tab 的激活逻辑负责按需加载。

---

## 3. 各 Tab 权限与模式切换规则

| Tab 索引 | Tab 名称 | 对应界面 | 权限规则 | 是否支持多选 | 模式与自动降级说明 |
| :--- | :--- | :--- | :--- | :--- | :--- |
| **Tab 0** | **监控** | 性能图表 / 健康度 / 告警 / 磁盘挂载 | **不要求 root**。支持 Windows/Linux | **是**（多选） | 独立由 `PerformanceViewModel` 进行全局多服务器采样。 |
| **Tab 1** | **监听端口** | ss 监听端口 / 快照列表 | **按模式划分** | 否（单选） | 1. 满足 Linux+root 时，默认使用**管理模式**（可查看 PID/Process 且切换模式）；<br>2. 否则自动降级为**快照模式**（由 non-root ss 命令获取并显示警告横幅）。提供“连接 Root”快捷键。 |
| **Tab 2** | **应用/进程** | 全局进程列表 / CPU 内存资源占用 | **不要求 root**。支持 Windows/Linux | 否（单选） | 仅提供**快照模式**（调用 `fetchApplications()` 展示）。非 Linux/Windows 均可加载。 |
| **Tab 3** | **系统服务** | systemd 服务管理 / 运行状态快照 | **按模式划分** | 否（单选） | 1. 满足 Linux+root 时，使用**管理模式**（可进行 start/stop/restart/enable/disable 操作）；<br>2. 否则降级为**快照模式**（无 Popup 操作菜单，仅显示状态，且非 Linux 不报错）。提供“连接 Root”快捷键。 |
| **Tab 4** | **用户账号** | Linux 用户管理 | **强制 Linux + root** | 否（单选） | 必须连接 root 成功方可加载。未连接显示 `_RootRequiredView` 拦截并提供“以 Root 连接”按钮。 |
| **Tab 5** | **活动会话** | `who` 当前登录会话 / 剔除会话 | **强制 Linux + root** | 否（单选） | 同上。必须 root 连接成功，用于剔除或监控活动终端会话。 |
| **Tab 6** | **系统电源** | 重启 / 关机电源菜单 | **强制 Linux + root** | 否（单选） | 同上。必须 root 连接成功，涉及开关机等危险管理指令。 |

---

## 4. 后续开发注意事项（防回归红线）

后续在系统管理或监控模块进行任何扩展时，必须遵循以下设计红线：

1.  **禁止在 snapshot 模式下依赖 `managementConnectionId` 或 `isConnected`。** 否则会直接破坏非 root 用户与 Windows 机器的快照诊断。快照视图应完全基于 `selectedConnectionId` 获取数据。
2.  **管理动作（如 `createUser`、`setUserSudo`、`manageSystemdService`、`rebootServer`）必须显式提取 `managementConnectionId` 进行安全性前置过滤。** 永远不要将这些写动作的目标直接绑定到 `selectedConnectionId`，以防用户在未成功建立 root 物理连接的选中状态下发出非预期的操作请求。
3.  **禁止在 Tab/Screen 的 `dispose()` 周期中停止全局监控服务。** `PerformanceMonitorService` 负责多服务器后台采样，其生命周期是全局的。采样定时器应一直静默运行或由用户在配置面板中点击“停止”才停止，否则切换 Tab 或退出系统管理控制台会导致前台和后台告警采样被中断。
4.  **在 Ports、Services、Applications Tab 中对比服务器切换时，必须在 `build()` 周期中使用本地状态变量（如 `_lastSelectedConnectionId`）进行连接 ID 的变更检测。** 不要依赖 `didUpdateWidget(oldWidget)` 比较 `viewModel.connectionId`，因为 viewModel 为同一对象引用时，该比较值总会相等导致重载失效。
5.  **不要恢复全局 Refresh All 操作。** 固定右上角刷新只在 Ports、Applications、Services、Users 和 Sessions Tab 出现，并且只刷新当前 Tab；Monitor 与 Power 不显示该操作。
6.  **单服务器快照不重复服务器摘要。** Ports、Applications 和 Services 已由共享服务器选择器表达目标，列表内容保持聚焦于当前资源。
