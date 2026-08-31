// System Admin Sessions Tab：展示并结束远程登录会话。

part of 'system_admin_screen.dart';

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
    final sessions = context.select<SystemAdminViewModel, List<ActiveSession>>(
      (vm) => vm.sessions,
    );
    if (loadingSessions) {
      return const Center(child: CircularProgressIndicator());
    }

    final id = context.select<SystemAdminViewModel, String?>(
      (vm) => vm.selectedConnectionId,
    );
    if (id == null) return const SizedBox.shrink();

    if (sessions.isEmpty) {
      return RefreshIndicator(
        onRefresh: () => viewModel.fetchSessions(id, force: true),
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 100),
            Center(child: Text('No active sessions.')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: () => viewModel.fetchSessions(id, force: true),
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: sessions.length,
        itemBuilder: (context, index) {
          final s = sessions[index];
          return Container(
            margin: const EdgeInsets.only(bottom: 8),
            decoration: BoxDecoration(
              color: widget.colorScheme.surface,
              borderRadius: BorderRadius.circular(AppTheme.radiusMedium),
              border: Border.all(
                color: widget.colorScheme.outlineVariant.withValues(alpha: 0.8),
                width: 1,
              ),
            ),
            child: ListTile(
              leading: CircleAvatar(
                radius: 18,
                backgroundColor: widget.colorScheme.surfaceContainerHighest,
                child: Icon(
                  Icons.computer,
                  size: 18,
                  color: widget.colorScheme.primary,
                ),
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
                      borderRadius: BorderRadius.circular(AppTheme.radiusXs),
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
                  color: widget.colorScheme.onSurface.withValues(alpha: 0.58),
                ),
              ),
              trailing: IconButton(
                icon: const Icon(Icons.login_outlined),
                color: widget.colorScheme.error,
                tooltip: widget.strings.killSession,
                onPressed: () => _confirmKillSession(s),
              ),
            ),
          );
        },
      ),
    );
  }

  Future<void> _confirmKillSession(ActiveSession session) async {
    final strings = context.read<AppSettings>().strings;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(strings.actionConfirm),
        content: Text(
          strings.killSessionConfirm(session.username, session.tty),
        ),
        actions: [
          TextButton(
            child: Text(strings.cancel),
            onPressed: () => Navigator.pop(context, false),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(strings.killAction),
          ),
        ],
      ),
    );

    if (!mounted) return;
    if (confirm == true) {
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
