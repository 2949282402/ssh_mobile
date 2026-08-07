/// 旧 Feature 导出入口。
///
/// Connection 领域模型已经归属到 [connection_core]。保留这个转导出文件，
/// 让当前尚未迁移的 Screen、ViewModel 和测试可以逐步切换，而不在本 Step
/// 同时改动 UI 目录结构或业务流程。
library;

export 'package:connection_core/connection_core.dart'
    show
        AuthMethod,
        ConnectionConfig,
        ConnectionProfile,
        ServerPlatform,
        TerminalLaunchMode;
