import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import 'package:animations/animations.dart';

import '../models/connection.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../services/playbook_service.dart';
import '../utils/responsive.dart';
import '../widgets/connection_progress_dialog.dart';
import '../widgets/tactile_feedback.dart';
import '../widgets/window_name_dialog.dart';
import 'developer_log_screen.dart';
import 'llm_chat_screen.dart';
import 'performance_monitor_screen.dart';
import 'sftp_screen.dart';
import 'system_admin_screen.dart';
import 'terminal_windows_screen.dart';
import '../services/performance_monitor_service.dart';

part 'home/home_settings_strings.dart';
part 'home/settings_panel.dart';

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
  static const int _performancePage = 3;
  static const int _adminPage = 4;
  static const int _logPage = 5;
  static const int _firstPage = _aiPage;
  static const int _lastPage = _logPage;

  late final PageController _pageController;
  late int _selectedIndex;
  late int _settledIndex;
  final Set<String> _expandedConnectionWindowIds = {};
  bool _aiHistoryVisible = false;
  bool _appDataBusy = false;
  bool _serverSelectionMode = false;
  final Set<String> _selectedServerIds = {};
  PlaybookService? _playbookService;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex.clamp(_firstPage, _lastPage);
    _settledIndex = _selectedIndex;
    _pageController = PageController(initialPage: _selectedIndex);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _playbookService = context.read<PlaybookService>();
      _playbookService?.addListener(_onPlaybookServiceChanged);
    });
  }

  @override
  void dispose() {
    _playbookService?.removeListener(_onPlaybookServiceChanged);
    _pageController.dispose();
    super.dispose();
  }

  void _onPlaybookServiceChanged() {
    if (!mounted) return;
    final prompt = _playbookService?.pendingDiagnosticPrompt;
    if (prompt != null && prompt.isNotEmpty) {
      _switchPage(_aiPage);
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final desktop = isDesktopLayout(context);
    final content = NotificationListener<ScrollNotification>(
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
            if (_appDataBusy)
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
              icon: const Icon(Icons.monitor_heart_outlined),
              selectedIcon: const Icon(Icons.monitor_heart_rounded),
              label: Text(strings.performanceMonitor),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.admin_panel_settings_outlined),
              selectedIcon: const Icon(Icons.admin_panel_settings_rounded),
              label: Text(strings.systemAdmin),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.article_outlined),
              selectedIcon: const Icon(Icons.article_rounded),
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

  Widget _buildBottomNavigation(
    BuildContext context,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textScale =
        MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0).toDouble();
    final expandedHeight = 62.0 + (textScale - 1.0) * 18.0;
    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: expandedHeight,
          child: Row(
            children: [
              _bottomNavItem(
                context,
                index: 0,
                icon: const Icon(Icons.smart_toy_outlined),
                selectedIcon: const Icon(Icons.smart_toy_rounded),
                label: settingsLabelAi(context),
              ),
              _bottomNavItem(
                context,
                index: 1,
                icon: const Icon(Icons.dns_outlined),
                selectedIcon: const Icon(Icons.dns_rounded),
                label: strings.servers,
              ),
              _bottomNavItem(
                context,
                index: 2,
                icon: const Icon(Icons.folder_open_outlined),
                selectedIcon: const Icon(Icons.folder_open_rounded),
                label: strings.sftp,
              ),
              _bottomNavItem(
                context,
                index: 3,
                icon: const Icon(Icons.monitor_heart_outlined),
                selectedIcon: const Icon(Icons.monitor_heart_rounded),
                label: strings.performanceMonitor,
              ),
              _bottomNavItem(
                context,
                index: 4,
                icon: const Icon(Icons.admin_panel_settings_outlined),
                selectedIcon: const Icon(Icons.admin_panel_settings_rounded),
                label: strings.systemAdmin,
              ),
              _bottomNavItem(
                context,
                index: 5,
                icon: const Icon(Icons.article_outlined),
                selectedIcon: const Icon(Icons.article_rounded),
                label: strings.logs,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bottomNavItem(
    BuildContext context, {
    required int index,
    required Widget icon,
    required Widget selectedIcon,
    required String label,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final selected = _navigationIndex == index;
    final foreground =
        selected ? colorScheme.primary : colorScheme.onSurfaceVariant;

    return Expanded(
      child: InkWell(
        onTap: () => _switchNavigationPage(index),
        child: LayoutBuilder(
          builder: (context, constraints) {
            if (constraints.maxHeight < 44) {
              return const SizedBox.shrink();
            }
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 2),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    width: 54,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? colorScheme.primary.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: IconTheme(
                      data: IconThemeData(color: foreground, size: 22),
                      child: selected ? selectedIcon : icon,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Flexible(
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: foreground,
                          fontSize: 11,
                          fontWeight:
                              selected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String get _appTitle {
    if (!kIsWeb) {
      switch (defaultTargetPlatform) {
        case TargetPlatform.windows:
          return 'SSH Windows';
        case TargetPlatform.macOS:
          return 'SSH Mac';
        case TargetPlatform.android:
        case TargetPlatform.iOS:
          return 'SSH Mobile';
        case TargetPlatform.linux:
        case TargetPlatform.fuchsia:
          break;
      }
    }
    return 'SSH Mobile';
  }

  int? get _navigationIndex {
    switch (_selectedIndex) {
      case _serverPage:
        return 1;
      case _sftpPage:
        return 2;
      case _performancePage:
        return 3;
      case _adminPage:
        return 4;
      case _logPage:
        return 5;
      case _aiPage:
      default:
        return 0;
    }
  }

  void _switchNavigationPage(int index) {
    switch (index) {
      case 0:
        _switchPage(_aiPage);
        break;
      case 1:
        _switchPage(_serverPage);
        break;
      case 2:
        _switchPage(_sftpPage);
        break;
      case 3:
        _switchPage(_performancePage);
        break;
      case 4:
        _switchPage(_adminPage);
        break;
      case 5:
        _switchPage(_logPage);
        break;
      default:
        _switchPage(_sftpPage);
        break;
    }
  }

  String settingsLabelAi(BuildContext context) {
    return context.read<AppSettings>().isEnglish ? 'AI' : 'AI';
  }

  void _switchPage(int index) {
    if (index == _selectedIndex) return;
    setState(() => _selectedIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _openSettings(BuildContext context) {
    Navigator.push(
      context,
      PageRouteBuilder(
        pageBuilder: (context, animation, secondaryAnimation) => _SettingsPage(
          appTitle: _appTitle,
          onExport: () => _exportAppData(
              context,
              AppStrings(
                context.read<AppSettings>().language,
              )),
          onImport: () => _importAppData(
              context,
              AppStrings(
                context.read<AppSettings>().language,
              )),
        ),
        transitionsBuilder: (context, animation, secondaryAnimation, child) {
          return SharedAxisTransition(
            animation: animation,
            secondaryAnimation: secondaryAnimation,
            transitionType: SharedAxisTransitionType.scaled,
            child: child,
          );
        },
        transitionDuration: const Duration(milliseconds: 300),
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
            case _performancePage:
              return const PerformanceMonitorScreen();
            case _adminPage:
              return const SystemAdminScreen();
            case _logPage:
            default:
              return const DeveloperLogPage();
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
    try {
      if (mounted) setState(() => _appDataBusy = true);
      final jsonText = await context.read<StorageService>().exportAppDataJson();
      if (!context.mounted) return;
      final now = DateTime.now();
      final fileName =
          'ssh_mobile_backup_${now.year}${now.month.toString().padLeft(2, '0')}${now.day.toString().padLeft(2, '0')}.json';
      final path = await FilePicker.saveFile(
        dialogTitle: strings.exportAppData,
        fileName: fileName,
        bytes: utf8.encode(jsonText),
      );
      if (!context.mounted || path == null) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.exportComplete)),
      );
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Export app data failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.exportFailed(e))),
      );
    } finally {
      if (mounted) setState(() => _appDataBusy = false);
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
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (!context.mounted || result == null || result.files.isEmpty) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) {
        throw StateError('Unable to read selected file.');
      }
      if (mounted) setState(() => _appDataBusy = true);
      await context
          .read<StorageService>()
          .importAppDataJson(utf8.decode(bytes));
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.importComplete)),
      );
      _switchPage(_serverPage);
    } catch (e, stackTrace) {
      AppLogService.instance.error(
        'Import app data failed',
        error: e,
        stackTrace: stackTrace,
      );
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.importFailed(e))),
      );
    } finally {
      if (mounted) setState(() => _appDataBusy = false);
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

  Widget _buildServerPage(
    BuildContext context,
    AppStrings strings,
  ) {
    final storageReady = context.select<StorageService, bool>(
      (storage) => storage.initialized,
    );
    final connections = context.select<StorageService, List<ConnectionConfig>>(
      (storage) => storage.connections,
    );
    return connections.isEmpty
        ? storageReady
            ? _buildEmptyState(context, strings)
            : _buildLoadingState()
        : _buildConnectionList(
            context,
            connections,
            strings,
          );
  }

  Widget _buildEmptyState(BuildContext context, AppStrings strings) {
    final colorScheme = Theme.of(context).colorScheme;

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 84,
              height: 84,
              decoration: BoxDecoration(
                color: colorScheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: colorScheme.primary.withValues(alpha: 0.18),
                ),
              ),
              child: Icon(
                Icons.terminal_rounded,
                size: 42,
                color: colorScheme.primary,
              ),
            ),
            const SizedBox(height: 18),
            Text(
              strings.noConnections,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              strings.addHint,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: colorScheme.onSurface.withValues(alpha: 0.62),
                fontSize: 14,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionList(
    BuildContext context,
    List<ConnectionConfig> connections,
    AppStrings strings,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= AppBreakpoints.desktop;
        final horizontalPadding = desktop ? 24.0 : 12.0;
        final maxContentWidth = desktop ? 1480.0 : double.infinity;

        return SizedBox(
          width: maxContentWidth.isInfinite
              ? constraints.maxWidth
              : maxContentWidth,
          height: constraints.maxHeight,
          child: Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  horizontalPadding,
                  desktop ? 18 : 8,
                  horizontalPadding,
                  12,
                ),
                child: _buildOverviewHeader(
                  context,
                  connections,
                  strings,
                ),
              ),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    0,
                    horizontalPadding,
                    88,
                  ),
                  itemCount: connections.length,
                  itemBuilder: (context, index) => _buildConnectionCard(
                    context,
                    connections[index],
                    strings,
                    connIndex: index,
                  ),
                  onReorder: (oldIndex, newIndex) {
                    context
                        .read<StorageService>()
                        .reorderConnections(oldIndex, newIndex);
                  },
                ),
              ),
              if (_serverSelectionMode) _buildSelectionBar(context, strings),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSelectionBar(BuildContext context, AppStrings strings) {
    final colorScheme = Theme.of(context).colorScheme;
    final count = _selectedServerIds.length;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHigh,
        border: Border(
          top: BorderSide(color: colorScheme.outlineVariant),
        ),
      ),
      child: Row(
        children: [
          Text(
            '$count ${strings.language == AppLanguage.en ? 'selected' : '已选择'}',
            style: TextStyle(
              color: colorScheme.onSurface,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const Spacer(),
          TextButton.icon(
            icon: const Icon(Icons.close, size: 18),
            label: Text(strings.cancel),
            onPressed: () {
              setState(() {
                _serverSelectionMode = false;
                _selectedServerIds.clear();
              });
            },
          ),
          const SizedBox(width: 8),
          if (count > 0)
            FilledButton.tonalIcon(
              icon: const Icon(Icons.delete, size: 18),
              label: Text(strings.delete),
              style: FilledButton.styleFrom(
                foregroundColor: colorScheme.error,
                backgroundColor: colorScheme.errorContainer,
              ),
              onPressed: () => _confirmBatchDelete(context, strings),
            ),
        ],
      ),
    );
  }

  Widget _buildConnectionCard(
    BuildContext context,
    ConnectionConfig conn,
    AppStrings strings, {
    int connIndex = 0,
  }) {
    return Selector<SshService, SshConnectionOverview>(
      key: ValueKey(conn.id),
      selector: (_, ssh) => ssh.serverOverviewSnapshot.forConnection(conn.id),
      builder: (context, sessionSummary, _) => _buildConnectionCardBody(
        context,
        conn,
        sessionSummary,
        strings,
        connIndex: connIndex,
      ),
    );
  }

  Widget _buildConnectionCardBody(
    BuildContext context,
    ConnectionConfig conn,
    SshConnectionOverview sessionSummary,
    AppStrings strings, {
    required int connIndex,
  }) {
    final isActive = sessionSummary.hasConnected;
    final sessionCount = sessionSummary.count;
    final latestState = sessionSummary.latestState;
    final isConnecting = latestState == SshConnectionState.connecting;
    final colorScheme = Theme.of(context).colorScheme;
    final primary = colorScheme.primary;
    final success = colorScheme.secondary;
    final cardColor = _panelColor(context);
    final textColor = _panelTextColor(context);
    final mutedTextColor = _panelMutedTextColor(context);
    final borderColor =
        isActive ? success.withValues(alpha: 0.42) : _panelBorderColor(context);
    final isSelected = _selectedServerIds.contains(conn.id);

    final windowsExpanded = _expandedConnectionWindowIds.contains(conn.id);

    return TactileFeedback(
      onTap:
          !_serverSelectionMode ? () => _openNewTerminal(context, conn) : null,
      onLongPress: () {
        if (!_serverSelectionMode) {
          setState(() {
            _serverSelectionMode = true;
            _selectedServerIds.add(conn.id);
          });
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? colorScheme.primary : borderColor,
            width: isSelected ? 1.5 : 1,
          ),
          boxShadow: _panelShadow(context),
        ),
        child: Column(
          children: [
            Row(
              children: [
                if (!_serverSelectionMode)
                  ReorderableDragStartListener(
                    index: connIndex,
                    child: Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(
                        Icons.drag_handle,
                        size: 20,
                        color: mutedTextColor.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                if (_serverSelectionMode)
                  Checkbox(
                    value: isSelected,
                    onChanged: (_) => _toggleServerSelection(conn.id),
                  ),
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: isActive
                        ? success.withValues(alpha: 0.15)
                        : primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(
                    _getStatusIcon(conn, latestState),
                    color: isActive ? success : primary,
                    size: 24,
                  ),
                ),
                if (!_serverSelectionMode) const SizedBox(width: 14),
                if (_serverSelectionMode) const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        conn.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: textColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Icon(
                            Icons.dns_outlined,
                            size: 13,
                            color: mutedTextColor.withValues(alpha: 0.72),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: SingleChildScrollView(
                              scrollDirection: Axis.horizontal,
                              child: Text(
                                '${conn.username}@${conn.host}:${conn.port}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color: mutedTextColor,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Selector<PerformanceMonitorService,
                            ServerHealthSnapshot>(
                          selector: (_, monitor) => monitor.healthFor(conn.id),
                          builder: (context, health, _) =>
                              _buildHealthChip(context, health, strings),
                        ),
                      ),
                    ],
                  ),
                ),
                if (!_serverSelectionMode && sessionCount > 0) ...[
                  const SizedBox(width: 8),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                    decoration: BoxDecoration(
                      color: success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                      border:
                          Border.all(color: success.withValues(alpha: 0.35)),
                    ),
                    child: Text(
                      '$sessionCount',
                      style: TextStyle(
                        color: success,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
                if (!_serverSelectionMode && isConnecting)
                  const SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else if (!_serverSelectionMode) ...[
                  IconButton(
                    tooltip: strings.newWindow,
                    icon: const Icon(Icons.add_to_photos_outlined),
                    color: mutedTextColor,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openNewTerminal(context, conn),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert, color: mutedTextColor),
                    onSelected: (action) =>
                        _handleAction(context, conn, action),
                    itemBuilder: (_) => [
                      PopupMenuItem(
                        value: 'edit',
                        child: Row(
                          children: [
                            const Icon(Icons.edit, size: 18),
                            const SizedBox(width: 8),
                            Text(strings.edit),
                          ],
                        ),
                      ),
                      PopupMenuItem(
                        value: 'delete',
                        child: Row(
                          children: [
                            Icon(Icons.delete,
                                size: 18,
                                color: Theme.of(context).colorScheme.error),
                            const SizedBox(width: 8),
                            Text(
                              strings.delete,
                              style: TextStyle(
                                  color: Theme.of(context).colorScheme.error),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Divider(
                height: 1, color: Theme.of(context).colorScheme.outlineVariant),
            InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => _toggleConnectionWindows(conn.id),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(4, 9, 4, 0),
                child: Row(
                  children: [
                    Icon(
                      Icons.tab_outlined,
                      size: 17,
                      color: mutedTextColor,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${strings.terminalWindows} ($sessionCount)',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Icon(
                      windowsExpanded
                          ? Icons.expand_less_rounded
                          : Icons.expand_more_rounded,
                      color: mutedTextColor,
                    ),
                  ],
                ),
              ),
            ),
            if (windowsExpanded)
              TerminalWindowsPage(
                key: PageStorageKey<String>('server-windows-${conn.id}'),
                connectionId: conn.id,
                showHeader: false,
                embedded: true,
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildHealthChip(
    BuildContext context,
    ServerHealthSnapshot health,
    AppStrings strings,
  ) {
    final color = _healthColor(context, health.level);
    final label = _healthLabel(strings, health.level);
    final detail = health.details.isEmpty ? label : health.details.join(' / ');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(_healthIcon(health.level), size: 13, color: color),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              '${strings.language == AppLanguage.en ? 'Health' : '健康'} ${health.score} · $detail',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOverviewHeader(
    BuildContext context,
    List<ConnectionConfig> connections,
    AppStrings strings,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cardColor = _panelColor(context);
    final textColor = _panelTextColor(context);
    final mutedTextColor = _panelMutedTextColor(context);
    final headerSnapshot = context.select<SshService, _ServerHeaderSnapshot>(
      (ssh) =>
          _ServerHeaderSnapshot.from(ssh.serverOverviewSnapshot, connections),
    );
    final activeCount = headerSnapshot.activeCount;
    final windowCount = headerSnapshot.windowCount;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(2, 0, 0, 8),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        context.read<AppSettings>().isEnglish
                            ? 'Server overview'
                            : '服务器总览',
                        style: TextStyle(
                          color: textColor,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        context.read<AppSettings>().isEnglish
                            ? 'Server information and terminal windows are managed together here.'
                            : '服务器信息与终端窗口在这里统一管理。',
                        style: TextStyle(
                          color: mutedTextColor,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: context.read<AppSettings>().isEnglish
                      ? 'Playbooks'
                      : '运维剧本',
                  icon: const Icon(Icons.rocket_launch_outlined),
                  color: mutedTextColor,
                  onPressed: () => Navigator.pushNamed(context, '/playbooks'),
                ),
                IconButton(
                  tooltip: strings.connectionHistory,
                  icon: const Icon(Icons.history_rounded),
                  color: mutedTextColor,
                  onPressed: () => Navigator.pushNamed(context, '/history'),
                ),
                IconButton(
                  tooltip: strings.settings,
                  icon: const Icon(Icons.settings_outlined),
                  color: mutedTextColor,
                  onPressed: () => _openSettings(context),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: cardColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: _panelBorderColor(context)),
              boxShadow: _panelShadow(context),
            ),
            child: Row(
              children: [
                _summaryItem(
                  context,
                  icon: Icons.storage_rounded,
                  label: strings.servers,
                  value: '${connections.length}',
                  textColor: textColor,
                  mutedTextColor: mutedTextColor,
                ),
                const SizedBox(width: 10),
                _summaryItem(
                  context,
                  icon: Icons.link_rounded,
                  label: strings.active,
                  value: '$activeCount',
                  accent: colorScheme.secondary,
                  textColor: textColor,
                  mutedTextColor: mutedTextColor,
                ),
                const SizedBox(width: 10),
                _summaryItem(
                  context,
                  icon: Icons.tab_rounded,
                  label: strings.windows,
                  value: '$windowCount',
                  textColor: textColor,
                  mutedTextColor: mutedTextColor,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required Color textColor,
    required Color mutedTextColor,
    Color? accent,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = accent ?? colorScheme.primary;
    return Expanded(
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(icon, size: 17, color: color),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: textColor,
                  ),
                ),
                Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    color: mutedTextColor,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Color _healthColor(BuildContext context, ServerHealthLevel level) {
    final colorScheme = Theme.of(context).colorScheme;
    return switch (level) {
      ServerHealthLevel.healthy => colorScheme.secondary,
      ServerHealthLevel.warning => Colors.orangeAccent.shade700,
      ServerHealthLevel.critical => colorScheme.error,
      ServerHealthLevel.unknown => colorScheme.onSurfaceVariant,
    };
  }

  IconData _healthIcon(ServerHealthLevel level) {
    return switch (level) {
      ServerHealthLevel.healthy => Icons.verified_rounded,
      ServerHealthLevel.warning => Icons.warning_amber_rounded,
      ServerHealthLevel.critical => Icons.error_rounded,
      ServerHealthLevel.unknown => Icons.help_outline_rounded,
    };
  }

  String _healthLabel(AppStrings strings, ServerHealthLevel level) {
    final en = strings.language == AppLanguage.en;
    return switch (level) {
      ServerHealthLevel.healthy => en ? 'Healthy' : '正常',
      ServerHealthLevel.warning => en ? 'Warning' : '警告',
      ServerHealthLevel.critical => en ? 'Critical' : '危险',
      ServerHealthLevel.unknown => en ? 'No samples' : '暂无采样',
    };
  }

  Color _panelColor(BuildContext context) {
    return Theme.of(context).colorScheme.surface;
  }

  Color _panelBorderColor(BuildContext context) {
    return Theme.of(context).colorScheme.outlineVariant;
  }

  Color _panelTextColor(BuildContext context) {
    return Theme.of(context).colorScheme.onSurface;
  }

  Color _panelMutedTextColor(BuildContext context) {
    return Theme.of(context).colorScheme.onSurfaceVariant;
  }

  List<BoxShadow> _panelShadow(BuildContext context) {
    return const [];
  }

  IconData _getStatusIcon(ConnectionConfig conn, SshConnectionState? state) {
    if (state != null) {
      if (state == SshConnectionState.connected) return Icons.link;
      if (state == SshConnectionState.connecting) return Icons.sync;
      return Icons.link_off;
    }
    return Icons.dns_outlined;
  }

  Future<void> _openNewTerminal(
    BuildContext context,
    ConnectionConfig conn,
  ) async {
    final windowName = await _askWindowName(context, conn.id);
    if (!context.mounted || windowName == null) return;
    await _openNewTerminalWithOptions(context, conn, windowName);
  }

  Future<void> _openNewTerminalWithOptions(
    BuildContext context,
    ConnectionConfig conn,
    String windowName,
  ) async {
    final ssh = context.read<SshService>();
    final strings = AppStrings(context.read<AppSettings>().language);

    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (ctx) => ConnectionProgressDialog(
        title: strings.connectingTo(conn.name),
        message: strings.establishingConnection,
      ),
    );

    await waitForConnectionProgressFrame();
    if (!context.mounted) return;

    final sessionId = await ssh.openSession(conn.id, displayName: windowName);
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (sessionId != null) {
      Navigator.pushNamed(
        context,
        '/terminal',
        arguments: {
          'id': conn.id,
          'sessionId': sessionId,
        },
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_formatConnectionFailure(ssh.errorMessage)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
  }

  Future<String?> _askWindowName(
    BuildContext context,
    String connectionId,
  ) async {
    final ssh = context.read<SshService>();
    return showDialog<String>(
      context: context,
      builder: (_) => WindowNameDialog(
        initialName: ssh.defaultDisplayNameForConnection(connectionId),
        isNameAvailable: ssh.isSessionNameAvailable,
      ),
    );
  }

  String _formatConnectionFailure(String? message) {
    final strings = AppStrings(context.read<AppSettings>().language);
    final text = message ?? strings.unknown;
    final lower = text.toLowerCase();
    if (lower.contains('tmux is not installed') ||
        lower.contains('unable to check tmux')) {
      return strings.tmuxMissingHint(text);
    }
    return strings.connectionFailed(text);
  }

  void _handleAction(
    BuildContext context,
    ConnectionConfig conn,
    String action,
  ) {
    switch (action) {
      case 'edit':
        Navigator.pushNamed(context, '/edit', arguments: conn.id);
        break;
      case 'delete':
        _confirmDelete(context, conn);
        break;
    }
  }

  void _toggleConnectionWindows(String connectionId) {
    setState(() {
      if (_expandedConnectionWindowIds.contains(connectionId)) {
        _expandedConnectionWindowIds.remove(connectionId);
      } else {
        _expandedConnectionWindowIds.add(connectionId);
      }
    });
  }

  void _confirmDelete(BuildContext context, ConnectionConfig conn) {
    final strings = AppStrings(context.read<AppSettings>().language);
    final storage = context.read<StorageService>();
    final ssh = context.read<SshService>();
    final sftp = context.read<SftpService>();
    final performance = context.read<PerformanceMonitorService>();

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.deleteConnectionTitle),
        content: Text(strings.deleteConnectionContent(conn.name)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await ssh.disconnectSessionsForConnection(conn.id);
              await sftp.disconnectConnection(conn.id, forgetPath: true);
              performance.stopForConnection(conn.id);
              await storage.deleteConnection(conn.id);
            },
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
  }

  void _addConnection(BuildContext context) {
    Navigator.pushNamed(context, '/add');
  }

  void _toggleServerSelection(String id) {
    setState(() {
      if (_selectedServerIds.contains(id)) {
        _selectedServerIds.remove(id);
        if (_selectedServerIds.isEmpty) {
          _serverSelectionMode = false;
        }
      } else {
        _selectedServerIds.add(id);
      }
    });
  }

  Future<void> _confirmBatchDelete(
    BuildContext context,
    AppStrings strings,
  ) async {
    final ids = _selectedServerIds.toList(growable: false);
    if (ids.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.deleteConnectionTitle),
        content: Text(
          strings.language == AppLanguage.en
              ? 'Delete ${ids.length} selected server${ids.length == 1 ? '' : 's'}? Passwords and private keys will also be removed.'
              : '确定删除选中的 $ids 台服务器吗？密码和私钥也会一并清除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final storage = context.read<StorageService>();
    final ssh = context.read<SshService>();
    final sftp = context.read<SftpService>();
    final performance = context.read<PerformanceMonitorService>();
    for (final id in ids) {
      await ssh.disconnectSessionsForConnection(id);
      await sftp.disconnectConnection(id, forgetPath: true);
      performance.stopForConnection(id);
    }
    await storage.deleteConnections(ids);
    if (!mounted) return;
    setState(() {
      _serverSelectionMode = false;
      _selectedServerIds.clear();
    });
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
