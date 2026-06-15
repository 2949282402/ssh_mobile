part of '../system_admin_screen.dart';

class _PortsTab extends StatefulWidget {
  final AppStrings strings;
  final ColorScheme colorScheme;
  final String connectionId;
  final List<ListeningPort> ports;
  final bool isLoading;
  final RefreshCallback onRefresh;

  const _PortsTab({
    required this.strings,
    required this.colorScheme,
    required this.connectionId,
    required this.ports,
    required this.isLoading,
    required this.onRefresh,
  });

  @override
  State<_PortsTab> createState() => _PortsTabState();
}

class _PortsTabState extends State<_PortsTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    if (widget.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (widget.ports.isEmpty) {
      return RefreshIndicator(
        onRefresh: widget.onRefresh,
        child: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          children: const [
            SizedBox(height: 100),
            Center(child: Text('No listening ports found.')),
          ],
        ),
      );
    }

    return RefreshIndicator(
      onRefresh: widget.onRefresh,
      child: ListView.builder(
        padding: const EdgeInsets.all(12),
        itemCount: widget.ports.length,
        itemBuilder: (context, index) {
          final p = widget.ports[index];
          return Card(
            child: ListTile(
              leading: Icon(
                p.protocol.contains('udp')
                    ? Icons.radio_button_checked
                    : Icons.swap_horizontal_circle,
                color: widget.colorScheme.secondary,
              ),
              title: Row(
                children: [
                  Text('${p.protocol.toUpperCase()}  :${p.localPort}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: widget.colorScheme.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: OverflowScrollText(
                          p.processName,
                          selectable: false,
                          maxLines: 1,
                          style: const TextStyle(
                              fontFamily: 'monospace',
                              fontWeight: FontWeight.bold,
                              fontSize: 12),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              subtitle: OverflowScrollText(
                'Address: ${p.localAddress} ${p.pid != null ? '• PID: ${p.pid}' : ''}',
                selectable: false,
                maxLines: 1,
                style: TextStyle(
                  fontSize: 12,
                  color: widget.colorScheme.onSurface.withValues(alpha: 0.58),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
