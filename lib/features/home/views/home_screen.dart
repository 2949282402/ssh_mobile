import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/connection/viewmodels/connection_viewmodel.dart';
import 'package:ssh_mobile/features/settings/viewmodels/settings_viewmodel.dart';
import 'package:ssh_mobile/features/system_admin/viewmodels/system_admin_viewmodel.dart';
import 'package:ssh_mobile/features/sftp/viewmodels/sftp_viewmodel.dart';
import 'package:ssh_mobile/features/developer_log/viewmodels/developer_log_viewmodel.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/ssh_service.dart';
import 'package:ssh_mobile/utils/responsive.dart';
import 'package:ssh_mobile/widgets/connection_progress_dialog.dart';
import 'package:ssh_mobile/widgets/overflow_scroll_text.dart';
import 'package:ssh_mobile/widgets/ssh_host_key_trust_dialog.dart';
import 'package:ssh_mobile/widgets/tactile_feedback.dart';
import 'package:ssh_mobile/widgets/window_name_dialog.dart';
import 'package:ssh_mobile/widgets/app_surface.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:shadcn_ui/shadcn_ui.dart';
import 'package:ssh_mobile/features/developer_log/views/developer_log_screen.dart';
import 'package:ssh_mobile/features/ai_chat/views/llm_chat_screen.dart';
import 'package:ssh_mobile/features/sftp/views/sftp_screen.dart';
import 'package:ssh_mobile/features/system_admin/views/system_admin_screen.dart';
import 'package:ssh_mobile/features/terminal/views/terminal_windows_screen.dart';
import 'package:ssh_mobile/services/performance_monitor_service.dart';
import 'package:ssh_mobile/services/mcp/mcp_port_probe.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_controller.dart';
import 'package:ssh_mobile/services/mcp/mcp_server_settings.dart';
import 'package:ssh_mobile/features/home/views/widgets/home_navigation_semantics.dart';

part 'widgets/home_settings_strings.dart';
part 'widgets/settings_panel.dart';
part 'widgets/settings_sections.dart';
part 'widgets/server_list_pane.dart';
part 'widgets/server_connection_widgets.dart';

class HomeScreen extends StatefulWidget {
  final int initialIndex;

  // Servers stays first in navigation. App launch lands on Servers.
  const HomeScreen({super.key, this.initialIndex = 0});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _serverPage = 0;
  static const int _sftpPage = 1;
  static const int _aiPage = 2;
  static const int _adminPage = 3;
  static const int _logPage = 4;
  static const int _firstPage = _serverPage;
  static const int _lastPage = _logPage;

  late final PageController _pageController;
  late int _selectedIndex;
  late int _settledIndex;
  bool? _usesDesktopShell;
  bool _aiHistoryVisible = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final usesDesktopShell = isDesktopLayout(context);
    final shellChanged =
        _usesDesktopShell != null && _usesDesktopShell != usesDesktopShell;
    _usesDesktopShell = usesDesktopShell;
    if (!shellChanged) return;

    // The navigation rail changes the PageView viewport width. Re-align its
    // pixel offset after a phone rotates across the desktop breakpoint so the
    // selected page does not land in the gap between two pages.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pageController.hasClients) return;
      _pageController.jumpToPage(_selectedIndex);
    });
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
    final isBusy = context.select<SettingsViewModel, bool>(
      (vm) => vm.isImporting || vm.isExporting,
    );
    final hasConnections = context.select<ConnectionViewModel, bool>(
      (vm) => vm.connections.isNotEmpty,
    );

    final content = NotificationListener<OpenSettingsNotification>(
      onNotification: (notification) {
        _openSettings(context);
        return true;
      },
      child: NotificationListener<SwitchToAiTabNotification>(
        onNotification: (notification) {
          _switchPage(_aiPage);
          return true;
        },
        child: NotificationListener<ScrollNotification>(
          onNotification: (notification) {
            if (desktop || notification.metrics.axis != Axis.horizontal) {
              return false;
            }

            // Check for horizontal overscroll (left-to-right at start, or right-to-left at end)
            final double overscrollAmount;
            if (notification is OverscrollNotification) {
              overscrollAmount = notification.overscroll;
            } else {
              final metrics = notification.metrics;
              if (metrics.pixels < 0.0) {
                overscrollAmount = metrics.pixels;
              } else if (metrics.pixels > metrics.maxScrollExtent) {
                overscrollAmount = metrics.pixels - metrics.maxScrollExtent;
              } else {
                overscrollAmount = 0.0;
              }
            }

            if (overscrollAmount < -20.0) {
              if (_selectedIndex == _serverPage && notification.depth == 0) {
                Future.microtask(() {
                  if (context.mounted) _openSettings(context);
                });
                return true;
              } else if (_selectedIndex == _adminPage &&
                  notification.depth > 0) {
                // Swipe left-to-right on first tab (Monitor) -> switch to AI Chat
                Future.microtask(() {
                  if (context.mounted) _switchPage(_aiPage);
                });
                return true;
              }
            } else if (overscrollAmount > 20.0) {
              if (_selectedIndex == _adminPage && notification.depth > 0) {
                // Swipe right-to-left on last tab (System Power) -> switch to Logs
                Future.microtask(() {
                  if (context.mounted) _switchPage(_logPage);
                });
                return true;
              }
            }
            return false;
          },
          child: PageView.builder(
            controller: _pageController,
            itemCount: _lastPage + 1,
            physics: _selectedIndex == _adminPage
                ? const NeverScrollableScrollPhysics()
                : const BouncingScrollPhysics(),
            allowImplicitScrolling: false,
            onPageChanged: (index) {
              if (_selectedIndex != index) {
                setState(() {
                  _selectedIndex = index;
                  _settledIndex = index;
                });
                _onPageActive(index);
              }
            },
            itemBuilder: (context, index) =>
                _buildPage(context, index, strings),
          ),
        ),
      ),
    );

    return Scaffold(
      key: _scaffoldKey,
      extendBody: !desktop,
      drawer: _buildSettingsDrawer(context, strings),
      drawerEnableOpenDragGesture: _selectedIndex == _serverPage,
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            desktop ? _buildDesktopShell(context, content, strings) : content,
            if (isBusy)
              ColoredBox(
                color: Theme.of(
                  context,
                ).colorScheme.surface.withValues(alpha: 0.72),
                child: _buildLoadingState(),
              ),
          ],
        ),
      ),
      floatingActionButton:
          _selectedIndex == _serverPage && !desktop && hasConnections
          ? FloatingActionButton(
              onPressed: () => Navigator.pushNamed(context, '/add'),
              tooltip: strings.addConnection,
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar:
          desktop || (_selectedIndex == _aiPage && _aiHistoryVisible)
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
    final size = MediaQuery.sizeOf(context);
    final width = size.width;
    final extended = width >= AppBreakpoints.wideDesktop;
    final compactHeight = usesCompactRailForHeight(size.height);
    final railMargin = compactHeight
        ? const EdgeInsets.fromLTRB(8, 6, 0, 6)
        : const EdgeInsets.fromLTRB(12, 12, 0, 12);

    final settingsButton = IconButton(
      tooltip: strings.settings,
      icon: const Icon(Icons.settings_outlined),
      style: IconButton.styleFrom(
        minimumSize: const Size.square(44),
        foregroundColor: colorScheme.primary,
        backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
      ),
      onPressed: () => _openSettings(context),
    );

    return Row(
      children: [
        Container(
          margin: railMargin,
          decoration: BoxDecoration(
            color: colorScheme.surface.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
            border: Border.all(
              color: colorScheme.outline.withValues(alpha: 0.72),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(
                  alpha: Theme.of(context).brightness == Brightness.dark
                      ? 0.20
                      : 0.045,
                ),
                blurRadius: 26,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: NavigationRail(
            backgroundColor: Colors.transparent,
            extended: extended,
            labelType: extended
                ? null
                : compactHeight
                ? NavigationRailLabelType.none
                : NavigationRailLabelType.all,
            selectedIndex: _navigationIndex,
            onDestinationSelected: _switchNavigationPage,
            leading: compactHeight
                ? const SizedBox(height: 4)
                : _buildRailBrand(context, extended),
            trailing: compactHeight
                ? Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: settingsButton,
                  )
                : Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: settingsButton,
                      ),
                    ),
                  ),
            destinations: [
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
                icon: const Icon(Icons.auto_awesome_outlined),
                selectedIcon: const Icon(Icons.auto_awesome_rounded),
                label: _buildAiLabel(context, _selectedIndex == _aiPage),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.monitor_heart_outlined),
                selectedIcon: const Icon(Icons.monitor_heart_rounded),
                label: Text(strings.admin),
              ),
              NavigationRailDestination(
                icon: const Icon(Icons.article_outlined),
                selectedIcon: const Icon(Icons.article_rounded),
                label: Text(strings.logs),
              ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildRailBrand(BuildContext context, bool extended) {
    final colors = Theme.of(context).colorScheme;
    final mark = Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [colors.primary, colors.tertiary],
        ),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: colors.primary.withValues(alpha: 0.22),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      alignment: Alignment.center,
      child: const Icon(Icons.terminal_rounded, color: Colors.white, size: 23),
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 18),
      child: extended
          ? Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                mark,
                const SizedBox(width: 12),
                const Flexible(
                  child: Text(
                    'SSH Mobile',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                ),
              ],
            )
          : mark,
    );
  }

  Widget _buildBottomNavigation(BuildContext context, AppStrings strings) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final mobileMetrics = mobileUiMetricsOf(context);

    return SafeArea(
      top: false,
      minimum: EdgeInsets.fromLTRB(
        mobileMetrics.navigationHorizontalInset,
        0,
        mobileMetrics.navigationHorizontalInset,
        mobileMetrics.navigationBottomInset,
      ),
      child: Container(
        height: mobileMetrics.navigationHeight,
        decoration: BoxDecoration(
          color: colorScheme.surface.withValues(alpha: isDark ? 0.94 : 0.97),
          borderRadius: BorderRadius.circular(AppTheme.radiusLarge),
          border: Border.all(
            color: colorScheme.outline.withValues(alpha: 0.76),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isDark ? 0.28 : 0.10),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: Row(
          children: [
            _buildNavItem(
              context: context,
              mobileMetrics: mobileMetrics,
              icon: const Icon(Icons.dns_outlined),
              selectedIcon: const Icon(Icons.dns_rounded),
              label: strings.servers,
              index: _serverPage,
            ),
            _buildNavItem(
              context: context,
              mobileMetrics: mobileMetrics,
              icon: const Icon(Icons.folder_open_outlined),
              selectedIcon: const Icon(Icons.folder_open_rounded),
              label: strings.sftp,
              index: _sftpPage,
            ),
            _buildNavItem(
              context: context,
              mobileMetrics: mobileMetrics,
              icon: const Icon(Icons.auto_awesome_outlined),
              selectedIcon: const Icon(Icons.auto_awesome_rounded),
              label: 'AI',
              index: _aiPage,
            ),
            _buildNavItem(
              context: context,
              mobileMetrics: mobileMetrics,
              icon: const Icon(Icons.monitor_heart_outlined),
              selectedIcon: const Icon(Icons.monitor_heart_rounded),
              label: strings.admin,
              index: _adminPage,
            ),
            _buildNavItem(
              context: context,
              mobileMetrics: mobileMetrics,
              icon: const Icon(Icons.article_outlined),
              selectedIcon: const Icon(Icons.article_rounded),
              label: strings.logs,
              index: _logPage,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required BuildContext context,
    required MobileUiMetrics mobileMetrics,
    required Widget icon,
    required Widget selectedIcon,
    required String label,
    required int index,
  }) {
    final isSelected = _selectedIndex == index;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Expanded(
      child: HomeNavigationSemantics(
        semanticsKey: ValueKey<String>('home-nav-$index'),
        label: label,
        selected: isSelected,
        onTap: () => _switchNavigationPage(index),
        child: TactileFeedback(
          onTap: () => _switchNavigationPage(index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      curve: Curves.easeOutCubic,
                      width: mobileMetrics.navigationIndicatorWidth,
                      height: mobileMetrics.navigationIndicatorHeight,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colorScheme.primary.withValues(alpha: 0.12)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(
                          AppTheme.radiusPill,
                        ),
                      ),
                    ),
                    IconTheme(
                      data: IconThemeData(
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        size: mobileMetrics.navigationIconSize,
                      ),
                      child: isSelected ? selectedIcon : icon,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 1),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  fontSize: mobileMetrics.navigationLabelSize,
                  fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                  letterSpacing: 0,
                ),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAiLabel(BuildContext context, bool isSelected) {
    return const Text('AI');
  }

  int get _navigationIndex {
    return _selectedIndex;
  }

  void _switchNavigationPage(int index) {
    _switchPage(index);
  }

  String? _lastSynchronizedAdminConnectionId;

  void _switchPage(int index) {
    if (_selectedIndex == index) return;
    setState(() {
      _selectedIndex = index;
      _settledIndex = index;
    });
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
    );
    _onPageActive(index);
  }

  void _onPageActive(int index) {
    if (index == _sftpPage) {
      final adminVm = context.read<SystemAdminViewModel>();
      final sftpVm = context.read<SftpViewModel>();
      final selectedId = adminVm.selectedConnectionId;
      if (selectedId != null &&
          (sftpVm.connectionId == null ||
              selectedId != _lastSynchronizedAdminConnectionId)) {
        _lastSynchronizedAdminConnectionId = selectedId;
        if (sftpVm.connectionId != selectedId) {
          unawaited(
            sftpVm.connect(
              selectedId,
              onUnknownHostKey: (request) =>
                  showSshHostKeyTrustDialog(context, request),
            ),
          );
        }
      }
    }
  }

  String settingsLabelAi(BuildContext context) {
    return 'AI';
  }

  void _openSettings(BuildContext context) {
    _scaffoldKey.currentState?.openDrawer();
  }

  Widget _buildSettingsDrawer(BuildContext context, AppStrings strings) {
    final viewportWidth = MediaQuery.sizeOf(context).width;
    final desktop = isDesktopLayout(context);
    final width = settingsDrawerWidthFor(
      viewportWidth: viewportWidth,
      desktop: desktop,
    );
    return SizedBox(
      width: width,
      child: Drawer(
        child: _SettingsPage(
          onExport: () => _exportAppData(context, strings),
          onImport: () => _importAppData(context, strings),
        ),
      ),
    );
  }

  Widget _buildPage(BuildContext context, int index, AppStrings strings) {
    final active = _selectedIndex == index;
    return _pageShell(
      index,
      _DeferredNavPage(
        active: active,
        loading: _buildLoadingState(),
        keepAliveAfterFirstBuild: true,
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
              return const ServerListPane();
            case _sftpPage:
              return const SftpScreen();
            case _adminPage:
              return const SystemAdminScreen();
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
      child: RepaintBoundary(child: AppPageSurface(child: child)),
    );
  }

  Future<void> _exportAppData(BuildContext context, AppStrings strings) async {
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
        messenger.showSnackBar(SnackBar(content: Text(strings.exportComplete)));
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.exportFailed(e))));
    }
  }

  Future<void> _importAppData(BuildContext context, AppStrings strings) async {
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
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
        return file?.readAsBytes();
      });
      if (!context.mounted) return;
      if (success) {
        messenger.showSnackBar(SnackBar(content: Text(strings.importComplete)));
        _switchPage(_serverPage);
      }
    } catch (e) {
      if (!context.mounted) return;
      messenger.showSnackBar(SnackBar(content: Text(strings.importFailed(e))));
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
          child: _AnimatedPageFadeIn(
            active: widget.active,
            child: Builder(builder: widget.builder),
          ),
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
    return _AnimatedPageFadeIn(active: true, child: widget.builder(context));
  }
}

class _AnimatedPageFadeIn extends StatelessWidget {
  final Widget child;
  final bool active;

  const _AnimatedPageFadeIn({required this.child, required this.active});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}

class SwitchToAiTabNotification extends Notification {
  const SwitchToAiTabNotification();
}
