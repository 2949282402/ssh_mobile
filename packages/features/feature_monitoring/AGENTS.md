最新更新时间：2026-08-24

# feature_monitoring 维护说明

本包负责服务器实时监控、健康评分、采样解析和监控工具契约。这里只保存实时
内存状态，不创建历史趋势数据库；App 通过公开 Port 注入 SSH exec、连接平台、
日志和后台服务能力。

监控采样由用户显式启动，不能在 App 启动时永久创建 polling Timer。Module 的
`deactivate` 和 `dispose` 必须取消 Timer、停止采样并解除监听。所有监控 SSH 请求
都标记为低优先级，不能占用交互 Terminal 的调度入口。

`MonitoringService` 只负责编排选择、Timer、SSH probe 和平台路由；采样历史、
累计计数、不可变派生视图和健康评分由 `MonitoringSampleStore` 独占，告警阈值、
五分钟去重和有界历史由 `MonitoringAlertEvaluator` 独占。不得在 Service 再建第二套
采样/告警缓存。

每轮 `startMonitoring` 必须捕获完整、不可变的目标集合和独立 epoch。停止、重启或
移除连接会使旧 epoch 失效；旧轮次不得继续 retry、记录 sample/error/alert、移除新轮次
的 sampling 标记或重启 Timer。

旧 `lib/services/performance_monitor_service.dart` 路径在迁移期间是兼容桥；新
代码应依赖 `package:feature_monitoring/feature_monitoring.dart` 的公共 API。

## Step29 标准字段

- 允许修改范围：监控模型、解析器、Ports、Module、Service、ViewModel 和测试。
- 禁止依赖：其他 Feature、旧统一存储、全局 SSH/Settings 实现或 App `/src/`。
- Public API 修改要求：同步 Monitoring Capability、App adapters、AI/System Admin 调用方和测试。
- 数据库约束：不创建 `monitoring.db`，采样历史保持在受限内存窗口。
- 资源释放规则：AppRuntime 拥有 Module；Module/Service 停止并释放采样 Timer、Stream 和订阅。
- 必须运行的测试：`dart format --output=none --set-exit-if-changed lib test`、`flutter analyze`、`flutter test`。
