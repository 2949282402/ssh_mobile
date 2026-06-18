import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../features/connection/models/connection.dart';
import '../features/connection/viewmodels/connection_viewmodel.dart';
import '../features/settings/viewmodels/settings_viewmodel.dart';
import '../features/system_admin/viewmodels/system_admin_viewmodel.dart';
import '../features/developer_log/viewmodels/developer_log_viewmodel.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../services/system_admin_service.dart';
import '../utils/responsive.dart';
import '../widgets/connection_progress_dialog.dart';
import '../widgets/overflow_scroll_text.dart';
import '../widgets/ssh_host_key_trust_dialog.dart';
import '../widgets/tactile_feedback.dart';
import '../widgets/window_name_dialog.dart';
import 'developer_log_screen.dart';
import 'llm_chat_screen.dart';
import 'sftp_screen.dart';
import 'system_admin_screen.dart';
import 'terminal_windows_screen.dart';
import '../services/performance_monitor_service.dart';

part 'home/home_settings_strings.dart';
part 'home/settings_panel.dart';
part 'home/server_list_pane.dart';

class HomeScreen extends StatefulWidget {
  final int initialIndex;

  // AI stays first in navigation, but launch still lands on Servers because
  // connection management is the app's operational home page.
  const HomeScreen({super.key, this.initialIndex = 1});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _aiPage = 0;
  static const int _serverPage = 1;
  static const int _sftpPage = 2;
  static const int _adminPage = 3;
  static const int _logPage = 4;
  static const int _firstPage = _aiPage;
  static const int _lastPage = _logPage;

  late final PageController _pageController;
  late int _selectedIndex;
  late int _settledIndex;
  final Set<String> _expandedConnectionWindowIds = {};
  bool _aiHistoryVisible = false;
  bool _serverSelectionMode = false;
  final Set<String> _selectedServerIds = {};

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex.clamp(_firstPage, _lastPage);
    _settledIndex = _selectedIndex;
    _pageController = PageController(initialPage: _selectedIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  void updateState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final desktop = isDesktopLayout(context);
    final settingsVm = context.watch<SettingsViewModel>();
    final isBusy = settingsVm.isImporting || settingsVm.isExporting;

    final content = NotificationListener<SwitchToAiTabNotification>(
      onNotification: (notification) {
        _switchPage(_aiPage);
        return true;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (desktop || notification.metrics.axis != Axis.horizontal) {
            return false;
          }
          return false;
        },
        child: PageView.builder(
          controller: _pageController,
          itemCount: _lastPage + 1,
          physics: const NeverScrollableScrollPhysics(),
          allowImplicitScrolling: false,
          onPageChanged: (index) {
            setState(() {
              _selectedIndex = index;
              _settledIndex = index;
            });
          },
          itemBuilder: (context, index) => _buildPage(context, index, strings),
        ),
      ),
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            desktop ? _buildDesktopShell(context, content, strings) : content,
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: 28,
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onHorizontalDragEnd: (details) {
                  if (details.primaryVelocity != null &&
                      details.primaryVelocity! > 300) {
                    _openSettings(context);
                  }
                },
                child: const SizedBox.expand(),
              ),
            ),
            if (isBusy)
              ColoredBox(
                color: Theme.of(context)
                    .colorScheme
                    .surface
                    .withValues(alpha: 0.72),
                child: _buildLoadingState(),
              ),
          ],
        ),
      ),
      floatingActionButton: _selectedIndex == _serverPage
          ? FloatingActionButton(
              onPressed: () => _addConnection(context),
              tooltip: strings.addConnection,
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar: desktop || _aiHistoryVisible
          ? null
          : _buildBottomNavigation(context, strings),
    );
  }

  Widget _buildDesktopShell(
    BuildContext context,
    Widget content,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final width = MediaQuery.sizeOf(context).width;
    final extended = width >= AppBreakpoints.wideDesktop;

    return Row(
      children: [
        NavigationRail(
          extended: extended,
          selectedIndex: _navigationIndex,
          onDestinationSelected: _switchNavigationPage,
          destinations: [
            NavigationRailDestination(
              icon: const Icon(Icons.smart_toy_outlined),
              selectedIcon: const Icon(Icons.smart_toy_rounded),
              label: Text(settingsLabelAi(context)),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.dns_outlined),
              selectedIcon: const Icon(Icons.dns_rounded),
              label: Text(strings.servers),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.folder_open_outlined),
              selectedIcon: const Icon(Icons.folder_open_rounded),
              label: Text(strings.sftp),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              selectedIcon: const Icon(Icons.admin_panel_settings_rounded),
              label: Text(strings.admin),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.terminal_outlined),
              selectedIcon: const Icon(Icons.terminal_rounded),
              label: Text(strings.switchToChinese == '中文' ? 'Log' : '日志'),
            ),
          ],
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: colorScheme.outlineVariant,
        ),
        Expanded(
          child: content,
        ),
      ],
    );
  }

  Widget _buildBottomNavigation(BuildContext context, AppStrings strings) {
    return NavigationBar(
      selectedIndex: _navigationIndex,
      onDestinationSelected: _switchNavigationPage,
      destinations: [
        NavigationDestination(
          icon: const Icon(Icons.smart_toy_outlined),
          selectedIcon: const Icon(Icons.smart_toy_rounded),
          label: settingsLabelAi(context),
        ),
        NavigationDestination(
          icon: const Icon(Icons.dns_outlined),
          selectedIcon: const Icon(Icons.dns_rounded),
          label: strings.servers,
        ),
        NavigationDestination(
          icon: const Icon(Icons.folder_open_outlined),
          selectedIcon: const Icon(Icons.folder_open_rounded),
          label: strings.sftp,
        ),
        NavigationDestination(
          icon: const Icon(Icons.admin_panel_settings_outlined),
          selectedIcon: const Icon(Icons.admin_panel_settings_rounded),
          label: strings.admin,
        ),
      ],
    );
  }

  int get _navigationIndex {
    if (_selectedIndex == _logPage) {
      return 4;
    }
    return _selectedIndex;
  }

  void _switchNavigationPage(int index) {
    if (index == 4) {
      _switchPage(_logPage);
    } else {
      _switchPage(index);
    }
  }

  void _switchPage(int index) {
    if (_selectedIndex == index) return;
    setState(() {
      _selectedIndex = index;
    });
    _pageController.jumpToPage(index);
  }

  String settingsLabelAi(BuildContext context) {
    return 'AI';
  }

  void _openSettings(BuildContext context) {
    final settings = context.read<AppSettings>();
    final strings = AppStrings(settings.language);
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => _SettingsPage(
          appTitle: strings.appTitle,
          onExport: () => _exportAppData(context, strings),
          onImport: () => _importAppData(context, strings),
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          const begin = Offset(-1.0, 0.0);
          const end = Offset.zero;
          const curve = Curves.easeOutCubic;
          var tween =
              Tween(begin: begin, end: end).chain(CurveTween(curve: curve));
          return SlideTransition(
            position: animation.drive(tween),
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 260),
      ),
    );
  }

  Widget _buildPage(
    BuildContext context,
    int index,
    AppStrings strings,
  ) {
    final active = _selectedIndex == index;
    return _pageShell(
      index,
      _DeferredNavPage(
        active: active,
        loading: _buildLoadingState(),
        keepAliveAfterFirstBuild: index == _aiPage,
        builder: (context) {
          switch (index) {
            case _aiPage:
              return LlmChatScreen(
                key: const PageStorageKey<String>('ai-chat-page'),
                active: _settledIndex == index,
                onHistoryVisibilityChanged: (visible) {
                  if (_aiHistoryVisible == visible) return;
                  setState(() => _aiHistoryVisible = visible);
                },
              );
            case _serverPage:
              return _buildServerPage(context, strings);
            case _sftpPage:
              return const SftpScreen();
            case _adminPage:
              return ChangeNotifierProvider(
                create: (context) => SystemAdminViewModel(
                  adminService: context.read<SystemAdminService>(),
                  storageService: context.read<StorageService>(),
                ),
                child: const SystemAdminScreen(),
              );
            case _logPage:
            default:
              return ChangeNotifierProvider(
                create: (context) => DeveloperLogViewModel(
                  logService: context.read<AppLogService>(),
                  appSettings: context.read<AppSettings>(),
                ),
                child: const DeveloperLogPage(),
              );
          }
        },
      ),
    );
  }

  Widget _pageShell(int index, Widget child) {
    return TickerMode(
      enabled: _selectedIndex == index || _settledIndex == index,
      child: RepaintBoundary(child: child),
    );
  }

  Future<void> _exportAppData(
    BuildContext context,
    AppStrings strings,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final settingsVm = context.read<SettingsViewModel>();
    try {
      final success = await settingsVm.exportAppData((fileName, bytes) async {
        return await FilePicker.saveFile(
          dialogTitle: strings.exportAppData,
          fileName: fileName,
          bytes: Uint8List.fromList(bytes),
        );
      });
      if (!context.mounted) return;
      if (success) {
        messenger.showSnackBar(
          SnackBar(content: Text(strings.exportComplete)),
        );
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.exportFailed(e))),
      );
    }
  }

  Future<void> _importAppData(
    BuildContext context,
    AppStrings strings,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.importAppData),
        content: Text(strings.importAppDataWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(strings.importAction),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final settingsVm = context.read<SettingsViewModel>();
    try {
      final success = await settingsVm.importAppData(() async {
        final result = await FilePicker.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['json'],
          withData: true,
        );
        if (result == null || result.files.isEmpty) return null;
        final bytes = result.files.single.bytes;
        if (bytes == null) {
          throw StateError('Unable to read selected file.');
        }
        return bytes;
      });
      if (!context.mounted) return;
      if (success) {
        messenger.showSnackBar(
          SnackBar(content: Text(strings.importComplete)),
        );
        _switchPage(_serverPage);
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.importFailed(e))),
      );
    }
  }

  Widget _buildLoadingState() {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
    );
  }
}

class _DeferredNavPage extends StatefulWidget {
  final bool active;
  final Widget loading;
  final WidgetBuilder builder;
  final bool keepAliveAfterFirstBuild;

  const _DeferredNavPage({
    required this.active,
    required this.loading,
    required this.builder,
    this.keepAliveAfterFirstBuild = false,
  });

  @override
  State<_DeferredNavPage> createState() => _DeferredNavPageState();
}

class _DeferredNavPageState extends State<_DeferredNavPage> {
  bool _ready = false;
  bool _activationScheduled = false;

  @override
  void initState() {
    super.initState();
    if (widget.active) _scheduleActivation();
  }

  @override
  void didUpdateWidget(covariant _DeferredNavPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.active) {
      if (widget.keepAliveAfterFirstBuild && _ready) return;
      if (_ready || _activationScheduled) {
        _ready = false;
        _activationScheduled = false;
      }
      return;
    }
    if (!oldWidget.active || !_ready) {
      _scheduleActivation();
    }
  }

  void _scheduleActivation() {
    if (_ready || _activationScheduled) return;
    _activationScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      if (!mounted || !widget.active) return;
      setState(() {
        _activationScheduled = false;
        _ready = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.keepAliveAfterFirstBuild && _ready) {
      return Offstage(
        offstage: !widget.active,
        child: TickerMode(
          enabled: widget.active,
          child: Builder(builder: widget.builder),
        ),
      );
    }

    if (!widget.active) {
      return const SizedBox.expand();
    }
    if (!_ready) {
      _scheduleActivation();
      return widget.loading;
    }
    return widget.builder(context);
  }
}

class _ServerHeaderSnapshot {
  final int activeCount;
  final int windowCount;

  const _ServerHeaderSnapshot({
    required this.activeCount,
    required this.windowCount,
  });

  factory _ServerHeaderSnapshot.from(
    SshServerOverviewSnapshot sessions,
    List<ConnectionConfig> connections,
  ) {
    var activeCount = 0;
    for (final connection in connections) {
      if (sessions.forConnection(connection.id).hasConnected) {
        activeCount++;
      }
    }
    return _ServerHeaderSnapshot(
      activeCount: activeCount,
      windowCount: sessions.windowCount,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _ServerHeaderSnapshot &&
        other.activeCount == activeCount &&
        other.windowCount == windowCount;
  }

  @override
  int get hashCode => Object.hash(activeCount, windowCount);
}

class SwitchToAiTabNotification extends Notification {
  const SwitchToAiTabNotification();
}
