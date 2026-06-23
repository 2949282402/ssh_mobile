import 'package:flutter/material.dart';

import '../../services/app_settings.dart';

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
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final connectedColor = colorScheme.secondary;
    final disconnectedColor = colorScheme.error;
    final closeColor = isConnected ? colorScheme.error : disconnectedColor;
    final statusColor = isConnected ? connectedColor : disconnectedColor;

    return AppBar(
      surfaceTintColor: Colors.transparent,
      titleSpacing: 4,
<<<<<<< HEAD
      title: Row(
        children: [
          Flexible(
            child: Text(
              displayName ?? serverName ?? strings.defaultTerminal,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: statusColor.withValues(alpha: 0.32),
              ),
            ),
            child: Text(
              isConnected ? strings.connected : strings.disconnected,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: statusColor,
=======
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
>>>>>>> 46c8b2a7f3e083a10730f7a62d0d6ac9daac2f72
              ),
            ),
          ),
        ],
      ),
      actions: [
<<<<<<< HEAD
        IconButton(
          icon: const Icon(Icons.view_list),
=======
        _appBarAction(
          icon: Icons.view_list,
>>>>>>> 46c8b2a7f3e083a10730f7a62d0d6ac9daac2f72
          tooltip: strings.switchWindow,
          onPressed: onSwitchWindow,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
<<<<<<< HEAD
          tooltip: strings.moreActions,
=======
          tooltip: 'More actions',
>>>>>>> 46c8b2a7f3e083a10730f7a62d0d6ac9daac2f72
          onSelected: (value) {
            switch (value) {
              case 'new_window':
                onOpenSiblingSession();
                break;
<<<<<<< HEAD
=======
              case 'reconnect':
                onReconnect();
                break;
              case 'toggle_theme':
                onToggleTheme();
                break;
>>>>>>> 46c8b2a7f3e083a10730f7a62d0d6ac9daac2f72
              case 'smaller_font':
                onSmallerFont();
                break;
              case 'larger_font':
                onLargerFont();
                break;
<<<<<<< HEAD
              case 'toggle_theme':
                onToggleTheme();
                break;
              case 'reconnect':
                onReconnect();
                break;
=======
>>>>>>> 46c8b2a7f3e083a10730f7a62d0d6ac9daac2f72
              case 'close_window':
                onCloseWindow();
                break;
            }
          },
<<<<<<< HEAD
          itemBuilder: (context) {
            final fontStyle = TextStyle(
              color: colorScheme.onSurface,
              fontSize: 15,
            );
            return [
              PopupMenuItem(
                value: 'new_window',
                child: Row(
                  children: [
                    const Icon(Icons.add_to_photos_outlined, size: 20),
                    const SizedBox(width: 12),
                    Text(strings.newWindow, style: fontStyle),
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
                      style: fontStyle,
                    ),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'smaller_font',
                child: Row(
                  children: [
                    const Icon(Icons.zoom_out, size: 20),
                    const SizedBox(width: 12),
                    Text(strings.smallerFont, style: fontStyle),
                  ],
                ),
              ),
              PopupMenuItem(
                value: 'larger_font',
                child: Row(
                  children: [
                    const Icon(Icons.zoom_in, size: 20),
                    const SizedBox(width: 12),
                    Text(strings.largerFont, style: fontStyle),
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
                      Text(strings.reconnect, style: fontStyle),
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
                      style: fontStyle.copyWith(color: closeColor),
                    ),
                  ],
                ),
              ),
            ];
          },
=======
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
>>>>>>> 46c8b2a7f3e083a10730f7a62d0d6ac9daac2f72
        ),
      ],
    );
  }

<<<<<<< HEAD
  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
=======
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
>>>>>>> 46c8b2a7f3e083a10730f7a62d0d6ac9daac2f72
}
