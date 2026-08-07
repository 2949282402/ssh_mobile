/// Connection Feature 的唯一公共入口。
///
/// App 和其他模块只能通过这里取得 ViewModel、页面和 Capability Contract，
/// 避免跨 Package 依赖 `src/` 实现细节。
library;

export 'package:connection_core/connection_core.dart'
    show
        AuthMethod,
        ConnectionConfig,
        ConnectionProfile,
        ServerPlatform,
        TerminalLaunchMode;
export 'src/application/connection_ports.dart';
export 'src/application/connection_view_model.dart';
export 'src/presentation/add_edit_screen.dart';
export 'src/presentation/connection_strings.dart';
