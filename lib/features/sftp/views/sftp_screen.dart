import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:animations/animations.dart';

import 'package:ssh_mobile/features/connection/models/connection.dart';
import 'package:ssh_mobile/features/connection/viewmodels/connection_viewmodel.dart';
import 'package:ssh_mobile/features/sftp/viewmodels/sftp_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/storage_service.dart';
import 'package:ssh_mobile/theme/app_theme.dart';
import 'package:ssh_mobile/utils/responsive.dart';
import 'package:ssh_mobile/widgets/tactile_feedback.dart';
import 'package:ssh_mobile/widgets/overflow_scroll_text.dart';
import 'package:ssh_mobile/widgets/ssh_host_key_trust_dialog.dart';
import 'package:ssh_mobile/features/sftp/views/sftp_editor_screen.dart';
import 'package:ssh_mobile/features/sftp/views/sftp_file_viewer_screen.dart';

part 'sftp_server_pane.dart';
part 'sftp_file_pane.dart';
part 'sftp_models.dart';

class SftpScreen extends StatefulWidget {
  const SftpScreen({super.key});

  @override
  State<SftpScreen> createState() => _SftpScreenState();
}

class _SftpScreenState extends State<SftpScreen> {
  static const _serversCollapsedStorageKey = 'sftp_servers_collapsed';

  bool _serversCollapsed = false;
  bool _restoredServersCollapsed = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_restoredServersCollapsed) return;
    _restoredServersCollapsed = true;
    final stored = PageStorage.maybeOf(context)?.readState(
      context,
      identifier: _serversCollapsedStorageKey,
    );
    if (stored is bool) _serversCollapsed = stored;
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final connectionVm = context.watch<ConnectionViewModel>();
    final sftp = context.read<SftpViewModel>();
    final storageReady = !connectionVm.isLoading;
    final connections = connectionVm.connections;
    final selectedConnectionId = context.select<SftpViewModel, String?>(
      (vm) => vm.connectionId,
    );
    final desktop = isDesktopLayout(context);
    final selectedConnection =
        _selectedConnection(connections, selectedConnectionId);
    final serversCollapsed = _serversCollapsed && connections.isNotEmpty;

    if (!storageReady) {
      return const Center(
        child: SizedBox(
          width: 28,
          height: 28,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }

    return desktop
        ? Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOutCubic,
                width: serversCollapsed ? 64 : 320,
                child: serversCollapsed
                    ? Selector<SftpViewModel, _SftpConnectionStatusSnapshot>(
                        selector: (_, service) =>
                            _SftpConnectionStatusSnapshot.from(
                          service,
                          selectedConnection?.id,
                        ),
                        builder: (context, status, _) =>
                            _CollapsedDesktopServerRail(
                          selectedConnection: selectedConnection,
                          busy: status.busy,
                          connected: status.connected,
                          strings: strings,
                          onExpand: _expandServers,
                        ),
                      )
                    : _ServerPane(
                        connections: connections,
                        strings: strings,
                        onCollapse: _collapseServers,
                      ),
              ),
              VerticalDivider(
                width: 1,
                thickness: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(
                child: _FilePane(
                  strings: strings,
                  sftp: sftp,
                ),
              ),
            ],
          )
        : Column(
            children: [
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                child: serversCollapsed
                    ? Selector<SftpViewModel, _SftpConnectionStatusSnapshot>(
                        key: const ValueKey('sftp-server-collapsed'),
                        selector: (_, service) =>
                            _SftpConnectionStatusSnapshot.from(
                          service,
                          selectedConnection?.id,
                        ),
                        builder: (context, status, _) =>
                            _CollapsedMobileServerBar(
                          selectedConnection: selectedConnection,
                          busy: status.busy,
                          connected: status.connected,
                          strings: strings,
                          onExpand: _expandServers,
                        ),
                      )
                    : _MobileServerStrip(
                        key: const ValueKey('sftp-server-expanded'),
                        connections: connections,
                        strings: strings,
                        onCollapse: _collapseServers,
                      ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: Theme.of(context).colorScheme.outlineVariant,
              ),
              Expanded(
                child: _FilePane(
                  strings: strings,
                  sftp: sftp,
                ),
              ),
            ],
          );
  }

  void _collapseServers() {
    _setServersCollapsed(true);
  }

  void _expandServers() {
    _setServersCollapsed(false);
  }

  void _setServersCollapsed(bool collapsed) {
    if (_serversCollapsed == collapsed) return;
    setState(() => _serversCollapsed = collapsed);
    PageStorage.maybeOf(context)?.writeState(
      context,
      collapsed,
      identifier: _serversCollapsedStorageKey,
    );
  }

  ConnectionConfig? _selectedConnection(
    List<ConnectionConfig> connections,
    String? activeConnectionId,
  ) {
    if (activeConnectionId == null) return null;
    for (final connection in connections) {
      if (connection.id == activeConnectionId) return connection;
    }
    return null;
  }
}
