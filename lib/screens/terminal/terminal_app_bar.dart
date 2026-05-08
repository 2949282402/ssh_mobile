import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../services/ssh_service.dart';

class TerminalScreenAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  final TerminalStrings strings;
  final SshSession? session;
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
    required this.session,
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
            ],
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
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
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    strings.fontSize,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
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
            ),
          ),
        ],
      ),
      actions: [
        if (!isConnected)
          _appBarAction(
            icon: Icons.refresh,
            tooltip: strings.reconnect,
            onPressed: reconnectInProgress ? null : onReconnect,
          ),
        _appBarAction(
          icon: isDarkMode ? Icons.dark_mode_rounded : Icons.light_mode_rounded,
          tooltip:
              isDarkMode ? strings.switchToLightMode : strings.switchToDarkMode,
          onPressed: onToggleTheme,
        ),
        _appBarAction(
          icon: Icons.view_list,
          tooltip: strings.switchWindow,
          onPressed: onSwitchWindow,
        ),
        _appBarAction(
          icon: isConnected ? Icons.power_settings_new : Icons.warning_amber,
          color: closeColor,
          tooltip: isConnected ? strings.disconnect : strings.closeDisconnected,
          onPressed: onCloseWindow,
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
    return SizedBox(
      width: 40,
      child: IconButton(
        icon: Icon(icon, size: 20, color: color),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: onPressed,
      ),
    );
  }

  Widget _compactIconButton({
    required IconData icon,
    required double iconSize,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 26,
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
