// 使用统一网络服务的 v1 点对点分享控制界面。

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:feature_lan_share/src/features/lan_share/services/lan_receiver_coordinator.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:feature_lan_share/src/domain/lan_share_ports.dart';

/// 展示由原生配置支持的 v1 Relay enrollment 控制界面。
class VpnP2pServerConfigCard extends StatefulWidget {
  /// 创建 Relay enrollment 卡片。
  const VpnP2pServerConfigCard({super.key});

  /// 创建可变 enrollment 卡片状态。
  @override
  State<VpnP2pServerConfigCard> createState() => _VpnP2pServerConfigCardState();
}

class _VpnP2pServerConfigCardState extends State<VpnP2pServerConfigCard> {
  late TextEditingController _hostController;
  late TextEditingController _portController;
  late TextEditingController _tokenController;
  bool? _isEnrolled;
  bool _isEnrolling = false;
  bool _isExpanded = false; // Collapsed by default as requested

  /// 加载当前 Relay 设置并开始 enrollment 校验。
  @override
  void initState() {
    super.initState();
    final settings = context.read<AppSettings>();
    final host = settings.relayHost;
    final port = settings.relayPort > 0 ? settings.relayPort : 443;
    _hostController = TextEditingController(text: host);
    _portController = TextEditingController(text: '$port');
    _tokenController = TextEditingController();

    _hostController.addListener(_onHostChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) => _refreshEnrollment());
  }

  /// 将粘贴的主机 URL 规范化为主机和端口字段。
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

  /// 销毁文本控制器和监听器。
  @override
  void dispose() {
    _hostController.removeListener(_onHostChanged);
    _hostController.dispose();
    _portController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  /// 为设备执行 enrollment，并配置原生 Relay 数据面。
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

    final token = _tokenController.text.trim();
    if (token.length < 16) {
      _showError(
        context.read<AppSettings>().isEnglish
            ? 'Enrollment Token must contain at least 16 characters.'
            : '注册 Token 至少需要 16 个字符。',
      );
      return;
    }

    final settings = context.read<AppSettings>();
    final endpoint = Uri(scheme: 'https', host: host, port: portVal);
    final coordinator = context.read<LanReceiverCoordinator>();
    setState(() => _isEnrolling = true);
    try {
      await settings.ensureLanIdentity();
      final result = await coordinator.enrollRelay(
        endpoint: endpoint,
        enrollmentToken: token,
      );
      if (result is NetworkFailure<void>) {
        if (!mounted) return;
        setState(() {
          _isEnrolling = false;
          _isEnrolled = false;
        });
        _showError(
          settings.isEnglish
              ? 'Enrollment failed (${result.error.code.name}).'
              : '注册失败（${result.error.code.name}）。',
        );
        return;
      }
      _tokenController.clear();
      if (!mounted) return;
      setState(() {
        _isEnrolling = false;
        _isEnrolled = true;
        _isExpanded = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            settings.isEnglish
                ? 'Device enrollment and authentication succeeded.'
                : '设备注册与身份验证成功。',
          ),
        ),
      );
    } catch (error, stackTrace) {
      context.read<LanShareLoggerPort>().warning(
        'Relay enrollment failed',
        details: '$error\n$stackTrace',
      );
      if (!mounted) return;
      setState(() {
        _isEnrolling = false;
        _isEnrolled = false;
      });
      _showError(
        settings.isEnglish
            ? 'Enrollment failed. Check the server, TLS certificate, and token.'
            : '注册失败，请检查服务器、TLS 证书和 Token。',
      );
    }
  }

  /// 通过协调器检查已存储 enrollment。
  Future<void> _refreshEnrollment() async {
    final settings = context.read<AppSettings>();
    final logger = context.read<LanShareLoggerPort>();
    await settings.ensureLanIdentity();
    if (!mounted || settings.relayEndpoint.isEmpty) {
      if (mounted) setState(() => _isEnrolled = false);
      return;
    }
    try {
      final enrolled = await context
          .read<LanReceiverCoordinator>()
          .connectConfiguredRelay();
      if (mounted) {
        setState(() => _isEnrolled = enrolled is NetworkSuccess<void>);
      }
    } catch (error, stackTrace) {
      logger.warning(
        'Relay connection verification failed',
        details: '$error\n$stackTrace',
      );
      if (mounted) setState(() => _isEnrolled = false);
    }
  }

  /// 展示可安全本地化的 enrollment 错误信息。
  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: Theme.of(context).colorScheme.error,
      ),
    );
  }

  /// 构建 enrollment 卡片 UI。
  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final strings = settings.strings;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final currentHost = settings.relayHost;
    final currentPort = settings.relayPort > 0 ? settings.relayPort : 443;

    return Card(
      elevation: 0,
      color: colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(
          color: colorScheme.outlineVariant.withValues(alpha: 0.5),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header bar (Tappable to expand / collapse)
            InkWell(
              onTap: () => setState(() => _isExpanded = !_isExpanded),
              borderRadius: BorderRadius.circular(12),
              child: Row(
                children: [
                  Icon(Icons.dns_rounded, color: colorScheme.primary, size: 20),
                  const SizedBox(width: 8),
                  Text(
                    strings.vpnServerConfigTitle,
                    style: theme.textTheme.titleSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    currentHost.isEmpty
                        ? (strings.isEnglish ? '(Not configured)' : '（未配置）')
                        : '($currentHost:$currentPort)',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontFamily: 'monospace',
                    ),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: _isEnrolled == true
                          ? Colors.green.withValues(alpha: 0.15)
                          : Colors.orange.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: _isEnrolled == true
                            ? Colors.green
                            : Colors.orange,
                      ),
                    ),
                    child: Text(
                      _isEnrolled == true
                          ? strings.vpnEnrolledBadge
                          : strings.vpnNotEnrolledBadge,
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                        color: _isEnrolled == true
                            ? Colors.green
                            : Colors.orange,
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    color: colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
            if (_isExpanded) ...[
              const Divider(height: 20),
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
              TextField(
                controller: _tokenController,
                decoration: InputDecoration(
                  labelText: strings.vpnEnrollmentToken,
                  hintText: strings.isEnglish
                      ? 'Required token from the relay dashboard'
                      : '必填：中继管理面板显示的 Token',
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
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.verified_user_rounded),
                    label: Text(strings.vpnEnrollButton),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class VpnP2pShareView extends StatelessWidget {
  /// 创建 Relay 分享设置页面。
  const VpnP2pShareView({super.key});

  /// 构建 Relay 设置页面。
  @override
  Widget build(BuildContext context) {
    return const SingleChildScrollView(
      padding: EdgeInsets.all(16.0),
      child: VpnP2pServerConfigCard(),
    );
  }
}
