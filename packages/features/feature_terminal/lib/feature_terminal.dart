// Terminal Feature 的唯一公共入口；调用方不得导入本包 lib/src。
library;

import 'package:app_core/app_core.dart';
import 'package:flutter/widgets.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:ssh_core/ssh_core.dart';

import 'src/domain/terminal_ports.dart';

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

/// Terminal Feature 的最小 Provider 组合边界。
///
/// App Shell 只负责提供 App Scope 实例和 Port；Provider 的具体组合由
/// Feature 自己拥有，避免精简 App 为了使用页面而反向依赖 Provider 实现。
final class TerminalFeatureScope extends StatelessWidget {
  /// 创建一个注入 Terminal 页面所需公共能力的 Scope。
  const TerminalFeatureScope({
    super.key,
    required this.sshSessionManager,
    required this.settings,
    required this.shortcuts,
    required this.connections,
    required this.logger,
    required this.historyRepository,
    required this.child,
  });

  /// App Scope SSH Manager；Scope 不拥有它的生命周期。
  final SshSessionManager sshSessionManager;

  /// Terminal 设置 Port；资源 Owner 由 App Shell 保持。
  final TerminalSettingsPort settings;

  /// 快捷命令 Port；资源 Owner 由 App Shell 保持。
  final TerminalShortcutPort shortcuts;

  /// 连接和会话导航 Port。
  final TerminalConnectionPort connections;

  /// 脱敏日志 Port。
  final TerminalLoggerPort logger;

  /// Terminal Module 提供的历史 Repository。
  final TerminalHistoryRepository historyRepository;

  /// Scope 内的页面内容。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: <SingleChildWidget>[
        Provider<SshSessionManager>.value(value: sshSessionManager),
        ListenableProvider<TerminalSettingsPort>.value(value: settings),
        ListenableProvider<TerminalShortcutPort>.value(value: shortcuts),
        Provider<TerminalConnectionPort>.value(value: connections),
        Provider<TerminalLoggerPort>.value(value: logger),
        Provider<TerminalHistoryRepository>.value(value: historyRepository),
      ],
      child: child,
    );
  }
}

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
