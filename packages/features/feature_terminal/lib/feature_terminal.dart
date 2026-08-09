// Terminal Feature 的唯一公共入口；调用方不得导入本包 lib/src。
library;

import 'package:app_core/app_core.dart';

export 'src/application/terminal_history_viewmodel.dart';
export 'src/application/terminal_module.dart';
export 'src/application/terminal_session_viewmodel.dart';
export 'src/application/terminal_windows_viewmodel.dart';
export 'src/data/database/terminal_database.dart';
export 'src/data/repository/drift_terminal_history_repository.dart';
export 'src/data/terminal_history_service.dart';
export 'src/domain/terminal_models.dart';
export 'src/domain/terminal_keyboard_models.dart';
export 'src/domain/terminal_ports.dart';
export 'src/domain/terminal_secret_policy.dart';
export 'src/domain/terminal_strings.dart';
export 'src/presentation/terminal_app_bar.dart';
export 'src/presentation/terminal_connection_overlay.dart';
export 'src/presentation/terminal_copy_screen.dart';
export 'src/presentation/terminal_history_screen.dart';
export 'src/presentation/terminal_screen.dart';
export 'src/presentation/terminal_settings_screen.dart';
export 'src/presentation/terminal_shortcut_panel.dart';
export 'src/presentation/terminal_view_area.dart';
export 'src/presentation/terminal_windows_screen.dart';
export 'src/presentation/widgets/terminal_custom_keyboard.dart';

/// Terminal Feature 对外公布的稳定路由名称。
abstract final class TerminalRouteNames {
  /// 单会话终端页面。
  static const terminal = '/terminal';

  /// 终端历史页面。
  static const history = '/history';

  /// 多窗口终端页面。
  static const windows = '/terminal-windows';
}

/// Terminal Feature 的路由元数据贡献；App Shell 负责解释页面构建。
final List<ModuleRouteContribution> terminalRouteContributions =
    List.unmodifiable([
      ModuleRouteContribution(routeName: TerminalRouteNames.terminal),
      ModuleRouteContribution(routeName: TerminalRouteNames.history),
      ModuleRouteContribution(routeName: TerminalRouteNames.windows),
    ]);
