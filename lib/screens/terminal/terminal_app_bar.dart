import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../widgets/overflow_scroll_text.dart';

class TerminalScreenAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final TerminalStrings strings;
  final String? displayName;
  final String? serverName;
  final bool isConnected;
  final bool isDarkMode;
  final bool reconnectInProgress;
  final VoidCallback onReconnect;
  final VoidCallback onToggleTheme;
  final VoidCallback onSwitchWindow;
  final VoidCallback onCloseWindow;
  final VoidCallback onOpenSiblingSession;
  final VoidCallback onSmallerFont;
  final VoidCallback onLargerFont;

  const TerminalScreenAppBar({
    super.key,
    required this.strings,
    required this.displayName,
    required this.serverName,
    required this.isConnected,
    required this.isDarkMode,
    required this.reconnectInProgress,
    required this.onReconnect,
    required this.onToggleTheme,
    required this.onSwitchWindow,
    required this.onCloseWindow,
    required this.onOpenSiblingSession,
    required this.onSmallerFont,
    required this.onLargerFont,
  });

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final connectedColor = colorScheme.secondary;
    final disconnectedColor = colorScheme.error;
    final closeColor = isConnected ? colorScheme.error : disconnectedColor;
    final statusColor = isConnected ? connectedColor : disconnectedColor;

    return AppBar(
      surfaceTintColor: Colors.transparent,
      titleSpacing: 4,
      title: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          OverflowScrollText(
            displayName ?? serverName ?? strings.defaultTerminal,
            selectable: false,
            maxLines: 1,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 2),
          IntrinsicWidth(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
                border: Border.all(
                  color: statusColor.withValues(alpha: 0.32),
                ),
              ),
              child: Center(
                child: Text(
                  isConnected ? strings.connected : strings.disconnected,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w800,
                    color: statusColor,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      actions: [
        _appBarAction(
          icon: Icons.view_list,
          tooltip: strings.switchWindow,
          onPressed: onSwitchWindow,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'More actions',
          onSelected: (value) {
            switch (value) {
              case 'new_window':
                onOpenSiblingSession();
                break;
              case 'reconnect':
                onReconnect();
                break;
              case 'toggle_theme':
                onToggleTheme();
                break;
              case 'smaller_font':
                onSmallerFont();
                break;
              case 'larger_font':
                onLargerFont();
                break;
              case 'close_window':
                onCloseWindow();
                break;
            }
          },
          itemBuilder: (ctx) => [
            PopupMenuItem(
              value: 'new_window',
              child: Row(
                children: [
                  const Icon(Icons.add, size: 20),
                  const SizedBox(width: 12),
                  Text(strings.newWindow),
                ],
              ),
            ),
            if (!isConnected)
              PopupMenuItem(
                value: 'reconnect',
                enabled: !reconnectInProgress,
                child: Row(
                  children: [
                    const Icon(Icons.refresh, size: 20),
                    const SizedBox(width: 12),
                    Text(strings.reconnect),
                  ],
                ),
              ),
            PopupMenuItem(
              value: 'toggle_theme',
              child: Row(
                children: [
                  Icon(
                    isDarkMode
                        ? Icons.light_mode_rounded
                        : Icons.dark_mode_rounded,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    isDarkMode
                        ? strings.switchToLightMode
                        : strings.switchToDarkMode,
                  ),
                ],
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'smaller_font',
              child: Row(
                children: [
                  const Icon(Icons.remove, size: 20),
                  const SizedBox(width: 12),
                  Text(strings.smallerFont),
                ],
              ),
            ),
            PopupMenuItem(
              value: 'larger_font',
              child: Row(
                children: [
                  const Icon(Icons.add, size: 20),
                  const SizedBox(width: 12),
                  Text(strings.largerFont),
                ],
              ),
            ),
            const PopupMenuDivider(),
            PopupMenuItem(
              value: 'close_window',
              child: Row(
                children: [
                  Icon(
                    isConnected
                        ? Icons.power_settings_new
                        : Icons.warning_amber,
                    color: closeColor,
                    size: 20,
                  ),
                  const SizedBox(width: 12),
                  Text(
                    isConnected
                        ? strings.disconnect
                        : strings.closeDisconnected,
                    style: TextStyle(color: closeColor),
                  ),
                ],
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _appBarAction({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      icon: Icon(icon, color: color),
      tooltip: tooltip,
      onPressed: onPressed,
    );
  }
}
