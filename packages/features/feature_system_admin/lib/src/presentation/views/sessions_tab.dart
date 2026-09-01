// System Admin Sessions Tab：展示并结束远程登录会话。

part of 'system_admin_screen.dart';

final _kPlaceholderSessions = List.generate(
  4,
  (i) => ActiveSession(
    username: 'user_${i + 1}',
    tty: 'pts/$i',
    ipAddress: '192.168.1.${50 + i}',
    loginTime: '2026-09-01 10:00:00',
  ),
);

class _SessionsTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final SystemAdminViewModel viewModel;

  const _SessionsTab({
    required this.strings,
    required this.colorScheme,
    required this.viewModel,
  });

  @override
  State<_SessionsTab> createState() => _SessionsTabState();
}

class _SessionsTabState extends State<_SessionsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final viewModel = widget.viewModel;
    final loadingSessions = context.select<SystemAdminViewModel, bool>(
      (vm) => vm.loadingSessions,
    );
    final rawSessions = context
        .select<SystemAdminViewModel, List<ActiveSession>>((vm) => vm.sessions);
    final sessions = loadingSessions ? _kPlaceholderSessions : rawSessions;

    final id = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.selectedConnectionId,
    );
    if (id == null) return const SizedBox.shrink();

    if (!loadingSessions && sessions.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => viewModel.fetchSessions(id, force: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 60),
            AppEmptyState(
              icon: Icons.people_outline_rounded,
              title: 'No active sessions.',
              message: 'No active user sessions detected on the host.',
              compact: true,
            ),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => viewModel.fetchSessions(id, force: true),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: _AdminListSurface(
          child: AppSkeletonizer(
            enabled: loadingSessions,
            semanticsLabel: widget.strings.activeSessions,
            child: ListView.separated(
              physics: loadingSessions
                  ? const NeverScrollableScrollPhysics()
                  : const AlwaysScrollableScrollPhysics(),
              itemCount: sessions.length,
              separatorBuilder: (_, _) => Divider(
                height: 1,
                thickness: 1,
                color: widget.colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
              itemBuilder: (context, index) {
                final s = sessions[index];
                return ListTile(
                  leading: Icon(
                    Icons.terminal_rounded,
                    size: 20,
                    color: widget.colorScheme.primary,
                  ),
                  title: Row(
                    children: [
                      Text(
                        s.username,
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                      const SizedBox(width: 12),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: widget.colorScheme.secondaryContainer,
                          borderRadius: BorderRadius.circular(
                            AppTheme.radiusXs,
                          ),
                        ),
                        child: Text(
                          s.tty,
                          style: TextStyle(
                            color: widget.colorScheme.onSecondaryContainer,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                  subtitle: OverflowScrollText(
                    '${s.loginTime} ${s.ipAddress.isNotEmpty ? '(${s.ipAddress})' : ''}',
                    selectable: false,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 12,
                      color: widget.colorScheme.onSurface.withValues(
                        alpha: 0.58,
                      ),
                    ),
                  ),
                  trailing: IconButton(
                    icon: const Icon(Icons.login_outlined),
                    color: widget.colorScheme.error,
                    tooltip: widget.strings.killSession,
                    onPressed: loadingSessions
                        ? null
                        : () => _confirmKillSession(s),
                  ),
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmKillSession(ActiveSession session) async {
    final strings = context.read<AppSettings>().strings;
    final confirm = await AppConfirmDialog.show(
      context,
      title: strings.actionConfirm,
      content: strings.killSessionConfirm(session.username, session.tty),
      cancelLabel: strings.cancel,
      confirmLabel: strings.killAction,
      isDestructive: true,
    );

    if (!mounted) return;
    if (confirm) {
      try {
        await widget.viewModel.killActiveSession(session.tty);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }
}
