import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../services/ssh_service.dart';
import '../../theme/app_theme.dart';

class TerminalScreenAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final TerminalStrings strings;
  final SshSession? session;
  final String? serverName;
  final bool isConnected;
  final bool reconnectInProgress;
  final VoidCallback onReconnect;
  final VoidCallback onSwitchWindow;
  final VoidCallback onCloseWindow;
  final VoidCallback onOpenSiblingSession;
  final VoidCallback onRenameWindow;
  final VoidCallback onSmallerFont;
  final VoidCallback onLargerFont;

  const TerminalScreenAppBar({
    super.key,
    required this.strings,
    required this.session,
    required this.serverName,
    required this.isConnected,
    required this.reconnectInProgress,
    required this.onReconnect,
    required this.onSwitchWindow,
    required this.onCloseWindow,
    required this.onOpenSiblingSession,
    required this.onRenameWindow,
    required this.onSmallerFont,
    required this.onLargerFont,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final closeColor = isConnected ? Colors.redAccent : Colors.orangeAccent;
    final colorScheme = Theme.of(context).colorScheme;

    return AppBar(
      surfaceTintColor: Colors.transparent,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  session?.displayName ?? serverName ?? strings.defaultTerminal,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(width: 4),
              _compactIconButton(
                icon: Icons.add,
                iconSize: 18,
                tooltip: strings.newWindow,
                onPressed: onOpenSiblingSession,
              ),
              _compactIconButton(
                icon: Icons.edit,
                iconSize: 16,
                tooltip: strings.renameWindow,
                onPressed: onRenameWindow,
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                decoration: BoxDecoration(
                  color:
                      (isConnected ? AppTheme.terminalGreen : Colors.redAccent)
                          .withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(999),
                  border: Border.all(
                    color: (isConnected
                            ? AppTheme.terminalGreen
                            : Colors.redAccent)
                        .withValues(alpha: 0.32),
                  ),
                ),
                child: Text(
                  isConnected ? strings.connected : strings.disconnected,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color:
                        isConnected ? AppTheme.terminalGreen : Colors.redAccent,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                strings.fontSize,
                style: TextStyle(
                  fontSize: 11,
                  color: colorScheme.onSurface.withValues(alpha: 0.72),
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 2),
              _compactIconButton(
                icon: Icons.remove,
                iconSize: 18,
                tooltip: strings.smallerFont,
                onPressed: onSmallerFont,
              ),
              const SizedBox(width: 2),
              _compactIconButton(
                icon: Icons.add,
                iconSize: 18,
                tooltip: strings.largerFont,
                onPressed: onLargerFont,
              ),
            ],
          ),
        ],
      ),
      actions: [
        if (!isConnected)
          IconButton(
            icon: const Icon(Icons.refresh, size: 20),
            tooltip: strings.reconnect,
            onPressed: reconnectInProgress ? null : onReconnect,
          ),
        IconButton(
          icon: const Icon(Icons.view_list, size: 20),
          tooltip: strings.switchWindow,
          onPressed: onSwitchWindow,
        ),
        IconButton(
          icon: Icon(
            isConnected ? Icons.power_settings_new : Icons.warning_amber,
            color: closeColor,
          ),
          tooltip: isConnected ? strings.disconnect : strings.closeDisconnected,
          onPressed: onCloseWindow,
        ),
      ],
    );
  }

  Widget _compactIconButton({
    required IconData icon,
    required double iconSize,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        icon: Icon(icon, size: iconSize),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
    );
  }
}
