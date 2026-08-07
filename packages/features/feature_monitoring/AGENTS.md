最新更新时间：2026-08-08

# feature_monitoring 维护说明

本包负责服务器实时监控、健康评分、采样解析和监控工具契约。这里只保存实时
内存状态，不创建历史趋势数据库；App 通过公开 Port 注入 SSH exec、连接平台、
日志和后台服务能力。

监控采样由用户显式启动，不能在 App 启动时永久创建 polling Timer。Module 的
`deactivate` 和 `dispose` 必须取消 Timer、停止采样并解除监听。所有监控 SSH 请求
都标记为低优先级，不能占用交互 Terminal 的调度入口。

旧 `lib/services/performance_monitor_service.dart` 路径在迁移期间是兼容桥；新
代码应依赖 `package:feature_monitoring/feature_monitoring.dart` 的公共 API。
