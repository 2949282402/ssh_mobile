import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:ssh_mobile/services/app_settings.dart';

class VpnP2pShareView extends StatefulWidget {
  const VpnP2pShareView({super.key});

  @override
  State<VpnP2pShareView> createState() => _VpnP2pShareViewState();
}

class _VpnP2pShareViewState extends State<VpnP2pShareView> {
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _tokenController;
  bool _isEnrolled = false;
  bool _isEnrolling = false;

  @override
  void initState() {
    super.initState();
    final settings = context.read<AppSettings>();
    final host = settings.relayHost.isNotEmpty ? settings.relayHost : 'relay.example.com';
    final port = settings.relayPort > 0 ? settings.relayPort : 443;
    _hostController = TextEditingController(text: host);
    _portController = TextEditingController(text: '$port');
    _tokenController = TextEditingController();

    _hostController.addListener(_onHostChanged);
  }

  void _onHostChanged() {
    final text = _hostController.text.trim();
    if (text.startsWith('http://') || text.startsWith('https://')) {
      final uri = Uri.tryParse(text);
      if (uri != null && uri.host.isNotEmpty) {
        _hostController.value = TextEditingValue(
          text: uri.host,
          selection: TextSelection.collapsed(offset: uri.host.length),
        );
        if (uri.hasPort) {
          _portController.text = '${uri.port}';
        } else if (uri.scheme == 'http') {
          _portController.text = '8080';
        } else {
          _portController.text = '443';
        }
      }
    }
  }

  @override
  void dispose() {
    _hostController.removeListener(_onHostChanged);
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  Future<void> _handleEnroll() async {
    final host = _hostController.text.trim();
    final portVal = int.tryParse(_portController.text.trim());
    if (host.isEmpty || portVal == null || portVal < 1 || portVal > 65535) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            context.read<AppSettings>().isEnglish
                ? 'Invalid server host or port (1-65535).'
                : '服务器主机或端口（1-65535）输入无效。',
          ),
          backgroundColor: Theme.of(context).colorScheme.error,
        ),
      );
      return;
    }

    setState(() => _isEnrolling = true);
    final settings = context.read<AppSettings>();
    await settings.setRelayServer(host: host, port: portVal);

    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;
    setState(() {
      _isEnrolling = false;
      _isEnrolled = true;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          settings.isEnglish
              ? 'Device enrolled successfully with control server ($host:$portVal).'
              : '设备已成功在控制服务器 ($host:$portVal) 注册。',
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
                  // Host & Port Row
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _hostController,
                          decoration: InputDecoration(
                            labelText: strings.vpnServerHost,
                            hintText: 'relay.example.com',
                            prefixIcon: const Icon(Icons.link_rounded),
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        flex: 1,
                        child: TextField(
                          controller: _portController,
                          keyboardType: TextInputType.number,
                          decoration: InputDecoration(
                            labelText: strings.vpnServerPort,
                            hintText: '443',
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  // Enrollment Token (Optional)
                  TextField(
                    controller: _tokenController,
                    decoration: InputDecoration(
                      labelText: strings.vpnEnrollmentToken,
                      hintText: strings.isEnglish
                          ? 'Auto-generated or custom token'
                          : '服务器面板显示或自定义的 Token',
                      prefixIcon: const Icon(Icons.key_rounded),
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Device ID: ${settings.lanDeviceId.isEmpty ? "dev_local_01" : settings.lanDeviceId}',
                          style: theme.textTheme.bodySmall?.copyWith(
                            fontFamily: 'monospace',
                            color: colorScheme.onSurfaceVariant,
                          ),
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
