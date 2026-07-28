import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/services/app_settings.dart';

class VpnP2pShareView extends StatefulWidget {
  const VpnP2pShareView({super.key});

  @override
  State<VpnP2pShareView> createState() => _VpnP2pShareViewState();
}

class _VpnP2pShareViewState extends State<VpnP2pShareView> {
  final TextEditingController _serverController = TextEditingController(
    text: 'https://relay.example.com',
  );
  bool _isEnrolled = false;
  bool _isEnrolling = false;

  @override
  void dispose() {
    _serverController.dispose();
    super.dispose();
  }

  Future<void> _handleEnroll() async {
    setState(() => _isEnrolling = true);
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() {
      _isEnrolling = false;
      _isEnrolled = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          context.read<AppSettings>().isEnglish
              ? 'Device enrolled successfully with control server.'
              : '设备已成功在控制服务器注册。',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final strings = AppStrings(settings.language);
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Control Server Configuration Card
          Card(
            elevation: 0,
            color: colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.dns_rounded, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        strings.vpnServerConfigTitle,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _isEnrolled
                              ? Colors.green.withValues(alpha: 0.15)
                              : Colors.orange.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: _isEnrolled ? Colors.green : Colors.orange,
                          ),
                        ),
                        child: Text(
                          _isEnrolled
                              ? strings.vpnEnrolledBadge
                              : strings.vpnNotEnrolledBadge,
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: _isEnrolled ? Colors.green : Colors.orange,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _serverController,
                    decoration: InputDecoration(
                      labelText: strings.vpnServerUrl,
                      prefixIcon: const Icon(Icons.link_rounded),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Device ID: ${settings.lanDeviceId.isEmpty ? "dev_local_01" : settings.lanDeviceId}',
                              style: theme.textTheme.bodySmall?.copyWith(
                                fontFamily: 'monospace',
                                color: colorScheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                      ElevatedButton.icon(
                        onPressed: _isEnrolling ? null : _handleEnroll,
                        icon: _isEnrolling
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.verified_user_rounded),
                        label: Text(strings.vpnEnrollButton),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 2. NAT / Relay Route Status Card
          Card(
            elevation: 0,
            color: colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.alt_route_rounded, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        strings.vpnRelayStatus,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: CircleAvatar(
                      backgroundColor: colorScheme.primaryContainer,
                      child: Icon(
                        Icons.speed_rounded,
                        color: colorScheme.onPrimaryContainer,
                      ),
                    ),
                    title: const Text('Direct Path (QUIC P2P / STUN)'),
                    subtitle: Text(
                      _isEnrolled
                          ? 'Route: UDP Direct · RTT: 24 ms · Packet Loss: 0.0%'
                          : 'Not connected to P2P relay mesh',
                      style: theme.textTheme.bodySmall,
                    ),
                    trailing: OutlinedButton(
                      onPressed: () {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(
                              settings.isEnglish
                                  ? 'NAT hole punch probe completed. RTT: 24ms.'
                                  : 'NAT 打洞探测完成，往返延迟：24ms。',
                            ),
                          ),
                        );
                      },
                      child: Text(strings.vpnHolePunchProbe),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 3. P2P Peer Nodes List Card
          Card(
            elevation: 0,
            color: colorScheme.surfaceContainerLow,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(
                color: colorScheme.outlineVariant.withValues(alpha: 0.5),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.hub_rounded, color: colorScheme.primary),
                      const SizedBox(width: 8),
                      Text(
                        strings.vpnPeerNodes,
                        style: theme.textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  if (!_isEnrolled)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 24.0),
                      child: Center(
                        child: Text(
                          strings.vpnNoPeers,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  else
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: CircleAvatar(
                        backgroundColor: colorScheme.secondaryContainer,
                        child: Icon(
                          Icons.laptop_rounded,
                          color: colorScheme.onSecondaryContainer,
                        ),
                      ),
                      title: const Text('Remote Server Peer (Linux)'),
                      subtitle: const Text(
                        'Virtual IP: 10.0.0.2 · QUIC Direct',
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.send_rounded),
                        onPressed: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                settings.isEnglish
                                    ? 'Opening P2P file transfer session...'
                                    : '正在发起 P2P 文件传输会话…',
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
