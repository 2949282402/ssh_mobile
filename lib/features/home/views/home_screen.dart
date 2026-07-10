import 'dart:async';
import 'dart:ui';
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
  double _scrollPosition = 0.0;
  bool _aiHistoryVisible = false;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex.clamp(_firstPage, _lastPage);
    _settledIndex = _selectedIndex;
    _scrollPosition = _selectedIndex.toDouble();
    _pageController = PageController(initialPage: _selectedIndex);
    _pageController.addListener(_handleScroll);
  }

  void _handleScroll() {
    if (_pageController.hasClients) {
      final page = _pageController.page;
      if (page != null && page != _scrollPosition) {
        setState(() {
          _scrollPosition = page;
        });
      }
    }
  }

  @override
  void dispose() {
    _pageController.removeListener(_handleScroll);
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
    final isBusy = context.select<SettingsViewModel, bool>(
      (vm) => vm.isImporting || vm.isExporting,
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
      drawer: _selectedIndex == _serverPage
          ? _buildSettingsDrawer(context, strings)
          : null,
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
      floatingActionButton: _selectedIndex == _serverPage
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
    final width = MediaQuery.sizeOf(context).width;
    final extended = width >= AppBreakpoints.wideDesktop;

    return Row(
      children: [
        NavigationRail(
          extended: extended,
          labelType: extended ? null : NavigationRailLabelType.all,
          selectedIndex: _navigationIndex,
          onDestinationSelected: _switchNavigationPage,
          trailing: Expanded(
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: IconButton(
                  tooltip: strings.settings,
                  icon: const Icon(Icons.settings_outlined),
                  onPressed: () => _openSettings(context),
                ),
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
              icon: const Icon(Icons.smart_toy_outlined),
              selectedIcon: const Icon(Icons.smart_toy_rounded),
              label: _buildAiLabel(context, _selectedIndex == _aiPage),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              selectedIcon: const Icon(Icons.admin_panel_settings_rounded),
              label: Text(strings.admin),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.terminal_outlined),
              selectedIcon: const Icon(Icons.terminal_rounded),
              label: Text(strings.logs),
            ),
          ],
        ),
        VerticalDivider(
          width: 1,
          thickness: 1,
          color: colorScheme.outlineVariant,
        ),
        Expanded(child: content),
      ],
    );
  }

  Widget _buildBottomNavigation(BuildContext context, AppStrings strings) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final extColors = theme.extension<ExtendedColors>();
    final glassBg =
        extColors?.glassBg ?? colorScheme.surface.withValues(alpha: 0.72);
    final glassBorder =
        extColors?.glassBorder ??
        colorScheme.outlineVariant.withValues(alpha: 0.3);

    return ClipPath(
      clipper: BottomNavCurveClipper(scrollPosition: _scrollPosition),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 15.0, sigmaY: 15.0),
        child: CustomPaint(
          painter: BottomNavCurvePainter(
            scrollPosition: _scrollPosition,
            backgroundColor: glassBg,
            borderColor: glassBorder,
          ),
          child: Container(
            height: 64.0 + mediaQuery.padding.bottom,
            color: Colors.transparent,
            child: SafeArea(
              top: false,
              child: Row(
                children: [
                  _buildNavItem(
                    context: context,
                    icon: const Icon(Icons.dns_outlined),
                    selectedIcon: const Icon(Icons.dns_rounded),
                    label: strings.servers,
                    index: _serverPage,
                  ),
                  _buildNavItem(
                    context: context,
                    icon: const Icon(Icons.folder_open_outlined),
                    selectedIcon: const Icon(Icons.folder_open_rounded),
                    label: strings.sftp,
                    index: _sftpPage,
                  ),
                  _buildAiNavItem(
                    context: context,
                    icon: const Icon(Icons.smart_toy_outlined),
                    selectedIcon: const Icon(Icons.smart_toy_rounded),
                    index: _aiPage,
                  ),
                  _buildNavItem(
                    context: context,
                    icon: const Icon(Icons.admin_panel_settings_outlined),
                    selectedIcon: const Icon(
                      Icons.admin_panel_settings_rounded,
                    ),
                    label: strings.admin,
                    index: _adminPage,
                  ),
                  _buildNavItem(
                    context: context,
                    icon: const Icon(Icons.terminal_outlined),
                    selectedIcon: const Icon(Icons.terminal_rounded),
                    label: strings.logs,
                    index: _logPage,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required BuildContext context,
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
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(0, isSelected ? -3 : 0, 0),
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      width: 56,
                      height: 28,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colorScheme.primary.withValues(alpha: 0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    IconTheme(
                      data: IconThemeData(
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                      child: isSelected ? selectedIcon : icon,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                style: TextStyle(
                  color: isSelected
                      ? colorScheme.primary
                      : colorScheme.onSurfaceVariant,
                  fontSize: 11,
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

  Widget _buildAiNavItem({
    required BuildContext context,
    required Widget icon,
    required Widget selectedIcon,
    required int index,
  }) {
    final isSelected = _selectedIndex == index;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Expanded(
      child: HomeNavigationSemantics(
        semanticsKey: ValueKey<String>('home-nav-$index'),
        label: 'AI',
        selected: isSelected,
        onTap: () => _switchNavigationPage(index),
        child: TactileFeedback(
          onTap: () => _switchNavigationPage(index),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutCubic,
                transform: Matrix4.translationValues(0, isSelected ? -3 : 0, 0),
                child: Stack(
                  alignment: Alignment.center,
                  clipBehavior: Clip.none,
                  children: [
                    AnimatedContainer(
                      duration: const Duration(milliseconds: 250),
                      curve: Curves.easeOutCubic,
                      width: 56,
                      height: 28,
                      decoration: BoxDecoration(
                        color: isSelected
                            ? colorScheme.primary.withValues(alpha: 0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    IconTheme(
                      data: IconThemeData(
                        color: isSelected
                            ? colorScheme.primary
                            : colorScheme.onSurfaceVariant,
                        size: 20,
                      ),
                      child: isSelected ? selectedIcon : icon,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 2),
              _buildAiLabel(context, isSelected),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAiLabel(BuildContext context, bool isSelected) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: isSelected
              ? [colorScheme.primary, colorScheme.tertiary]
              : [
                  colorScheme.primary.withValues(alpha: 0.15),
                  colorScheme.tertiary.withValues(alpha: 0.15),
                ],
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: colorScheme.primary.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Text(
        'AI',
        style: TextStyle(
          color: isSelected ? Colors.white : colorScheme.primary,
          fontSize: 11,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.5,
        ),
      ),
    );
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
    return SizedBox(
      width: MediaQuery.sizeOf(context).width * 0.85,
      child: Drawer(
        child: _SettingsPage(
          appTitle: strings.appTitle,
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
      child: RepaintBoundary(child: child),
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

class BottomNavCurvePainter extends CustomPainter {
  final double scrollPosition;
  final Color backgroundColor;
  final Color borderColor;
  final double domeWidth;
  final double domeHeight;

  BottomNavCurvePainter({
    required this.scrollPosition,
    required this.backgroundColor,
    required this.borderColor,
    this.domeWidth = 100.0,
    this.domeHeight = 5.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;

    final double tabWidth = size.width / 5;
    final double centerX = (scrollPosition + 0.5) * tabWidth;

    // Smoothly scale down dome height near the left/right boundaries
    // to prevent overlapping with the edges.
    final double threshold = domeWidth / 2;
    double currentDomeHeight = domeHeight;

    if (centerX < threshold) {
      if (centerX <= 0) {
        currentDomeHeight = 0.0;
      } else {
        final double t = centerX / threshold;
        currentDomeHeight = domeHeight * (t * t); // Quadratic easing
      }
    } else if (size.width - centerX < threshold) {
      final double distToRight = size.width - centerX;
      if (distToRight <= 0) {
        currentDomeHeight = 0.0;
      } else {
        final double t = distToRight / threshold;
        currentDomeHeight = domeHeight * (t * t); // Quadratic easing
      }
    }

    double domeStart = centerX - domeWidth / 2;
    double domeEnd = centerX + domeWidth / 2;

    if (domeStart < 0) {
      domeStart = 0;
    }
    if (domeEnd > size.width) {
      domeEnd = size.width;
    }

    final path = Path();
    path.moveTo(0, 0);

    // Line to dome start
    path.lineTo(domeStart, 0);

    // Draw the dome (only if height > 0)
    if (currentDomeHeight > 0) {
      path.cubicTo(
        centerX - domeWidth * 0.35,
        0,
        centerX - domeWidth * 0.22,
        -currentDomeHeight,
        centerX,
        -currentDomeHeight,
      );
      path.cubicTo(
        centerX + domeWidth * 0.22,
        -currentDomeHeight,
        centerX + domeWidth * 0.35,
        0,
        domeEnd,
        0,
      );
    }

    // Line to top-right corner
    path.lineTo(size.width, 0);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    // 1. Draw a very soft drop shadow under the top edge for elegant depth
    final shadowPath = Path();
    shadowPath.moveTo(0, 0);
    if (domeStart > 0) {
      shadowPath.lineTo(domeStart, 0);
    }
    if (currentDomeHeight > 0) {
      shadowPath.cubicTo(
        centerX - domeWidth * 0.35,
        0,
        centerX - domeWidth * 0.22,
        -currentDomeHeight,
        centerX,
        -currentDomeHeight,
      );
      shadowPath.cubicTo(
        centerX + domeWidth * 0.22,
        -currentDomeHeight,
        centerX + domeWidth * 0.35,
        0,
        domeEnd,
        0,
      );
    }
    shadowPath.lineTo(size.width, 0);

    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.05)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0;
    shadowPaint.maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.5);
    canvas.drawPath(shadowPath, shadowPaint);

    // 2. Draw the solid background
    canvas.drawPath(path, paint);

    // 3. Draw the top border line
    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(shadowPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant BottomNavCurvePainter oldDelegate) {
    return oldDelegate.scrollPosition != scrollPosition ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.borderColor != borderColor;
  }
}

class BottomNavCurveClipper extends CustomClipper<Path> {
  final double scrollPosition;
  final double domeWidth;
  final double domeHeight;

  BottomNavCurveClipper({
    required this.scrollPosition,
    this.domeWidth = 100.0,
    this.domeHeight = 5.0,
  });

  @override
  Path getClip(Size size) {
    final double tabWidth = size.width / 5;
    final double centerX = (scrollPosition + 0.5) * tabWidth;

    final double threshold = domeWidth / 2;
    double currentDomeHeight = domeHeight;

    if (centerX < threshold) {
      if (centerX <= 0) {
        currentDomeHeight = 0.0;
      } else {
        final double t = centerX / threshold;
        currentDomeHeight = domeHeight * (t * t);
      }
    } else if (size.width - centerX < threshold) {
      final double distToRight = size.width - centerX;
      if (distToRight <= 0) {
        currentDomeHeight = 0.0;
      } else {
        final double t = distToRight / threshold;
        currentDomeHeight = domeHeight * (t * t);
      }
    }

    double domeStart = centerX - domeWidth / 2;
    double domeEnd = centerX + domeWidth / 2;

    if (domeStart < 0) {
      domeStart = 0;
    }
    if (domeEnd > size.width) {
      domeEnd = size.width;
    }

    final path = Path();
    path.moveTo(0, -10);
    path.lineTo(domeStart, -10);
    if (currentDomeHeight > 0) {
      path.cubicTo(
        centerX - domeWidth * 0.35,
        -10,
        centerX - domeWidth * 0.22,
        -currentDomeHeight - 10,
        centerX,
        -currentDomeHeight - 10,
      );
      path.cubicTo(
        centerX + domeWidth * 0.22,
        -currentDomeHeight - 10,
        centerX + domeWidth * 0.35,
        -10,
        domeEnd,
        -10,
      );
    }
    path.lineTo(size.width, -10);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();
    return path;
  }

  @override
  bool shouldReclip(covariant BottomNavCurveClipper oldClipper) {
    return oldClipper.scrollPosition != scrollPosition;
  }
}
