# 应用启动按需初始化架构 (On-demand Startup Initialization Architecture)

> 最新更新时间：2026-07-26

## 概述
为了大幅提升应用冷启动速度，降低 CPU/内存占用并减少未访问功能引起的后台 I/O 和网络开销，应用采用了**按需初始化架构（On-demand Initialization Architecture）**。

## 架构要点

### 1. 核心 Bootstrap (`AppBootstrapCoordinator`)
- `main()` 仅初始化 `WidgetsFlutterBinding` 与 `AppLogService` 内存日志，并发起 `AppBootstrapCoordinator.ensureBootstrap()`。
- `AppBootstrapCoordinator` 仅装载核心偏好（语言、主题、色板、SFTP 限制等）与 `StorageService` 基础数据。
- 剥离 MCP Token 生成、LAN Identity 查找与平台设备名获取等耗时/平台通道 I/O，移至具体功能触发时处理。

### 2. ConnectionViewModel 与 SshService 解耦 (`ConnectionRuntimeActions`)
- `ConnectionViewModel` 构造函数仅依赖 `ConnectionRepository`。
- `SshService`、`SftpService`、`PerformanceMonitorService` 改为通过 `ConnectionRuntimeActions` 惰性工厂访问。
- `SshService` 构造函数保持轻量，不直接启动后台事件监听与 tmux 会话恢复；通过 `ensureInitialized()` 按需初始化。

### 3. Feature Scope 隔离
- `SftpFeatureScope` 和 `SystemAdminFeatureScope` 在页面路由层级为模块提供局部 ViewModel 作用域。
- 根级 `MultiProvider` 不再放置未访问页面的重型 ViewModel。
- 移除了 Home 页切换时 SFTP 对 `SystemAdminViewModel` 的跨模块强行读取。

### 4. LAN 后台接收器分离 (`LanReceiverCoordinator`)
- 提取 `LanReceiverCoordinator` 管理全局 HTTPS 接收端口、mDNS 广播及配对邀请处理，保持后台配对功能完备。
- `LanShareFeatureScope` 按需取得 Coordinator 持有的唯一共享 `LanShareViewModel`，主页面、全局配对路由与聊天路由复用同一底层运行时，不会重复绑定端口。
- `LanShareViewModel` 仅在用户进入 LAN Share 页面或收到配对邀请时创建，主动扫描与历史记录数据库 watch 不进入核心启动路径。

### 5. MCP 工具图惰性构造 (`LazyAiToolExecutor`)
- `McpServerController` 在已启用模式下自动监听端口，但注入 `LazyAiToolExecutor` 代理。
- 首次收到 `tools/list` 或 `tools/call` JSON-RPC 请求时，才首次触发全量 `AiToolService` 依赖图及底层服务的构造。

### 6. 条件生命周期与导入刷新
- 移除首帧后固定 900ms 的全局后台服务预热 Timer。
- 规范配置导入（Import）回调，等待所有已注册系统的异步刷新完成后才返回。
