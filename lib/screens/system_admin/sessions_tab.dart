part of '../system_admin_screen.dart';

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
    if (viewModel.loadingSessions) {
      return const Center(child: CircularProgressIndicator());
    }

    final id = viewModel.selectedConnectionId;
    if (id == null) return const SizedBox.shrink();

    if (viewModel.sessions.isEmpty) {
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
        itemCount: viewModel.sessions.length,
        itemBuilder: (context, index) {
          final s = viewModel.sessions[index];
          return Card(
            child: ListTile(
              leading: const CircleAvatar(child: Icon(Icons.computer)),
              title: Row(
                children: [
                  Text(s.username,
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 12),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: widget.colorScheme.secondaryContainer,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(s.tty,
                        style: TextStyle(
                            color: widget.colorScheme.onSecondaryContainer,
                            fontSize: 11)),
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
    final language = context.read<AppSettings>().language;
    final strings = AppStrings(language);
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
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Failed: $e')));
      }
    }
  }
}
