import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../../services/app_settings.dart';
import '../../../theme/app_theme.dart';
import '../../../widgets/app_surface.dart';
import '../utils/lan_platform_capabilities.dart';
import '../viewmodels/lan_share_viewmodel.dart';

class LanShareSettingsScreen extends StatefulWidget {
  const LanShareSettingsScreen({super.key});

  @override
  State<LanShareSettingsScreen> createState() => _LanShareSettingsScreenState();
}

class _LanShareSettingsScreenState extends State<LanShareSettingsScreen> {
  bool _notificationGranted = false;
  bool _cameraGranted = false;

  bool get _supportsRuntimePermissions => supportsLanShareRuntimePermissions(
    platform: defaultTargetPlatform,
    isWeb: kIsWeb,
  );

  @override
  void initState() {
    super.initState();
    _refreshPermissions();
  }

  Future<void> _refreshPermissions() async {
    if (!_supportsRuntimePermissions) return;
    final notification = await Permission.notification.status;
    final camera = await Permission.camera.status;
    if (!mounted) return;
    setState(() {
      _notificationGranted = notification.isGranted;
      _cameraGranted = camera.isGranted;
    });
  }

  Future<void> _requestPermission(Permission permission) async {
    final status = await permission.request();
    if (!mounted) return;
    setState(() {
      if (permission == Permission.notification) {
        _notificationGranted = status.isGranted;
      } else {
        _cameraGranted = status.isGranted;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final vm = context.watch<LanShareViewModel>();
    final settings = vm.appSettings;
    final strings = AppStrings(settings.language);
    final alias = settings.lanDeviceAlias;
    final deviceId = settings.lanDeviceId;

    return Scaffold(
      appBar: AppBar(
        title: Text(strings.lanShareSettings),
        leading: IconButton(
          tooltip: strings.close,
          onPressed: () => Navigator.maybePop(context),
          icon: const Icon(Icons.close_rounded),
        ),
      ),
      body: AppPageSurface(
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(AppTheme.compactPagePadding),
            children: [
              AppSectionCard(
                title: strings.lanShareSettings,
                child: Column(
                  children: [
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(
                        Icons.drive_file_rename_outline_rounded,
                      ),
                      title: Text(strings.lanDeviceAlias),
                      subtitle: Text(alias.isEmpty ? strings.unknown : alias),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _rename(context, settings, alias, strings),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.fingerprint_rounded),
                      title: Text(strings.lanDeviceId),
                      subtitle: Text(
                        deviceId.isEmpty ? strings.unknown : deviceId,
                        style: const TextStyle(fontFamily: 'monospace'),
                      ),
                      trailing: IconButton(
                        tooltip: strings.copy,
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: deviceId.isEmpty
                            ? null
                            : () async {
                                await Clipboard.setData(
                                  ClipboardData(text: deviceId),
                                );
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text(strings.copy)),
                                  );
                                }
                              },
                      ),
                    ),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.hub_outlined),
                      title: Text(strings.lanRelayServer),
                      subtitle: Text(
                        settings.relayHost.isEmpty
                            ? strings.unknown
                            : '${settings.relayHost}:${settings.relayPort}',
                      ),
                      trailing: const Icon(Icons.chevron_right_rounded),
                      onTap: () => _editRelay(context, settings, strings),
                    ),
                  ],
                ),
              ),
              if (_supportsRuntimePermissions) ...[
                const SizedBox(height: 14),
                AppSectionCard(
                  title: strings.lanPermissions,
                  child: Column(
                    children: [
                      _PermissionTile(
                        title: strings.lanNotificationPermission,
                        granted: _notificationGranted,
                        onTap: _notificationGranted
                            ? null
                            : () => _requestPermission(Permission.notification),
                        strings: strings,
                      ),
                      _PermissionTile(
                        title: strings.lanCameraPermission,
                        granted: _cameraGranted,
                        onTap: _cameraGranted
                            ? null
                            : () => _requestPermission(Permission.camera),
                        strings: strings,
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _rename(
    BuildContext context,
    AppSettings settings,
    String current,
    AppStrings strings,
  ) async {
    final controller = TextEditingController(text: current);
    final value = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.lanDeviceAlias),
        content: TextField(
          controller: controller,
          maxLength: 32,
          autofocus: true,
          decoration: InputDecoration(hintText: strings.lanDeviceAlias),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: Text(strings.save),
          ),
        ],
      ),
    );
    controller.dispose();
    if (value != null && value.isNotEmpty) {
      await settings.setLanDeviceAlias(value);
    }
  }

  Future<void> _editRelay(
    BuildContext context,
    AppSettings settings,
    AppStrings strings,
  ) async {
    final host = TextEditingController(text: settings.relayHost);
    final port = TextEditingController(text: '${settings.relayPort}');
    String? error;
    final value = await showDialog<(String, int)>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(strings.lanRelayServer),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: host,
                decoration: InputDecoration(labelText: strings.hostAddress),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: port,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(labelText: strings.port),
              ),
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(
                  error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: Text(strings.cancel),
            ),
            FilledButton(
              onPressed: () {
                final parsed = int.tryParse(port.text.trim());
                if (host.text.trim().isEmpty ||
                    parsed == null ||
                    parsed < 1 ||
                    parsed > 65535) {
                  setState(() => error = strings.invalidPort);
                  return;
                }
                Navigator.pop(dialogContext, (host.text.trim(), parsed));
              },
              child: Text(strings.save),
            ),
          ],
        ),
      ),
    );
    host.dispose();
    port.dispose();
    if (value == null || !context.mounted) return;
    try {
      await settings.setRelayServer(host: value.$1, port: value.$2);
    } on ArgumentError {
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.invalidPort)));
      }
    }
  }
}

class _PermissionTile extends StatelessWidget {
  final String title;
  final bool granted;
  final VoidCallback? onTap;
  final AppStrings strings;

  const _PermissionTile({
    required this.title,
    required this.granted,
    required this.onTap,
    required this.strings,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        granted
            ? Icons.check_circle_outline_rounded
            : Icons.warning_amber_rounded,
        color: granted ? Colors.green : Colors.orange,
      ),
      title: Text(title),
      subtitle: Text(granted ? strings.connected : strings.unknown),
      onTap: onTap,
    );
  }
}
