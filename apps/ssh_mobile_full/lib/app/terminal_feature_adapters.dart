// Terminal Feature 的 App Shell 适配器集合。
//
// 这些适配器把旧 App Service 转换为 Terminal Package 的 Port。它们不创建
// SSH、数据库或全局单例；长期资源仍由 AppRuntime/TerminalModule 分别拥有。

import 'dart:async';

import 'package:app_core/app_core.dart';
import 'package:app_ui/app_ui.dart';
import 'package:feature_terminal/feature_terminal.dart' as feature_terminal;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssh_core/ssh_core.dart';

import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/shortcut_command_service.dart';
import '../services/ssh_service.dart';
import '../widgets/ssh_host_key_trust_dialog.dart';
import 'package:connection_core/connection_core.dart';

/// 将 AppSettings 暴露为 Terminal 的设置 Port。
final class AppTerminalSettingsAdapter extends ChangeNotifier
    implements feature_terminal.TerminalSettingsPort {
  /// 创建设置适配器并转发 AppSettings 的变更通知。
  AppTerminalSettingsAdapter(this._settings) {
    _settings.addListener(_forwardSettingsChanged);
  }

  final AppSettings _settings;
  bool _disposed = false;

  @override
  Object get language => _settings.language;

  @override
  bool get isDarkMode => _settings.isDarkMode;

  @override
  bool get oledDark => _settings.oledDark;

  @override
  String get terminalThemeId => _settings.terminalThemeId;

  @override
  String get terminalFontFamily => _settings.terminalFontFamily;

  @override
  void toggleTheme() {
    _settings.toggleTheme();
  }

  @override
  Future<void> setTerminalThemeId(String id) {
    return _settings.setTerminalThemeId(id);
  }

  @override
  Future<void> setTerminalFontFamily(String family) {
    return _settings.setTerminalFontFamily(family);
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settings.removeListener(_forwardSettingsChanged);
    super.dispose();
  }

  void _forwardSettingsChanged() {
    if (!_disposed) notifyListeners();
  }
}

/// 将旧快捷命令服务转换为 Terminal 的不可变命令 Port。
final class AppTerminalShortcutAdapter extends ChangeNotifier
    implements feature_terminal.TerminalShortcutPort {
  /// 创建快捷命令适配器并转发配置变更。
  AppTerminalShortcutAdapter(this._service) {
    _service.addListener(_forwardServiceChanged);
  }

  final ShortcutCommandService _service;
  bool _disposed = false;

  @override
  int get orderVersion => _service.orderVersion;

  @override
  List<feature_terminal.TerminalShortcutCommand> get customCommands =>
      _service.customCommands.map(_toCommand).toList(growable: false);

  @override
  List<String> get quickCommandIds => _service.quickCommandIds;

  @override
  List<feature_terminal.TerminalShortcutCommand> sortByUsage(
    List<feature_terminal.TerminalShortcutCommand> commands,
  ) {
    final legacyCommands = commands
        .map(
          (command) => ShortcutCommand(
            id: command.id,
            label: command.label,
            code: command.code,
            custom: command.custom,
          ),
        )
        .toList(growable: false);
    return _service
        .sortByUsage(legacyCommands)
        .map(_toCommand)
        .toList(growable: false);
  }

  @override
  Future<void> recordUse(String id) => _service.recordUse(id);

  @override
  Future<void> reorderCommands(List<String> ids) =>
      _service.reorderCommands(ids);

  @override
  Future<void> setQuickCommandIds(Iterable<String> ids) =>
      _service.setQuickCommandIds(ids);

  @override
  Future<void> resetQuickCommandIds() => _service.resetQuickCommandIds();

  @override
  Future<void> addCustomCommand(String label, String code) =>
      _service.addCustomCommand(label, code);

  @override
  Future<void> removeCustomCommand(String id) =>
      _service.removeCustomCommand(id);

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _service.removeListener(_forwardServiceChanged);
    super.dispose();
  }

  void _forwardServiceChanged() {
    if (!_disposed) notifyListeners();
  }

  feature_terminal.TerminalShortcutCommand _toCommand(ShortcutCommand command) {
    return feature_terminal.TerminalShortcutCommand(
      id: command.id,
      label: command.label,
      code: command.code,
      custom: command.custom,
    );
  }
}

/// 将旧连接和导航能力转换为 Terminal 的连接 Port。
final class AppTerminalConnectionAdapter
    implements feature_terminal.TerminalConnectionPort {
  /// 创建只持有短期 Navigator 引用的连接适配器。
  AppTerminalConnectionAdapter({
    required this.navigatorKey,
    required this.connectionRepository,
    required this.sshService,
  });

  final GlobalKey<NavigatorState> navigatorKey;
  final ConnectionRepository connectionRepository;
  final SshService sshService;

  @override
  feature_terminal.TerminalConnectionInfo? getConnection(String connectionId) {
    final config = connectionRepository.getConnection(connectionId);
    if (config == null) return null;
    return feature_terminal.TerminalConnectionInfo(
      id: config.id,
      name: config.name,
      host: config.host,
      port: config.port,
      username: config.username,
    );
  }

  @override
  String defaultDisplayNameForConnection(String connectionId) {
    return sshService.defaultDisplayNameForConnection(connectionId);
  }

  @override
  Future<String?> openSession(
    String connectionId, {
    String? displayName,
  }) async {
    final context = navigatorKey.currentContext;
    final sessionId = await sshService.openSession(
      connectionId,
      displayName: displayName,
      onUnknownHostKey: context == null
          ? null
          : (request) => showSshHostKeyTrustDialog(context, request),
    );
    return sessionId;
  }

  @override
  Future<void> openConnectionEditor(
    String connectionId, {
    bool isNew = false,
  }) async {
    final navigator = navigatorKey.currentState;
    if (navigator == null) return;
    await navigator.pushNamed(
      isNew ? '/add' : '/edit',
      arguments: isNew ? null : connectionId,
    );
  }
}

/// 将 AppLogService 暴露为 Terminal 的脱敏日志 Port。
final class AppTerminalLoggerAdapter
    implements feature_terminal.TerminalLoggerPort {
  /// 创建日志适配器。
  const AppTerminalLoggerAdapter(this.logger);

  /// App Scope 的日志 Owner。
  final AppLogService logger;

  @override
  void info(String message) {
    logger.info(message);
  }

  @override
  void warning(String message, {Object? error, StackTrace? stackTrace}) {
    logger.warning(
      message,
      details: error == null ? null : '$error\n$stackTrace',
    );
  }

  @override
  void error(String message, {Object? error, StackTrace? stackTrace}) {
    logger.error(message, error: error, stackTrace: stackTrace);
  }
}

/// Terminal History Repository 的 App Shell 转发层。
///
/// terminal.db 的生命周期和数据归属由 TerminalModule 管理；App Shell 只
/// 暴露 Feature Repository，不再维护第二份历史数据。
final class AppTerminalHistoryRepository
    implements feature_terminal.TerminalHistoryRepository {
  /// 创建不拥有底层 Repository 的转发适配器。
  const AppTerminalHistoryRepository(this._primary);

  final feature_terminal.TerminalHistoryRepository _primary;

  @override
  Future<List<feature_terminal.TerminalHistoryRecord>> loadRecords() =>
      _primary.loadRecords();

  @override
  Future<void> saveRecord(feature_terminal.TerminalHistoryRecord record) =>
      _primary.saveRecord(record);

  @override
  Future<void> removeRecord(String sessionId) =>
      _primary.removeRecord(sessionId);

  @override
  Future<void> replaceAll(
    Iterable<feature_terminal.TerminalHistoryRecord> records,
  ) {
    return _primary.replaceAll(records);
  }
}

/// Terminal Route 的 Module Scope；页面销毁时释放 terminal.db。
final class AppTerminalModuleScope extends StatefulWidget {
  /// 创建包级 Module 的路由边界。
  const AppTerminalModuleScope({
    super.key,
    required this.child,
    @visibleForTesting this.moduleFactory,
  });

  /// Module 完成初始化后要显示的页面。
  final Widget child;

  /// 可选的测试 Module 构造器；生产路由仍使用默认数据库实现。
  @visibleForTesting
  final feature_terminal.TerminalModule Function()? moduleFactory;

  @override
  State<AppTerminalModuleScope> createState() => _AppTerminalModuleScopeState();
}

final class _AppTerminalModuleScopeState extends State<AppTerminalModuleScope> {
  late final feature_terminal.TerminalModule _module;
  late final Future<void> _activation;
  feature_terminal.TerminalHistoryRepository? _historyRepository;

  @override
  void initState() {
    super.initState();
    _module = widget.moduleFactory?.call() ?? feature_terminal.TerminalModule();
    final manager = context.read<SshSessionManager>();
    _activation = _activate(manager);
  }

  Future<void> _activate(SshSessionManager manager) async {
    await _module.register(ModuleContext.fromMap({SshSessionManager: manager}));
    await _module.activate();
    _historyRepository = AppTerminalHistoryRepository(
      _module.historyRepository,
    );
  }

  @override
  void dispose() {
    unawaited(_module.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _activation,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Center(child: Text('Terminal module failed to initialize.')),
          );
        }
        if (snapshot.connectionState != ConnectionState.done ||
            _historyRepository == null) {
          final appSettings = context.read<AppSettings?>();
          final language = appSettings?.language ?? AppLanguage.en;
          final strings = AppStrings(language);
          return Scaffold(body: _TerminalModuleScopeSkeleton(strings: strings));
        }
        return Provider<feature_terminal.TerminalHistoryRepository>.value(
          value: _historyRepository!,
          child: widget.child,
        );
      },
    );
  }
}

class _TerminalModuleScopeSkeleton extends StatelessWidget {
  const _TerminalModuleScopeSkeleton({required this.strings});

  final AppStrings strings;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return AppSkeletonizer.zone(
      enabled: true,
      semanticsLabel: strings.terminalWindows,
      child: AppPageSurface(
        child: SafeArea(
          child: Column(
            children: [
              // Session Tabs Bar
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.terminal_rounded, size: 16),
                          SizedBox(width: 8),
                          Text(
                            'Session 1: bash',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          SizedBox(width: 6),
                          Icon(Icons.close_rounded, size: 14),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: colorScheme.surfaceContainerLowest,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusSmall,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.terminal_outlined,
                            size: 16,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'Session 2',
                            style: TextStyle(
                              fontSize: 12,
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Spacer(),
                    const Icon(Icons.add_rounded, size: 22),
                  ],
                ),
              ),
              const Divider(height: 1),

              // Terminal Screen Viewport
              Expanded(
                child: Container(
                  width: double.infinity,
                  color: Colors.black,
                  padding: const EdgeInsets.all(14),
                  child: const Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Connecting to production-host.internal:22...',
                        style: TextStyle(
                          color: Colors.white70,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        'Linux prod-node-01 6.8.0-generic #42-Ubuntu SMP x86_64',
                        style: TextStyle(
                          color: Colors.white70,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'admin@prod-node-01:~\$ systemctl status worker-pool',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: 4),
                      Text(
                        '● worker-pool.service - Background Task Dispatcher',
                        style: TextStyle(
                          color: Colors.white,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '     Loaded: loaded (/lib/systemd/system/worker-pool.service; enabled)',
                        style: TextStyle(
                          color: Colors.white60,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: 2),
                      Text(
                        '     Active: active (running) since Tue 2026-09-01 08:30:12 UTC',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                      SizedBox(height: 8),
                      Text(
                        'admin@prod-node-01:~\$ █',
                        style: TextStyle(
                          color: Colors.greenAccent,
                          fontFamily: 'monospace',
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // Bottom Accessory Bar
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  border: Border(
                    top: BorderSide(color: colorScheme.outlineVariant),
                  ),
                ),
                child: Row(
                  children: [
                    _buildAccessoryKey('ESC'),
                    _buildAccessoryKey('TAB'),
                    _buildAccessoryKey('CTRL'),
                    _buildAccessoryKey('ALT'),
                    const Spacer(),
                    const Icon(Icons.keyboard_arrow_up_rounded, size: 20),
                    const SizedBox(width: 8),
                    const Icon(Icons.keyboard_arrow_down_rounded, size: 20),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAccessoryKey(String label) {
    return Container(
      margin: const EdgeInsets.only(right: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.black26,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }
}
