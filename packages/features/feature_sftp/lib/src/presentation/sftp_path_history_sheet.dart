part of 'sftp_screen.dart';

class _SftpPathHistorySheet extends StatefulWidget {
  final SftpStrings strings;
  final SftpViewModel sftp;
  final String currentPath;

  const _SftpPathHistorySheet({
    required this.strings,
    required this.sftp,
    required this.currentPath,
  });

  @override
  State<_SftpPathHistorySheet> createState() => _SftpPathHistorySheetState();
}

class _SftpPathHistorySheetState extends State<_SftpPathHistorySheet> {
  late Future<_SftpPathHistoryData> _future = _load();
  late final TextEditingController _pathController = TextEditingController(
    text: widget.currentPath,
  );

  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }

  Future<_SftpPathHistoryData> _load() async {
    final favorites = await widget.sftp.loadFavoritePaths();
    final recent = await widget.sftp.loadRecentPaths();
    final currentFavorite = await widget.sftp.findFavoritePath(
      widget.currentPath,
    );
    return _SftpPathHistoryData(
      recent: recent,
      favorites: favorites,
      currentFavorite: currentFavorite,
    );
  }

  void _reload() {
    setState(() {
      _future = _load();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final mediaQuery = MediaQuery.of(context);
    final remainingHeight =
        mediaQuery.size.height -
        mediaQuery.viewInsets.bottom -
        mediaQuery.viewPadding.vertical;
    final availableHeight = remainingHeight > 0 ? remainingHeight * 0.86 : 0.0;
    final sheetHeight = availableHeight > 680 ? 680.0 : availableHeight;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: mediaQuery.viewInsets.bottom),
        child: Align(
          alignment: Alignment.bottomCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SizedBox(
              height: sheetHeight,
              child: FutureBuilder<_SftpPathHistoryData>(
                future: _future,
                builder: (context, snapshot) {
                  final data = snapshot.data;
                  final waiting =
                      snapshot.connectionState == ConnectionState.waiting;
                  return Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 2, 12, 10),
                        child: AppPageHeader(
                          title: widget.strings.pathHistory,
                          icon: Icons.route_rounded,
                          trailing: SizedBox.square(
                            dimension: 48,
                            child: IconButton.filledTonal(
                              key: const ValueKey('sftp-toggle-favorite'),
                              tooltip: data?.currentFavorite == null
                                  ? widget.strings.addFavoritePath
                                  : widget.strings.removeFavoritePath,
                              icon: Icon(
                                data?.currentFavorite == null
                                    ? Icons.star_outline_rounded
                                    : Icons.star_rounded,
                                color: data?.currentFavorite == null
                                    ? colorScheme.onSurfaceVariant
                                    : colorScheme.primary,
                              ),
                              onPressed: waiting || snapshot.hasError
                                  ? null
                                  : () =>
                                        _toggleFavorite(data?.currentFavorite),
                            ),
                          ),
                        ),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                        child: TextField(
                          key: const ValueKey('sftp-path-input'),
                          controller: _pathController,
                          decoration: InputDecoration(
                            labelText: widget.strings.inputPath,
                            prefixIcon: const Icon(Icons.folder_open_rounded),
                            suffixIconConstraints: const BoxConstraints(
                              minWidth: 48,
                              minHeight: 48,
                            ),
                            suffixIcon: SizedBox.square(
                              key: const ValueKey('sftp-open-path'),
                              dimension: 48,
                              child: IconButton(
                                tooltip: widget.strings.openPath,
                                icon: const Icon(Icons.arrow_forward_rounded),
                                onPressed: _openTypedPath,
                              ),
                            ),
                          ),
                          textInputAction: TextInputAction.go,
                          onSubmitted: (_) => _openTypedPath(),
                        ),
                      ),
                      Divider(height: 1, color: colorScheme.outlineVariant),
                      if (waiting)
                        Expanded(
                          child: AppSkeletonizer.zone(
                            enabled: true,
                            semanticsLabel: widget.strings.pathHistory,
                            child: ListView(
                              physics: const NeverScrollableScrollPhysics(),
                              padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                              children: [
                                _SftpPathSectionHeader(
                                  label: widget.strings.favoritePaths,
                                ),
                                _PathListTile(
                                  icon: Icons.star_rounded,
                                  label: 'Web Root',
                                  path: '/var/www/html',
                                  trailing: const SizedBox.square(
                                    dimension: 48,
                                    child: Icon(Icons.close_rounded, size: 20),
                                  ),
                                  onTap: () {},
                                ),
                                const SizedBox(height: 8),
                                _SftpPathSectionHeader(
                                  label: widget.strings.recentPaths,
                                ),
                                _PathListTile(
                                  icon: Icons.history_rounded,
                                  label: '/etc/nginx',
                                  path: '/etc/nginx',
                                  trailing: const SizedBox.square(
                                    dimension: 48,
                                    child: Icon(Icons.close_rounded, size: 20),
                                  ),
                                  onTap: () {},
                                ),
                                _PathListTile(
                                  icon: Icons.history_rounded,
                                  label: '/var/log/syslog',
                                  path: '/var/log/syslog',
                                  trailing: const SizedBox.square(
                                    dimension: 48,
                                    child: Icon(Icons.close_rounded, size: 20),
                                  ),
                                  onTap: () {},
                                ),
                              ],
                            ),
                          ),
                        )
                      else if (snapshot.hasError)
                        Expanded(
                          child: AppEmptyState(
                            icon: Icons.history_toggle_off_rounded,
                            title: widget.strings.pathHistoryLoadFailed,
                            message: widget.strings.pathHistoryLoadFailedHint,
                            compact: true,
                            contained: false,
                            action: FilledButton.tonalIcon(
                              key: const ValueKey('sftp-path-history-retry'),
                              onPressed: _reload,
                              icon: const Icon(Icons.refresh_rounded),
                              label: Text(widget.strings.retry),
                            ),
                          ),
                        )
                      else
                        Expanded(
                          child: ListView(
                            padding: const EdgeInsets.fromLTRB(12, 8, 12, 20),
                            children: [
                              _SftpPathSectionHeader(
                                label: widget.strings.favoritePaths,
                              ),
                              if (data == null || data.favorites.isEmpty)
                                _EmptyPathRow(
                                  label: widget.strings.noFavoritePaths,
                                )
                              else
                                for (final favorite in data.favorites)
                                  _PathListTile(
                                    icon: Icons.star_rounded,
                                    label: favorite.name,
                                    path: favorite.path,
                                    trailing: SizedBox.square(
                                      dimension: 48,
                                      child: IconButton(
                                        tooltip:
                                            widget.strings.removeFavoritePath,
                                        icon: const Icon(Icons.close_rounded),
                                        onPressed: () =>
                                            _removeFavorite(favorite.id),
                                      ),
                                    ),
                                    onTap: () => _openPath(favorite.path),
                                  ),
                              const SizedBox(height: 8),
                              _SftpPathSectionHeader(
                                label: widget.strings.recentPaths,
                              ),
                              if (data == null || data.recent.isEmpty)
                                _EmptyPathRow(
                                  label: widget.strings.noRecentPaths,
                                )
                              else
                                for (final recent in data.recent)
                                  _PathListTile(
                                    icon: Icons.history_rounded,
                                    label: recent.path,
                                    path: _formatTimestamp(recent.visitedAt),
                                    onTap: () => _openPath(recent.path),
                                  ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _openTypedPath() {
    final path = _pathController.text.trim();
    if (path.isNotEmpty) _openPath(path);
  }

  Future<void> _toggleFavorite(SftpFavoritePathRecord? favorite) async {
    try {
      if (favorite == null) {
        await widget.sftp.addFavoritePath(
          widget.currentPath,
          widget.currentPath,
        );
      } else {
        await widget.sftp.removeFavoritePath(favorite.id);
      }
      if (mounted) _reload();
    } catch (e) {
      _showHistoryError(e);
    }
  }

  Future<void> _removeFavorite(String id) async {
    try {
      await widget.sftp.removeFavoritePath(id);
      if (mounted) _reload();
    } catch (e) {
      _showHistoryError(e);
    }
  }

  void _showHistoryError(Object error) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(error.toString())));
  }

  Future<void> _openPath(String path) async {
    Navigator.pop(context);
    await widget.sftp.openPath(path);
  }

  String _formatTimestamp(DateTime time) {
    String two(int value) => value.toString().padLeft(2, '0');
    return '${time.year.toString().padLeft(4, '0')}-'
        '${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }
}

class _SftpPathHistoryData {
  final List<SftpRecentPathRecord> recent;
  final List<SftpFavoritePathRecord> favorites;
  final SftpFavoritePathRecord? currentFavorite;

  const _SftpPathHistoryData({
    required this.recent,
    required this.favorites,
    required this.currentFavorite,
  });
}

class _SftpPathSectionHeader extends StatelessWidget {
  final String label;

  const _SftpPathSectionHeader({required this.label});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 14, 8, 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }
}

class _EmptyPathRow extends StatelessWidget {
  final String label;

  const _EmptyPathRow({required this.label});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerLow.withValues(alpha: 0.58),
        borderRadius: BorderRadius.circular(AppTheme.radiusSmall),
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Row(
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 18,
            color: colors.onSurfaceVariant,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.onSurfaceVariant),
            ),
          ),
        ],
      ),
    );
  }
}

class _PathListTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String path;
  final Widget? trailing;
  final VoidCallback onTap;

  const _PathListTile({
    required this.icon,
    required this.label,
    required this.path,
    required this.onTap,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    return Semantics(
      container: true,
      button: true,
      label: '$label, $path',
      onTap: onTap,
      child: TactileFeedback(
        onTap: onTap,
        child: ExcludeSemantics(
          child: Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow.withValues(alpha: 0.72),
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(color: colors.outline.withValues(alpha: 0.58)),
            ),
            child: Row(
              children: [
                AppIconBadge(icon: icon, size: 36, iconSize: 18),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      OverflowScrollText(
                        label,
                        selectable: false,
                        maxLines: 1,
                        style: theme.textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 3),
                      OverflowScrollText(
                        path,
                        selectable: false,
                        maxLines: 1,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                trailing ??
                    Icon(
                      Icons.chevron_right_rounded,
                      color: colors.onSurfaceVariant,
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
