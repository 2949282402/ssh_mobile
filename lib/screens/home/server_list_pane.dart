part of '../home_screen.dart';

extension _HomeScreenStateServerList on _HomeScreenState {
  Widget _buildServerPage(
    BuildContext context,
    AppStrings strings,
  ) {
    final storageReady = context.select<ConnectionViewModel, bool>(
      (vm) => vm.isLoading == false,
    );
    final connections =
        context.select<ConnectionViewModel, List<ConnectionConfig>>(
      (vm) => vm.connections,
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
                borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
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
            const SizedBox(height: 20),
            FilledButton.icon(
              icon: const Icon(Icons.add),
              label: Text(
                  strings.language == AppLanguage.en ? 'Add Server' : '添加服务器'),
              onPressed: () => Navigator.pushNamed(context, '/add'),
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
                  scrollCacheExtent: const ScrollCacheExtent.pixels(700),
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
                  onReorderItem: (oldIndex, newIndex) {
                    final storageNewIndex =
                        newIndex > oldIndex ? newIndex + 1 : newIndex;
                    context
                        .read<ConnectionViewModel>()
                        .reorderConnections(oldIndex, storageNewIndex);
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
    return SafeArea(
      bottom: true,
      top: false,
      child: Container(
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
              strings.language == AppLanguage.en
                  ? '$count selected'
                  : '已选择 $count 台服务器',
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
                updateState(() {
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
      ),
    );
  }

  Widget _buildConnectionCard(
    BuildContext context,
    ConnectionConfig conn,
    AppStrings strings, {
    int connIndex = 0,
  }) {
    return RepaintBoundary(
      key: ValueKey('server-card-${conn.id}'),
      child: Selector<SshService, SshConnectionOverview>(
        key: ValueKey(conn.id),
        selector: (_, ssh) => ssh.serverOverviewSnapshot.forConnection(conn.id),
        builder: (context, sessionSummary, _) => _buildConnectionCardBody(
          context,
          conn,
          sessionSummary,
          strings,
          connIndex: connIndex,
        ),
      ),
    );
  }

  Widget _buildStatusChip(
    BuildContext context,
    SshConnectionState? state,
    SshConnectionOverview sessionSummary,
    AppStrings strings,
  ) {
    final colorScheme = Theme.of(context).colorScheme;
    final success = colorScheme.secondary;

    final Color color;
    final String text;

    if (sessionSummary.hasConnected) {
      color = success;
      text = strings.connected;
    } else if (state == SshConnectionState.connecting) {
      color = colorScheme.primary;
      text = strings.connecting;
    } else if (state == SshConnectionState.error) {
      color = colorScheme.error;
      text = strings.language == AppLanguage.en ? 'Error' : '错误';
    } else {
      color = colorScheme.onSurface.withValues(alpha: 0.4);
      text = strings.disconnected;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.3), width: 1),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
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
    final scale = mobileUiScaleOf(context);
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
    final cardBgColor =
        isSelected ? colorScheme.primary.withValues(alpha: 0.12) : cardColor;
    final activeBorderColor =
        isSelected ? colorScheme.primary.withValues(alpha: 0.54) : borderColor;

    final windowsExpanded = _expandedConnectionWindowIds.contains(conn.id);

    return TactileFeedback(
      onTap:
          !_serverSelectionMode ? () => _openNewTerminal(context, conn) : null,
      onLongPress: () {
        if (!_serverSelectionMode) {
          updateState(() {
            _serverSelectionMode = true;
            _selectedServerIds.add(conn.id);
          });
        }
      },
      child: Container(
        margin: EdgeInsets.only(bottom: 10 * scale),
        padding: EdgeInsets.all(14 * scale),
        decoration: BoxDecoration(
          color: cardBgColor,
          borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
          border: Border.all(
            color: activeBorderColor,
            width: 1,
          ),
          boxShadow: const [],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 第一层：拖拽柄/多选框 + 状态图标 + 名称 + 连接状态 Chip
            Row(
              children: [
                if (!_serverSelectionMode)
                  ReorderableDragStartListener(
                    index: connIndex,
                    child: Padding(
                      padding: EdgeInsets.only(right: 6 * scale),
                      child: Icon(
                        Icons.drag_handle,
                        size: 20 * scale,
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
                  width: 38 * scale,
                  height: 38 * scale,
                  decoration: BoxDecoration(
                    color: isActive
                        ? success.withValues(alpha: 0.15)
                        : isConnecting
                            ? colorScheme.primary.withValues(alpha: 0.1)
                            : latestState == SshConnectionState.error
                                ? colorScheme.error.withValues(alpha: 0.1)
                                : primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                  ),
                  child: Icon(
                    _getStatusIcon(conn, latestState),
                    color: isActive
                        ? success
                        : isConnecting
                            ? colorScheme.primary
                            : latestState == SshConnectionState.error
                                ? colorScheme.error
                                : primary,
                    size: 20 * scale,
                  ),
                ),
                SizedBox(width: 10 * scale),
                Expanded(
                  child: Row(
                    children: [
                      Expanded(
                        child: OverflowScrollText(
                          conn.name,
                          selectable: false,
                          maxLines: 1,
                          style: TextStyle(
                            color: textColor,
                            fontSize: 15 * scale,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      _buildStatusChip(
                          context, latestState, sessionSummary, strings),
                    ],
                  ),
                ),
              ],
            ),
            SizedBox(height: 10 * scale),
            // 第二层：主机信息 + 健康状态
            Padding(
              padding:
                  EdgeInsets.only(left: _serverSelectionMode ? 0 : 26 * scale),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        Icons.dns_outlined,
                        size: 13 * scale,
                        color: mutedTextColor.withValues(alpha: 0.72),
                      ),
                      SizedBox(width: 5 * scale),
                      Flexible(
                        child: Text(
                          '${conn.username}@${conn.host}:${conn.port}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12.5 * scale,
                            color: mutedTextColor,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (conn.id.isNotEmpty) ...[
                    SizedBox(height: 6 * scale),
                    Selector<PerformanceMonitorService, ServerHealthSnapshot>(
                      selector: (_, monitor) => monitor.healthFor(conn.id),
                      builder: (context, health, _) =>
                          _buildHealthChip(context, health, strings),
                    ),
                  ],
                ],
              ),
            ),
            SizedBox(height: 12 * scale),
            Divider(height: 1, color: colorScheme.outlineVariant),
            SizedBox(height: 8 * scale),
            // 第三层：窗口列表整行按钮 + 1个常用操作(连接/打开) + 更多菜单(编辑/删除)
            Row(
              children: [
                Expanded(
                  child: InkWell(
                    onTap: () => _toggleConnectionWindows(conn.id),
                    borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
                    child: Padding(
                      padding: EdgeInsets.symmetric(
                          vertical: 6 * scale, horizontal: 8 * scale),
                      child: Row(
                        children: [
                          Icon(
                            Icons.tab_outlined,
                            size: 16 * scale,
                            color: mutedTextColor,
                          ),
                          SizedBox(width: 6 * scale),
                          Text(
                            strings.language == AppLanguage.en
                                ? 'Windows · $sessionCount'
                                : '窗口列表 · $sessionCount',
                            style: TextStyle(
                              color: textColor,
                              fontSize: 13 * scale,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(width: 4 * scale),
                          Icon(
                            windowsExpanded
                                ? Icons.expand_less_rounded
                                : Icons.expand_more_rounded,
                            color: mutedTextColor,
                            size: 18 * scale,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                if (!_serverSelectionMode) ...[
                  TextButton.icon(
                    icon: Icon(Icons.play_arrow_rounded, size: 18 * scale),
                    label: Text(
                        strings.language == AppLanguage.en ? 'Connect' : '连接'),
                    onPressed: () => _openNewTerminal(context, conn),
                  ),
                  PopupMenuButton<String>(
                    icon: Icon(Icons.more_vert,
                        color: mutedTextColor, size: 18 * scale),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
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
                            Icon(
                              Icons.delete,
                              size: 18,
                              color: colorScheme.error,
                            ),
                            const SizedBox(width: 8),
                            Text(
                              strings.delete,
                              style: TextStyle(color: colorScheme.error),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
            if (windowsExpanded) ...[
              const SizedBox(height: 8),
              TerminalWindowsPage(
                key: PageStorageKey<String>('server-windows-${conn.id}'),
                connectionId: conn.id,
                showHeader: false,
                embedded: true,
              ),
            ],
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
        borderRadius: BorderRadius.circular(AppTheme.radiusPill),
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
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(color: _panelBorderColor(context)),
              boxShadow: const [],
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
              borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
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
          showSshHostKeyTrustDialog(context, request),
    );
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
          content: Text(_formatConnectionFailure(connectionVm.errorMessage)),
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
    updateState(() {
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

  void _addConnection(BuildContext context) {
    Navigator.pushNamed(context, '/add');
  }

  void _toggleServerSelection(String id) {
    updateState(() {
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
    updateState(() {
      _serverSelectionMode = false;
      _selectedServerIds.clear();
    });
  }
}
