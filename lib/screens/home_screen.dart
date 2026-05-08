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

class HomeScreen extends StatefulWidget {
  final int initialIndex;

  const HomeScreen({super.key, this.initialIndex = 1});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const int _logPage = 0;
  static const int _serverPage = 1;
  static const int _sftpPage = 2;
  static const int _windowPage = 3;
  static const int _aiPage = 4;

  late final PageController _pageController;
  late int _selectedIndex;

  @override
  void initState() {
    super.initState();
    _selectedIndex = widget.initialIndex.clamp(_logPage, _aiPage);
    _pageController = PageController(initialPage: _selectedIndex);
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final storage = context.watch<StorageService>();
    final ssh = context.watch<SshService>();
    final settings = context.watch<AppSettings>();
    final strings = AppStrings(settings.language);
    final connections = storage.connections;
    final desktop = isDesktopLayout(context);
    final content = PageView(
      controller: _pageController,
      onPageChanged: (index) => setState(() => _selectedIndex = index),
      children: [
        const DeveloperLogPage(),
        connections.isEmpty
            ? storage.initialized
                ? _buildEmptyState(context, strings)
                : _buildLoadingState()
            : _buildConnectionList(context, connections, ssh, strings),
        const SftpScreen(),
        const TerminalWindowsPage(),
        const LlmChatScreen(),
      ],
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(
          _appTitle,
          style: TextStyle(fontWeight: FontWeight.w700),
        ),
        actions: [
          TextButton(
            onPressed: settings.toggleLanguage,
            child: Text(
              settings.isEnglish
                  ? strings.switchToEnglish
                  : strings.switchToChinese,
            ),
          ),
          IconButton(
            icon: Icon(
              settings.isDarkMode ? Icons.dark_mode : Icons.light_mode,
            ),
            tooltip: settings.isDarkMode
                ? strings.switchToLightMode
                : strings.switchToDarkMode,
            onPressed: () => settings.toggleTheme(),
          ),
        ],
      ),
      body: desktop
          ? _buildDesktopShell(context, content, ssh, strings)
          : content,
      floatingActionButton: _selectedIndex == _serverPage
          ? FloatingActionButton(
              onPressed: () => _addConnection(context),
              tooltip: strings.addConnection,
              child: const Icon(Icons.add),
            )
          : null,
      bottomNavigationBar:
          desktop ? null : _buildBottomNavigation(context, ssh, strings),
    );
  }

  Widget _buildDesktopShell(
    BuildContext context,
    Widget content,
    SshService ssh,
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
          backgroundColor: colorScheme.surface,
          indicatorColor: colorScheme.primary.withValues(alpha: 0.12),
          selectedIconTheme: IconThemeData(color: colorScheme.primary),
          unselectedIconTheme:
              IconThemeData(color: colorScheme.onSurfaceVariant),
          selectedLabelTextStyle: TextStyle(
            color: colorScheme.primary,
            fontWeight: FontWeight.w800,
          ),
          unselectedLabelTextStyle: TextStyle(
            color: colorScheme.onSurfaceVariant,
            fontWeight: FontWeight.w600,
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
              icon: _windowIcon(ssh, selected: false),
              selectedIcon: _windowIcon(ssh, selected: true),
              label: Text(strings.windows),
            ),
            NavigationRailDestination(
              icon: const Icon(Icons.smart_toy_outlined),
              selectedIcon: const Icon(Icons.smart_toy_rounded),
              label: Text(settingsLabelAi(context)),
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
    SshService ssh,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 80,
          child: Row(
            children: [
              _bottomNavItem(
                context,
                index: 0,
                icon: const Icon(Icons.dns_outlined),
                selectedIcon: const Icon(Icons.dns_rounded),
                label: strings.servers,
              ),
              _bottomNavItem(
                context,
                index: 1,
                icon: const Icon(Icons.folder_open_outlined),
                selectedIcon: const Icon(Icons.folder_open_rounded),
                label: strings.sftp,
              ),
              _bottomNavItem(
                context,
                index: 2,
                icon: _windowIcon(ssh, selected: false),
                selectedIcon: _windowIcon(ssh, selected: true),
                label: strings.windows,
              ),
              _bottomNavItem(
                context,
                index: 3,
                icon: const Icon(Icons.smart_toy_outlined),
                selectedIcon: const Icon(Icons.smart_toy_rounded),
                label: settingsLabelAi(context),
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
                    ? colorScheme.secondaryContainer
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(16),
              ),
              child: IconTheme(
                data: IconThemeData(color: foreground, size: 24),
                child: selected ? selectedIcon : icon,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: foreground,
                fontSize: 12,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _windowIcon(SshService ssh, {required bool selected}) {
    final icon = Icon(selected ? Icons.tab_rounded : Icons.tab_outlined);
    if (ssh.sessions.isEmpty) return icon;
    return Badge(label: Text('${ssh.sessions.length}'), child: icon);
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
      case _logPage:
        return null;
      case _sftpPage:
        return 1;
      case _windowPage:
        return 2;
      case _aiPage:
        return 3;
      case _serverPage:
      default:
        return 0;
    }
  }

  void _switchNavigationPage(int index) {
    switch (index) {
      case 0:
        _switchPage(_serverPage);
        break;
      case 1:
        _switchPage(_sftpPage);
        break;
      case 2:
        _switchPage(_windowPage);
        break;
      case 3:
      default:
        _switchPage(_aiPage);
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

  Widget _buildLoadingState() {
    return const Center(
      child: SizedBox(
        width: 28,
        height: 28,
        child: CircularProgressIndicator(strokeWidth: 2),
      ),
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
    SshService ssh,
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
                      ssh,
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
                        ssh,
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
                          ssh,
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
    SshService ssh,
    AppStrings strings,
  ) {
    final isActive = ssh.hasConnectedSession(conn.id);
    final sessionCount = ssh.sessionCountForConnection(conn.id);
    final isConnecting = ssh.latestSessionForConnection(conn.id)?.state ==
        SshConnectionState.connecting;
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
                _getStatusIcon(conn, ssh),
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
    SshService ssh,
    AppStrings strings,
  ) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final cardColor = _panelColor(context);
    final textColor = _panelTextColor(context);
    final mutedTextColor = _panelMutedTextColor(context);
    final activeCount =
        connections.where((conn) => ssh.hasConnectedSession(conn.id)).length;
    final windowCount = ssh.sessions.length;

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

  IconData _getStatusIcon(ConnectionConfig conn, SshService ssh) {
    final session = ssh.latestSessionForConnection(conn.id);
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
