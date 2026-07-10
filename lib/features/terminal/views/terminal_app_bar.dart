import 'package:flutter/material.dart';

import 'package:ssh_mobile/services/app_settings.dart';

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
      title: Row(
        children: [
          Flexible(
            child: Text(
              displayName ?? serverName ?? strings.defaultTerminal,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
            decoration: BoxDecoration(
              color: statusColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(999),
              border: Border.all(color: statusColor.withValues(alpha: 0.32)),
            ),
            child: Text(
              isConnected ? strings.connected : strings.disconnected,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: statusColor,
              ),
            ),
          ),
        ],
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.view_list),
          tooltip: strings.switchWindow,
          onPressed: onSwitchWindow,
        ),
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: strings.moreActions,
          onSelected: (value) {
            switch (value) {
              case 'new_window':
                onOpenSiblingSession();
                break;
              case 'smaller_font':
                onSmallerFont();
                break;
              case 'larger_font':
                onLargerFont();
                break;
              case 'toggle_theme':
                onToggleTheme();
                break;
              case 'reconnect':
                onReconnect();
                break;
              case 'close_window':
                onCloseWindow();
                break;
            }
          },
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
        ),
      ],
    );
  }

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);
}
