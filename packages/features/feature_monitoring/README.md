最新更新时间：2026-08-09

# feature_monitoring

服务器实时监控 Feature Package，包含 Linux/Windows 采样解析、健康评分、告警、
端口/进程/服务查询和监控工具适配器。

## 边界

- `lib/src/domain`：监控模型、解析器和 App/SSH Port；
- `lib/src/application`：监控服务、Module、ViewModel 和工具适配器；
- 不创建 `monitoring.db`，实时采样只保存在服务内存窗口；
- 不依赖统一存储门面、`SshService`、`AppSettings` 或其他 Feature 实现。

App Shell 负责把现有 SSH、连接目录、日志和后台服务适配到公开 Port。旧根目录
实现暂时保留委托桥，保证迁移期间既有 AI、Home、System Admin 和测试调用点的
行为不变。
