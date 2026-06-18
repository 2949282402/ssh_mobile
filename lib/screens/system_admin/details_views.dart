part of '../system_admin_screen.dart';

class _FlatSnapshotItem<T> {
  final ConnectionConfig connection;
  final T? item;
  final String? emptyText;
  final bool isHeader;
  final bool isFirst;
  final bool isLast;

  _FlatSnapshotItem({
    required this.connection,
    this.item,
    this.emptyText,
    this.isHeader = false,
    this.isFirst = false,
    this.isLast = false,
  });
}

class _ServerSnapshotTab<T> extends StatelessWidget {
  final AppStrings strings;
  final List<ConnectionConfig> connections;
  final String emptyText;
  final Future<Map<String, List<T>>>? future;
  final VoidCallback onRefresh;
  final Widget Function(BuildContext context, T item) itemBuilder;

  const _ServerSnapshotTab({
    required this.strings,
    required this.connections,
    required this.emptyText,
    required this.future,
    required this.onRefresh,
    required this.itemBuilder,
  });

  @override
  Widget build(BuildContext context) {
    if (connections.isEmpty) {
      return Center(
        child:
            Text(_monitorText(strings, 'Select a server first.', '请先选择一台服务器。')),
      );
    }
    return FutureBuilder<Map<String, List<T>>>(
      future: future,
      builder: (context, snapshot) {
        final isRefreshing =
            snapshot.connectionState == ConnectionState.waiting;
        return Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        _serverSummary(strings, connections),
                        maxLines: 1,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
                  IconButton.outlined(
                    onPressed: isRefreshing ? null : onRefresh,
                    icon: isRefreshing
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.refresh_rounded),
                    tooltip: strings.refresh,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Builder(
                builder: (context) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(
                      child: SizedBox(
                        width: 28,
                        height: 28,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    );
                  }
                  if (snapshot.hasError) {
                    return Center(
                      child: Text(
                        '${_monitorText(strings, 'Load failed', '加载失败')}: ${snapshot.error}',
                        textAlign: TextAlign.center,
                      ),
                    );
                  }
                  final data = snapshot.data ?? const {};

                  // Build the flat list of items
                  final flatItems = <_FlatSnapshotItem<T>>[];
                  for (final connection in connections) {
                    final items = data[connection.id] ?? const [];
                    if (items.isEmpty) {
                      flatItems.add(_FlatSnapshotItem<T>(
                        connection: connection,
                        isHeader: true,
                        isFirst: true,
                        isLast: false,
                      ));
                      flatItems.add(_FlatSnapshotItem<T>(
                        connection: connection,
                        emptyText: emptyText,
                        isHeader: false,
                        isFirst: false,
                        isLast: true,
                      ));
                    } else {
                      flatItems.add(_FlatSnapshotItem<T>(
                        connection: connection,
                        isHeader: true,
                        isFirst: true,
                        isLast: false,
                      ));
                      for (int i = 0; i < items.length; i++) {
                        flatItems.add(_FlatSnapshotItem<T>(
                          connection: connection,
                          item: items[i],
                          isHeader: false,
                          isFirst: false,
                          isLast: i == items.length - 1,
                        ));
                      }
                    }
                  }

                  final colorScheme = Theme.of(context).colorScheme;
                  final borderSide =
                      BorderSide(color: colorScheme.outlineVariant);

                  return ListView.builder(
                    cacheExtent: 900,
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 24),
                    itemCount: flatItems.length,
                    itemBuilder: (context, index) {
                      final flatItem = flatItems[index];
                      final isFirst = flatItem.isFirst;
                      final isLast = flatItem.isLast;

                      // Render decoration for continuous border
                      final decoration = BoxDecoration(
                        color: colorScheme.surface,
                        borderRadius: BorderRadius.only(
                          topLeft:
                              isFirst ? const Radius.circular(8) : Radius.zero,
                          topRight:
                              isFirst ? const Radius.circular(8) : Radius.zero,
                          bottomLeft:
                              isLast ? const Radius.circular(8) : Radius.zero,
                          bottomRight:
                              isLast ? const Radius.circular(8) : Radius.zero,
                        ),
                        border: Border(
                          left: borderSide,
                          right: borderSide,
                          top: isFirst ? borderSide : BorderSide.none,
                          bottom: isLast ? borderSide : BorderSide.none,
                        ),
                      );

                      final margin = EdgeInsets.only(
                        left: 0,
                        right: 0,
                        top: isFirst ? 12.0 : 0.0,
                        bottom: isLast ? 12.0 : 0.0,
                      );

                      if (flatItem.isHeader) {
                        return Container(
                          key: ValueKey('header-${flatItem.connection.id}'),
                          margin: margin,
                          decoration: decoration,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
                          child: Text(
                            flatItem.connection.name,
                            style: const TextStyle(
                                fontWeight: FontWeight.w800, fontSize: 14),
                          ),
                        );
                      }

                      if (flatItem.emptyText != null) {
                        return Container(
                          key: ValueKey('empty-${flatItem.connection.id}'),
                          margin: margin,
                          decoration: decoration,
                          padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                          child: Text(
                            flatItem.emptyText!,
                            style: TextStyle(
                                color: colorScheme.onSurfaceVariant,
                                fontSize: 12),
                          ),
                        );
                      }

                      return Container(
                        margin: margin,
                        decoration: decoration,
                        child: itemBuilder(context, flatItem.item as T),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PortProcessTile extends StatefulWidget {
  final AppStrings strings;
  final PortProcessSnapshot port;

  const _PortProcessTile({
    required this.strings,
    required this.port,
  });

  @override
  State<_PortProcessTile> createState() => _PortProcessTileState();
}

class _PortProcessTileState extends State<_PortProcessTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final port = widget.port;
    final portText = port.port == 0 ? '-' : '${port.port}';
    final processText = port.process.trim().isEmpty ? '-' : port.process.trim();
    final stateText = port.state.trim().isEmpty ? '-' : port.state.trim();

    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 56,
                  height: 32,
                  alignment: Alignment.center,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  decoration: BoxDecoration(
                    color: colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: colorScheme.primary.withValues(alpha: 0.22),
                    ),
                  ),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      portText,
                      maxLines: 1,
                      style: TextStyle(
                        color: colorScheme.primary,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OverflowScrollText(
                        processText,
                        selectable: false,
                        maxLines: 1,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      OverflowScrollText(
                        '${port.protocol.toUpperCase()} $stateText  ${port.localAddress}',
                        selectable: false,
                        maxLines: 1,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(78, 0, 12, 10),
            child: Column(
              children: [
                _PortDetailLine(
                  label: _monitorText(widget.strings, 'Address', '地址'),
                  value: port.localAddress,
                ),
                _PortDetailLine(
                  label: _monitorText(widget.strings, 'Protocol', '协议'),
                  value: port.protocol.toUpperCase(),
                ),
                _PortDetailLine(
                  label: _monitorText(widget.strings, 'State', '状态'),
                  value: stateText,
                ),
                _PortDetailLine(
                  label: _monitorText(widget.strings, 'Process', '进程'),
                  value: processText,
                ),
              ],
            ),
          ),
          crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 160),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }
}

class _PortDetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _PortDetailLine({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 64,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ServiceStatusTile extends StatefulWidget {
  final AppStrings strings;
  final ServiceStatusSnapshot service;

  const _ServiceStatusTile({
    required this.strings,
    required this.service,
  });

  @override
  State<_ServiceStatusTile> createState() => _ServiceStatusTileState();
}

class _ServiceStatusTileState extends State<_ServiceStatusTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final service = widget.service;
    final nameText = service.name.trim().isEmpty ? '-' : service.name.trim();
    final displayNameText =
        service.displayName.trim().isEmpty ? '-' : service.displayName.trim();

    final isRunning = service.status.toLowerCase() == 'running' ||
        service.activeState.toLowerCase() == 'active';
    final statusColor = isRunning ? colorScheme.secondary : colorScheme.error;

    return Column(
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            child: Row(
              children: [
                Container(
                  width: 10,
                  height: 10,
                  decoration: BoxDecoration(
                    color: statusColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OverflowScrollText(
                        nameText,
                        selectable: false,
                        maxLines: 1,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 2),
                      OverflowScrollText(
                        displayNameText,
                        selectable: false,
                        maxLines: 1,
                        style: TextStyle(
                          color: colorScheme.onSurfaceVariant,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: statusColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    service.status.toUpperCase(),
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Icon(
                  _expanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: colorScheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.fromLTRB(34, 0, 12, 10),
            child: Column(
              children: [
                _ServiceDetailLine(
                  label: _monitorText(widget.strings, 'Service Name', '服务名称'),
                  value: service.name,
                ),
                _ServiceDetailLine(
                  label: _monitorText(widget.strings, 'Description', '描述'),
                  value: service.displayName,
                ),
                _ServiceDetailLine(
                  label: _monitorText(widget.strings, 'Status', '状态'),
                  value: service.status,
                ),
                _ServiceDetailLine(
                  label: _monitorText(widget.strings, 'Active State', '活动状态'),
                  value: service.activeState,
                ),
                _ServiceDetailLine(
                  label: _monitorText(widget.strings, 'Load State', '加载状态'),
                  value: service.loadState,
                ),
              ],
            ),
          ),
          crossFadeState:
              _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          duration: const Duration(milliseconds: 160),
          sizeCurve: Curves.easeOutCubic,
        ),
      ],
    );
  }
}

class _ServiceDetailLine extends StatelessWidget {
  final String label;
  final String value;

  const _ServiceDetailLine({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 96,
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                value,
                maxLines: 1,
                style: TextStyle(
                  color: colorScheme.onSurface,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
