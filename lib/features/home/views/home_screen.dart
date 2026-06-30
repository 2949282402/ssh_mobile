import 'dart:async';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/foundation.dart';
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

part 'widgets/home_settings_strings.dart';
part 'widgets/settings_panel.dart';
part 'widgets/server_list_pane.dart';

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
  final Set<String> _expandedConnectionWindowIds = {};
  bool _aiHistoryVisible = false;
  bool _serverSelectionMode = false;
  final Set<String> _selectedServerIds = {};

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
            return false;
          },
          child: PageView.builder(
            controller: _pageController,
            itemCount: _lastPage + 1,
            physics: const BouncingScrollPhysics(),
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
      body: SafeArea(
        bottom: false,
        child: Stack(
          children: [
            desktop ? _buildDesktopShell(context, content, strings) : content,
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
        Expanded(
          child: content,
        ),
      ],
    );
  }

  Widget _buildBottomNavigation(BuildContext context, AppStrings strings) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final mediaQuery = MediaQuery.of(context);

    return CustomPaint(
      painter: BottomNavCurvePainter(
        scrollPosition: _scrollPosition,
        backgroundColor: colorScheme.surface,
        borderColor: colorScheme.outlineVariant.withValues(alpha: 0.5),
      ),
      child: Container(
        height: 80 + mediaQuery.padding.bottom,
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
                selectedIcon: const Icon(Icons.admin_panel_settings_rounded),
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
      child: TactileFeedback(
        onTap: () => _switchNavigationPage(index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(0, isSelected ? -6 : 0, 0),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    width: 64,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colorScheme.primary.withValues(alpha: 0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  IconTheme(
                    data: IconThemeData(
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                    child: isSelected ? selectedIcon : icon,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              style: TextStyle(
                color: isSelected
                    ? colorScheme.primary
                    : colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                letterSpacing: 0,
              ),
              child: Text(label),
            ),
          ],
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
      child: TactileFeedback(
        onTap: () => _switchNavigationPage(index),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeOutCubic,
              transform: Matrix4.translationValues(0, isSelected ? -6 : 0, 0),
              child: Stack(
                alignment: Alignment.center,
                clipBehavior: Clip.none,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    width: 64,
                    height: 32,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? colorScheme.primary.withValues(alpha: 0.08)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  IconTheme(
                    data: IconThemeData(
                      color: isSelected
                          ? colorScheme.primary
                          : colorScheme.onSurfaceVariant,
                      size: 22,
                    ),
                    child: isSelected ? selectedIcon : icon,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 4),
            _buildAiLabel(context, isSelected),
          ],
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
                  colorScheme.tertiary.withValues(alpha: 0.15)
                ],
        ),
        borderRadius: BorderRadius.circular(8),
        boxShadow: isSelected
            ? [
                BoxShadow(
                  color: colorScheme.primary.withValues(alpha: 0.25),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                )
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
          unawaited(sftpVm.connect(
            selectedId,
            onUnknownHostKey: (request) =>
                showSshHostKeyTrustDialog(context, request),
          ));
        }
      }
    }
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
        keepAliveAfterFirstBuild:
            index == _aiPage || index == _sftpPage || index == _adminPage,
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
        final file = await FilePicker.pickFile(
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
        return file?.readAsBytes();
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
    return _AnimatedPageFadeIn(
      active: true,
      child: widget.builder(context),
    );
  }
}

class _AnimatedPageFadeIn extends StatelessWidget {
  final Widget child;
  final bool active;

  const _AnimatedPageFadeIn({required this.child, required this.active});

  @override
  Widget build(BuildContext context) {
    return TweenAnimationBuilder<double>(
      key: ValueKey(active),
      tween: Tween(begin: 0.0, end: active ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 320),
      curve: Curves.easeOutCubic,
      builder: (context, value, child) {
        if (value == 0.0 && !active) {
          return const SizedBox.shrink();
        }
        return Opacity(
          opacity: value,
          child: Transform.translate(
            offset: Offset(0, 16 * (1 - value)),
            child: child,
          ),
        );
      },
      child: child,
    );
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
    this.domeWidth = 75.0,
    this.domeHeight = 10.0,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = backgroundColor
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = borderColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;

    final double tabWidth = size.width / 5;
    final double centerX = (scrollPosition + 0.5) * tabWidth;

    final path = Path();
    path.moveTo(0, 0);

    final domeStart = centerX - domeWidth / 2;
    final domeEnd = centerX + domeWidth / 2;

    if (domeStart > 0) {
      path.lineTo(domeStart, 0);
    } else {
      path.moveTo(0, 0);
    }

    path.cubicTo(
      centerX - domeWidth / 4,
      0,
      centerX - domeWidth / 4,
      -domeHeight,
      centerX,
      -domeHeight,
    );
    path.cubicTo(
      centerX + domeWidth / 4,
      -domeHeight,
      centerX + domeWidth / 4,
      0,
      domeEnd,
      0,
    );

    path.lineTo(size.width, 0);
    path.lineTo(size.width, size.height);
    path.lineTo(0, size.height);
    path.close();

    canvas.drawPath(path, paint);

    final borderPath = Path();
    borderPath.moveTo(0, 0);
    if (domeStart > 0) {
      borderPath.lineTo(domeStart, 0);
    }
    borderPath.cubicTo(
      centerX - domeWidth / 4,
      0,
      centerX - domeWidth / 4,
      -domeHeight,
      centerX,
      -domeHeight,
    );
    borderPath.cubicTo(
      centerX + domeWidth / 4,
      -domeHeight,
      centerX + domeWidth / 4,
      0,
      domeEnd,
      0,
    );
    borderPath.lineTo(size.width, 0);

    canvas.drawPath(borderPath, borderPaint);
  }

  @override
  bool shouldRepaint(covariant BottomNavCurvePainter oldDelegate) {
    return oldDelegate.scrollPosition != scrollPosition ||
        oldDelegate.backgroundColor != backgroundColor ||
        oldDelegate.borderColor != borderColor;
  }
}
