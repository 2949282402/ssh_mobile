最新更新时间：2026-08-08

# feature_terminal

`feature_terminal` 持有终端会话页面、终端交互 ViewModel、终端历史模型和
独立 `terminal.db`。SSH 通过注入的 `ssh_core.SshSessionManager` 获取，禁止
在本包创建 `SshService`、`SshSessionManagerImpl` 或新的全局连接 Owner。

Package 外部只能从 `lib/feature_terminal.dart` 使用公共 API，不得引用
`lib/src/`。文案、设置、快捷命令、连接信息和日志通过本包定义的 Port 注入，
避免 Feature 反向依赖 App Shell 或其他 Feature。

Terminal 页面使用 Route Scope 创建 ViewModel；页面销毁时必须释放订阅、Timer、
Controller 和 SSH 相关监听。`TerminalModule` 独占自己的数据库和 Repository，
关闭时必须先停止活跃资源，再关闭数据库。

终端原始输出历史服务位于 `lib/src/data/`，不直接访问 App 的数据保护、日志或路径
服务；这些能力通过 Port 注入。当前 App Shell 的兼容 facade 负责提供旧实现所需的
平台适配，并由 SSH Owner 在关闭时调用 `dispose`，避免输出写入队列和文件句柄泄漏。
