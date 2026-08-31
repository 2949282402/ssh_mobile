part of '../home_screen.dart';

class ServerListPane extends StatefulWidget {
  const ServerListPane({super.key});

  @override
  State<ServerListPane> createState() => _ServerListPaneState();
}

class _ServerListPaneState extends State<ServerListPane> {
  bool _serverSelectionMode = false;
  final Set<String> _selectedServerIds = {};
  final Set<String> _expandedConnectionWindowIds = {};

  void _updateState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final storageReady = context.select<ConnectionViewModel, bool>(
      (vm) => vm.isLoading == false,
    );
    final connections = context
        .select<ConnectionViewModel, List<ConnectionConfig>>(
          (vm) => vm.connections,
        );

    if (connections.isNotEmpty) {
      return _buildConnectionList(context, connections, strings);
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= AppBreakpoints.desktop;
        final horizontalPadding = desktop
            ? AppTheme.pagePadding
            : AppTheme.compactPagePadding;
        return Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(
                horizontalPadding,
                desktop ? 20 : 12,
                horizontalPadding,
                8,
              ),
              child: _buildOverviewHeader(context, connections, strings),
            ),
            Expanded(
              child: storageReady
                  ? _ServerEmptyState(strings: strings)
                  : AppSkeletonizer.zone(
                      enabled: true,
                      semanticsLabel: strings.loadingServers,
                      child: const _ServerSkeletonList(),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildConnectionList(
    BuildContext context,
    List<ConnectionConfig> connections,
    AppStrings strings,
  ) {
    final layoutMode = context.select<AppSettings, String>(
      (settings) => settings.serverListLayoutMode,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final desktop = constraints.maxWidth >= AppBreakpoints.desktop;
        final horizontalPadding = desktop
            ? AppTheme.pagePadding
            : AppTheme.compactPagePadding;
        final maxContentWidth = desktop ? 1480.0 : double.infinity;
        final isGrid =
            layoutMode == 'grid' &&
            supportsServerGridForWidth(constraints.maxWidth);
        final mobileMetrics = mobileUiMetricsOf(context);
        final navigationClearance = desktop
            ? 0.0
            : mobileMetrics.navigationHeight +
                  mobileMetrics.navigationBottomInset;
        final scrollBottomPadding = desktop
            ? 24.0
            : navigationClearance +
                  MediaQuery.viewPaddingOf(context).bottom +
                  16;

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
                child: _buildOverviewHeader(context, connections, strings),
              ),
              Expanded(
                child: isGrid
                    ? GridView.builder(
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          0,
                          horizontalPadding,
                          scrollBottomPadding,
                        ),
                        gridDelegate:
                            const SliverGridDelegateWithMaxCrossAxisExtent(
                              maxCrossAxisExtent: 480,
                              crossAxisSpacing: 12,
                              mainAxisSpacing: 12,
                              // Keep health details and action buttons visible
                              // at the 1.3x accessibility text scale used by
                              // the app shell; 190px clips the card content.
                              mainAxisExtent: 210,
                            ),
                        itemCount: connections.length,
                        itemBuilder: (context, index) => _buildConnectionCard(
                          context,
                          connections[index],
                          strings,
                          connIndex: index,
                          isGrid: true,
                        ),
                      )
                    : ReorderableListView.builder(
                        buildDefaultDragHandles: false,
                        scrollCacheExtent: const ScrollCacheExtent.pixels(
                          700.0,
                        ),
                        padding: EdgeInsets.fromLTRB(
                          horizontalPadding,
                          0,
                          horizontalPadding,
                          scrollBottomPadding,
                        ),
                        itemCount: connections.length,
                        itemBuilder: (context, index) => _buildConnectionCard(
                          context,
                          connections[index],
                          strings,
                          connIndex: index,
                          isGrid: false,
                        ),
                        onReorderItem: (oldIndex, newIndex) {
                          context
                              .read<ConnectionViewModel>()
                              .reorderConnections(oldIndex, newIndex);
                        },
                      ),
              ),
              if (_serverSelectionMode)
                Padding(
                  padding: EdgeInsets.only(bottom: navigationClearance),
                  child: _buildSelectionBar(context, strings),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildSelectionBar(BuildContext context, AppStrings strings) {
    return _ServerSelectionBar(
      strings: strings,
      selectedServerIds: _selectedServerIds,
      onCancel: () {
        _updateState(() {
          _serverSelectionMode = false;
          _selectedServerIds.clear();
        });
      },
      onDelete: () => _confirmBatchDelete(context, strings),
    );
  }

  Widget _buildConnectionCard(
    BuildContext context,
    ConnectionConfig conn,
    AppStrings strings, {
    int connIndex = 0,
    required bool isGrid,
  }) {
    final windowsExpanded = _expandedConnectionWindowIds.contains(conn.id);
    final isSelected = _selectedServerIds.contains(conn.id);
    return RepaintBoundary(
      key: ValueKey('server-card-${conn.id}'),
      child: Selector<SshService, SshConnectionOverview>(
        key: ValueKey(conn.id),
        selector: (_, ssh) => ssh.serverOverviewSnapshot.forConnection(conn.id),
        builder: (context, sessionSummary, _) => _ServerConnectionCard(
          conn: conn,
          sessionSummary: sessionSummary,
          strings: strings,
          connIndex: connIndex,
          isSelected: isSelected,
          serverSelectionMode: _serverSelectionMode,
          windowsExpanded: windowsExpanded,
          isGrid: isGrid,
          onTap: !_serverSelectionMode
              ? () => _openNewTerminal(context, conn)
              : () => _toggleServerSelection(conn.id),
          onLongPress: () {
            if (!_serverSelectionMode) {
              _updateState(() {
                _serverSelectionMode = true;
                _selectedServerIds.add(conn.id);
              });
            }
          },
          onSelectedChanged: (_) => _toggleServerSelection(conn.id),
          onOpenNewTerminal: () => _openNewTerminal(context, conn),
          onToggleConnectionWindows: () => _toggleConnectionWindows(conn.id),
          onAction: (action) => _handleAction(context, conn, action),
        ),
      ),
    );
  }

  Future<void> _openNewTerminal(
    BuildContext context,
    ConnectionConfig conn,
  ) async {
    final ssh = context.read<SshService>();
    final windowName = ssh.defaultDisplayNameForConnection(conn.id);
    await _openNewTerminalWithOptions(context, conn, windowName);
  }

  Future<void> _openNewTerminalWithOptions(
    BuildContext context,
    ConnectionConfig conn,
    String windowName,
  ) async {
    final connectionVm = context.read<ConnectionViewModel>();
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

    final sessionId = await connectionVm.openTerminalSession(
      conn.id,
      windowName,
      onUnknownHostKey: (request) =>
          context.read<ConnectionUiAdapter>().confirmHostKey(context, request),
    );
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (sessionId != null) {
      Navigator.pushNamed(
        context,
        '/terminal',
        arguments: {'id': conn.id, 'sessionId': sessionId},
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(_formatConnectionFailure(connectionVm.errorMessage)),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
    }
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
        Navigator.pushNamed(
          context,
          '/edit',
          arguments: AppConnectionEditRouteArguments(
            connectionId: conn.id,
            viewModel: context.read<ConnectionViewModel>(),
          ),
        );
        break;
      case 'delete':
        _confirmDelete(context, conn);
        break;
    }
  }

  void _toggleConnectionWindows(String connectionId) {
    _updateState(() {
      if (_expandedConnectionWindowIds.contains(connectionId)) {
        _expandedConnectionWindowIds.remove(connectionId);
      } else {
        _expandedConnectionWindowIds.add(connectionId);
      }
    });
  }

  void _confirmDelete(BuildContext context, ConnectionConfig conn) {
    final strings = AppStrings(context.read<AppSettings>().language);
    final storage = context.read<ConnectionViewModel>();

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
              await storage.deleteConnectionWithCleanup(conn.id);
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

  void _toggleServerSelection(String id) {
    _updateState(() {
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
              : '确定删除选中的 ${ids.length} 台服务器吗？密码和私钥也会一并清除。',
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
    final storage = context.read<ConnectionViewModel>();
    await storage.deleteConnectionsWithCleanup(ids);
    if (!mounted) return;
    _updateState(() {
      _serverSelectionMode = false;
      _selectedServerIds.clear();
    });
  }

  Widget _buildOverviewHeader(
    BuildContext context,
    List<ConnectionConfig> connections,
    AppStrings strings,
  ) {
    final activeCount = connections.length;
    final colorScheme = Theme.of(context).colorScheme;
    final subtitle = strings.language == AppLanguage.en
        ? '$activeCount saved server${activeCount == 1 ? "" : "s"}'
        : '已保存 $activeCount 台服务器';
    final isDesktopPlatform = isDesktopTargetPlatform();
    final isExpanded = WindowSizeClass.of(context).isExpandedOrLarger;
    final showDesktopAdd = (isDesktopPlatform || isExpanded) && activeCount > 0;
    final layoutMode = context.select<AppSettings, String>(
      (settings) => settings.serverListLayoutMode,
    );
    final layoutMenu = PopupMenuButton<String>(
      tooltip: strings.serverListLayout,
      icon: Icon(
        layoutMode == 'grid' ? Icons.grid_view_rounded : Icons.list_rounded,
      ),
      onSelected: (value) =>
          context.read<AppSettings>().setServerListLayoutMode(value),
      itemBuilder: (context) => [
        CheckedPopupMenuItem<String>(
          value: 'list',
          checked: layoutMode == 'list',
          child: Text(strings.layoutList),
        ),
        CheckedPopupMenuItem<String>(
          value: 'grid',
          checked: layoutMode == 'grid',
          child: Text(strings.layoutGrid),
        ),
      ],
    );

    final Widget? trailing;
    if (_serverSelectionMode) {
      trailing = null;
    } else if (showDesktopAdd) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          layoutMenu,
          FilledButton.icon(
            onPressed: () => Navigator.pushNamed(
              context,
              '/add',
              arguments: context.read<ConnectionViewModel>(),
            ),
            icon: const Icon(Icons.add_rounded),
            label: Text(strings.addConnection),
          ),
        ],
      );
    } else if (!isDesktopPlatform && !isExpanded) {
      trailing = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          layoutMenu,
          IconButton.filledTonal(
            onPressed: () => const OpenSettingsNotification().dispatch(context),
            tooltip: strings.settings,
            style: IconButton.styleFrom(
              minimumSize: const Size.square(48),
              maximumSize: const Size.square(48),
              foregroundColor: colorScheme.primary,
              backgroundColor: colorScheme.primary.withValues(alpha: 0.1),
            ),
            icon: const Icon(Icons.settings_outlined),
          ),
        ],
      );
    } else {
      trailing = layoutMenu;
    }

    return AppPageHeader(
      title: strings.servers,
      subtitle: subtitle,
      icon: Icons.dns_rounded,
      trailing: trailing,
    );
  }
}
