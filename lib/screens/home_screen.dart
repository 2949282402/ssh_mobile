import 'dart:async';
import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';

import '../models/connection.dart';
import '../services/app_settings.dart';
import '../services/sftp_service.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../utils/responsive.dart';
import '../widgets/connection_progress_dialog.dart';
import '../widgets/window_name_dialog.dart';
import 'developer_log_screen.dart';
import 'llm_chat_screen.dart';
import 'sftp_screen.dart';
import 'terminal_windows_screen.dart';

extension _HomeSettingsStrings on AppStrings {
  String get settings => language == AppLanguage.en ? 'Settings' : '设置';
  String get appearance => language == AppLanguage.en ? 'Appearance' : '外观';
  String get dataBackup => language == AppLanguage.en ? 'Data backup' : '数据备份';
  String get exportAppData =>
      language == AppLanguage.en ? 'Export app data' : '导出应用数据';
  String get importAppData =>
      language == AppLanguage.en ? 'Import app data' : '导入应用数据';
  String get exportComplete =>
      language == AppLanguage.en ? 'Export complete' : '导出完成';
  String get importComplete =>
      language == AppLanguage.en ? 'Import complete' : '导入完成';
  String get importAction => language == AppLanguage.en ? 'Import' : '导入';
  String get importAppDataWarning => language == AppLanguage.en
      ? 'Importing will replace saved servers, window history, AI chats, AI settings, and custom skills. Passwords, private keys, and API keys must be configured again. Continue?'
      : '导入会替换当前设备上的服务器、窗口历史、AI 聊天、AI 设置和自定义 Skills。密码、私钥和 API Key 需要重新配置。是否继续？';
  String get backupContainsSecrets => language == AppLanguage.en
      ? 'Passwords, private keys, and API keys are not exported. Reconfigure them after import.'
      : '密码、私钥和 API Key 不会导出，导入后需要重新配置。';
  String exportFailed(Object error) =>
      language == AppLanguage.en ? 'Export failed: $error' : '导出失败：$error';
  String importFailed(Object error) =>
      language == AppLanguage.en ? 'Import failed: $error' : '导入失败：$error';
}

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
  static const int _windowPage = 2;
  static const int _sftpPage = 3;
  static const int _logPage = 4;
  static const int _firstPage = _aiPage;
  static const int _lastPage = _logPage;

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  late final PageController _pageController;
  late int _selectedIndex;
  late int _settledIndex;
  Timer? _bottomNavCollapseTimer;
  bool _bottomNavExpanded = true;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex.clamp(_firstPage, _lastPage);
    _settledIndex = _selectedIndex;
    _pageController = PageController(initialPage: _selectedIndex);
    _scheduleBottomNavCollapse();
  }

  @override
  void dispose() {
    _bottomNavCollapseTimer?.cancel();
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final storageReady = context.select<StorageService, bool>(
      (storage) => storage.initialized,
    );
    final connections = context.select<StorageService, List<ConnectionConfig>>(
      (storage) => storage.connections,
    );
    final sessions = context.select<SshService, List<SshSession>>(
      (ssh) => ssh.sessions,
    );
    final settings = context.watch<AppSettings>();
    final strings = AppStrings(settings.language);
    final desktop = isDesktopLayout(context);
    final content = NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (desktop || notification.metrics.axis != Axis.horizontal) {
          return false;
        }
        if (notification is ScrollStartNotification) {
          _showBottomNav();
        } else if (notification is ScrollEndNotification) {
          _scheduleBottomNavCollapse();
        }
        return false;
      },
      child: PageView.builder(
        controller: _pageController,
        itemCount: _lastPage + 1,
        allowImplicitScrolling: false,
        onPageChanged: (index) {
          setState(() {
            _selectedIndex = index;
            _settledIndex = index;
          });
          if (!desktop) _scheduleBottomNavCollapse();
        },
        itemBuilder: (context, index) => _buildPage(
          context,
          index,
          storageReady,
          connections,
          sessions,
          strings,
        ),
      ),
    );

    return Scaffold(
      key: _scaffoldKey,
      endDrawerEnableOpenDragGesture: false,
      endDrawer: _SettingsPanel(
        onExport: () => _exportAppData(context, strings),
        onImport: () => _importAppData(context, strings),
      ),
      appBar: AppBar(
        title: Text(_appTitle),
        actions: [
          IconButton(
            tooltip: strings.settings,
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
          ),
        ],
      ),
      body: desktop
          ? _buildDesktopShell(context, content, sessions, strings)
          : content,
      floatingActionButton: _selectedIndex == _serverPage
          ? FloatingActionButton(
              onPressed: () => _addConnection(context),
              tooltip: strings.addConnection,
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar:
          desktop ? null : _buildBottomNavigation(context, sessions, strings),
    );
  }

  Widget _buildDesktopShell(
    BuildContext context,
    Widget content,
    List<SshSession> sessions,
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
              icon: _windowIcon(sessions, selected: false),
              selectedIcon: _windowIcon(sessions, selected: true),
              label: Text(strings.windows),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.folder_open_outlined),
              selectedIcon: const Icon(Icons.folder_open_rounded),
              label: Text(strings.sftp),
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
    List<SshSession> sessions,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final textScale =
        MediaQuery.textScalerOf(context).scale(1).clamp(1.0, 2.0).toDouble();
    final expandedHeight = 76.0 + (textScale - 1.0) * 28.0;
    return Material(
      color: colorScheme.surface,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: _bottomNavExpanded ? expandedHeight : 22,
          // Do not animate the height here. During expansion Flutter would lay
          // out the full navigation Row inside the previous 22 px collapsed
          // height, which produces transient RenderFlex overflow reports.
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 140),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeOutCubic,
            child: _bottomNavExpanded
                ? Row(
                    key: const ValueKey('bottom-nav-expanded'),
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
                        icon: _windowIcon(sessions, selected: false),
                        selectedIcon: _windowIcon(sessions, selected: true),
                        label: strings.windows,
                      ),
                      _bottomNavItem(
                        context,
                        index: 3,
                        icon: const Icon(Icons.folder_open_outlined),
                        selectedIcon: const Icon(Icons.folder_open_rounded),
                        label: strings.sftp,
                      ),
                    ],
                  )
                : InkWell(
                    key: const ValueKey('bottom-nav-collapsed'),
                    onTap: _showBottomNav,
                    child: Center(
                      child: Container(
                        width: 46,
                        height: 5,
                        decoration: BoxDecoration(
                          color: colorScheme.onSurfaceVariant
                              .withValues(alpha: 0.46),
                          borderRadius: BorderRadius.circular(999),
                        ),
                      ),
                    ),
                  ),
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
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: 64,
                height: 32,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: selected
                      ? colorScheme.primary.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: IconTheme(
                  data: IconThemeData(color: foreground, size: 24),
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
                      fontSize: 12,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _windowIcon(List<SshSession> sessions, {required bool selected}) {
    final icon = Icon(selected ? Icons.tab_rounded : Icons.tab_outlined);
    if (sessions.isEmpty) return icon;
    return Badge(label: Text('${sessions.length}'), child: icon);
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
      case _windowPage:
        return 2;
      case _sftpPage:
        return 3;
      case _logPage:
        return null;
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
        _switchPage(_windowPage);
        break;
      case 3:
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
    _showBottomNav();
    setState(() => _selectedIndex = index);
    _pageController.animateToPage(
      index,
      duration: const Duration(milliseconds: 260),
      curve: Curves.easeOutCubic,
    );
  }

  void _showBottomNav() {
    _bottomNavCollapseTimer?.cancel();
    if (!_bottomNavExpanded && mounted) {
      setState(() => _bottomNavExpanded = true);
    }
  }

  void _scheduleBottomNavCollapse() {
    _bottomNavCollapseTimer?.cancel();
    _bottomNavCollapseTimer = Timer(const Duration(milliseconds: 1500), () {
      if (mounted && _bottomNavExpanded) {
        setState(() => _bottomNavExpanded = false);
      }
    });
  }

  Widget _buildPage(
    BuildContext context,
    int index,
    bool storageReady,
    List<ConnectionConfig> connections,
    List<SshSession> sessions,
    AppStrings strings,
  ) {
    switch (index) {
      case _aiPage:
        return _pageShell(index, LlmChatScreen(active: _settledIndex == index));
      case _serverPage:
        return _pageShell(
          index,
          _buildServerPage(
              context, storageReady, connections, sessions, strings),
        );
      case _windowPage:
        return _pageShell(index, const TerminalWindowsPage());
      case _sftpPage:
        return _pageShell(index, const SftpScreen());
      case _logPage:
      default:
        return _pageShell(index, const DeveloperLogPage());
    }
  }

  Widget _pageShell(int index, Widget child) {
    return RepaintBoundary(child: child);
  }

  Future<void> _exportAppData(
    BuildContext context,
    AppStrings strings,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
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
      await context
          .read<StorageService>()
          .importAppDataJson(utf8.decode(bytes));
      if (!context.mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(strings.importComplete)),
      );
      _switchPage(_serverPage);
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

  Widget _buildServerPage(
    BuildContext context,
    bool storageReady,
    List<ConnectionConfig> connections,
    List<SshSession> sessions,
    AppStrings strings,
  ) {
    return connections.isEmpty
        ? storageReady
            ? _buildEmptyState(context, strings)
            : _buildLoadingState()
        : _buildConnectionList(context, connections, sessions, strings);
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
    List<SshSession> sessions,
    AppStrings strings,
  ) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= AppBreakpoints.desktop;
        final columns = constraints.maxWidth >= AppBreakpoints.wideDesktop
            ? 3
            : desktop
                ? 2
                : 1;
        final horizontalPadding = desktop ? 24.0 : 12.0;
        final maxContentWidth = desktop ? 1480.0 : double.infinity;

        return Center(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: maxContentWidth),
            child: CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: EdgeInsets.fromLTRB(
                    horizontalPadding,
                    desktop ? 18 : 8,
                    horizontalPadding,
                    0,
                  ),
                  sliver: SliverToBoxAdapter(
                    child: _buildOverviewHeader(
                      context,
                      connections,
                      sessions,
                      strings,
                    ),
                  ),
                ),
                if (columns == 1)
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      0,
                      horizontalPadding,
                      88,
                    ),
                    sliver: SliverList.separated(
                      itemCount: connections.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) => _buildConnectionCard(
                        context,
                        connections[index],
                        sessions,
                        strings,
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: EdgeInsets.fromLTRB(
                      horizontalPadding,
                      0,
                      horizontalPadding,
                      88,
                    ),
                    sliver: SliverGrid(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) => _buildConnectionCard(
                          context,
                          connections[index],
                          sessions,
                          strings,
                        ),
                        childCount: connections.length,
                      ),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: columns,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                        mainAxisExtent: 108,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildConnectionCard(
    BuildContext context,
    ConnectionConfig conn,
    List<SshSession> sessions,
    AppStrings strings,
  ) {
    final relatedSessions =
        sessions.where((session) => session.connectionId == conn.id).toList();
    final isActive = relatedSessions.any((session) => session.isConnected);
    final sessionCount = relatedSessions.length;
    final latestSession = relatedSessions.isEmpty ? null : relatedSessions.last;
    final isConnecting = latestSession?.state == SshConnectionState.connecting;
    final colorScheme = Theme.of(context).colorScheme;
    final primary = colorScheme.primary;
    final success = colorScheme.secondary;
    final cardColor = _panelColor(context);
    final textColor = _panelTextColor(context);
    final mutedTextColor = _panelMutedTextColor(context);
    final borderColor =
        isActive ? success.withValues(alpha: 0.42) : _panelBorderColor(context);

    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _connectToServer(context, conn),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cardColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
          boxShadow: _panelShadow(context),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: isActive
                    ? success.withValues(alpha: 0.15)
                    : primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                _getStatusIcon(conn, latestSession),
                color: isActive ? success : primary,
                size: 24,
              ),
            ),
            const SizedBox(width: 14),
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
                      Expanded(
                        child: Text(
                          '${conn.username}@${conn.host}:${conn.port}',
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            color: mutedTextColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (isConnecting)
              const SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: mutedTextColor),
                onSelected: (action) => _handleAction(context, conn, action),
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'new_terminal',
                    child: Row(
                      children: [
                        const Icon(Icons.add_to_photos, size: 18),
                        const SizedBox(width: 8),
                        Text(strings.newWindow),
                      ],
                    ),
                  ),
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
                        const Icon(Icons.delete, size: 18, color: Colors.red),
                        const SizedBox(width: 8),
                        Text(
                          strings.delete,
                          style: const TextStyle(color: Colors.red),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            if (sessionCount > 0) ...[
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: success.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(color: success.withValues(alpha: 0.35)),
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
          ],
        ),
      ),
    );
  }

  Widget _buildOverviewHeader(
    BuildContext context,
    List<ConnectionConfig> connections,
    List<SshSession> sessions,
    AppStrings strings,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cardColor = _panelColor(context);
    final textColor = _panelTextColor(context);
    final mutedTextColor = _panelMutedTextColor(context);
    final activeConnectionIds = sessions
        .where((session) => session.isConnected)
        .map((session) => session.connectionId)
        .toSet();
    final activeCount = connections
        .where((conn) => activeConnectionIds.contains(conn.id))
        .length;
    final windowCount = sessions.length;

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Container(
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

  Color _panelColor(BuildContext context) {
    final isDarkMode = context.read<AppSettings>().isDarkMode;
    return isDarkMode ? const Color(0xFF161B22) : Colors.white;
  }

  Color _panelBorderColor(BuildContext context) {
    final isDarkMode = context.read<AppSettings>().isDarkMode;
    return isDarkMode ? const Color(0xFF30363D) : const Color(0xFFE0E0E0);
  }

  Color _panelTextColor(BuildContext context) {
    final isDarkMode = context.read<AppSettings>().isDarkMode;
    return isDarkMode ? const Color(0xFFE6EDF3) : const Color(0xFF1F1F1F);
  }

  Color _panelMutedTextColor(BuildContext context) {
    final isDarkMode = context.read<AppSettings>().isDarkMode;
    return isDarkMode ? const Color(0xFF9AA4AF) : const Color(0xFF666666);
  }

  List<BoxShadow> _panelShadow(BuildContext context) {
    if (context.read<AppSettings>().isDarkMode) {
      return const [];
    }
    return [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.06),
        blurRadius: 16,
        offset: const Offset(0, 8),
      ),
    ];
  }

  IconData _getStatusIcon(ConnectionConfig conn, SshSession? session) {
    if (session != null) {
      if (session.state == SshConnectionState.connected) return Icons.link;
      if (session.state == SshConnectionState.connecting) return Icons.sync;
      return Icons.link_off;
    }
    return Icons.dns_outlined;
  }

  void _connectToServer(BuildContext context, ConnectionConfig conn) {
    final ssh = context.read<SshService>();

    final existing = ssh.latestSessionForConnection(conn.id);
    if (existing?.isConnected == true ||
        (existing != null && conn.launchMode == TerminalLaunchMode.tmux)) {
      Navigator.pushNamed(
        context,
        '/terminal',
        arguments: {
          'id': conn.id,
          'sessionId': existing!.id,
        },
      );
      return;
    }

    _openNewTerminal(context, conn);
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
          backgroundColor: Colors.redAccent,
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
      case 'new_terminal':
        _openNewTerminal(context, conn);
        break;
      case 'edit':
        Navigator.pushNamed(context, '/edit', arguments: conn.id);
        break;
      case 'delete':
        _confirmDelete(context, conn);
        break;
    }
  }

  void _confirmDelete(BuildContext context, ConnectionConfig conn) {
    final strings = AppStrings(context.read<AppSettings>().language);
    final storage = context.read<StorageService>();
    final ssh = context.read<SshService>();
    final sftp = context.read<SftpService>();

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
              await storage.deleteConnection(conn.id);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.delete),
          ),
        ],
      ),
    );
  }

  void _addConnection(BuildContext context) {
    Navigator.pushNamed(context, '/add');
  }
}

class _SettingsPanel extends StatelessWidget {
  final VoidCallback onExport;
  final VoidCallback onImport;

  const _SettingsPanel({
    required this.onExport,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final strings = AppStrings(settings.language);
    final colorScheme = Theme.of(context).colorScheme;
    return Drawer(
      child: SafeArea(
        child: ListTileTheme(
          dense: true,
          minLeadingWidth: 28,
          horizontalTitleGap: 10,
          iconColor: colorScheme.onSurfaceVariant,
          child: DefaultTextStyle.merge(
            style: const TextStyle(fontSize: 13),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.settings_outlined,
                      color: colorScheme.primary,
                      size: 21,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        strings.settings,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _SettingsSection(
                  title: strings.appearance,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.translate_rounded, size: 20),
                      title: Text(
                        settings.isEnglish
                            ? strings.switchToChinese
                            : strings.switchToEnglish,
                        style: const TextStyle(fontSize: 13),
                      ),
                      onTap: settings.toggleLanguage,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      secondary: Icon(
                        settings.isDarkMode
                            ? Icons.dark_mode
                            : Icons.light_mode,
                        size: 20,
                      ),
                      title: Text(
                        settings.isDarkMode
                            ? strings.switchToLightMode
                            : strings.switchToDarkMode,
                        style: const TextStyle(fontSize: 13),
                      ),
                      value: settings.isDarkMode,
                      onChanged: (_) => settings.toggleTheme(),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _SettingsSection(
                  title: strings.dataBackup,
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.upload_file_outlined, size: 20),
                      title: Text(
                        strings.exportAppData,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        strings.backupContainsSecrets,
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: onExport,
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.download_for_offline_outlined,
                        size: 20,
                      ),
                      title: Text(
                        strings.importAppData,
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        strings.importAppDataWarning,
                        style: const TextStyle(fontSize: 11),
                      ),
                      onTap: onImport,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  final String title;
  final List<Widget> children;

  const _SettingsSection({
    required this.title,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
            child: Text(
              title,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 11,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          ...children,
        ],
      ),
    );
  }
}
