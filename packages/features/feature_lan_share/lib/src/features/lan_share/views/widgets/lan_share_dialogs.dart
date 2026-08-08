// v1 LAN Share 配对、WebShare 与设备地址对话框。
// WebShare 链接只接受 HTTPS，避免从界面入口引入明文降级。

part of '../lan_share_screen.dart';

extension _LanShareDialogActions on _LanShareScreenState {
  /// 展示已发现设备并向用户选中的设备发送文件。
  void _showTargetDevicePickerAndSend(List<String> filePaths) {
    final vm = context.read<LanShareViewModel>();
    final strings = context.read<AppSettings>().strings;

    showModalBottomSheet(
      context: context,
      builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Text(
              strings.lanShareSendToNearby,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
          ...vm.devices.map(
            (dev) => ListTile(
              title: Text(dev.alias),
              subtitle: Text(dev.ip),
              onTap: () async {
                Navigator.pop(ctx);
                final paired = await vm.isDevicePaired(dev.id);
                if (!mounted) return;
                if (!paired) {
                  final pairingResult = await vm.requestPairing(dev);
                  if (!mounted) return;
                  if (pairingResult is NetworkFailure) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(strings.lanShareOffline)),
                    );
                  }
                  return;
                }
                for (final path in filePaths) {
                  final sendResult = await vm.sendFile(dev, path);
                  if (sendResult is NetworkFailure && mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(strings.lanShareOffline)),
                    );
                    break;
                  }
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 启动固定 HTTPS WebShare，并展示访问二维码和 PIN。
  void _toggleWebShareDialog(
    BuildContext context,
    AppStrings strings,
    LanShareViewModel vm,
  ) async {
    if (!vm.isWebShareActive) {
      await vm.toggleWebShare();
    }
    if (!context.mounted) return;

    if (vm.isWebShareActive && vm.webShareUrl != null) {
      vm.securityService.getOrGenerate6DigitPin();
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 16.0,
            vertical: 24.0,
          ),
          title: Text(strings.lanShareScanQrCode),
          content: WebShareDialogContent(vm: vm, strings: strings),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(strings.close),
            ),
          ],
        ),
      );
      // Stop the server when the user closes the QR dialog, reversing the icon state.
      if (context.mounted && vm.isWebShareActive) {
        await vm.toggleWebShare();
      }
    }
  }

  /// 解析 HTTPS WebShare 链接或 IP 地址，并发起配对请求。
  void _connectToScannedOrInput(
    BuildContext context,
    String input,
    LanShareViewModel vm,
    AppStrings strings,
  ) {
    String ip = '';
    int port = 53317;
    String? advertisedDeviceId;
    String? advertisedFingerprint;

    // 只有 HTTPS scheme 才能作为 WebShare 链接解析。
    final parsedUri = Uri.tryParse(input);
    if (parsedUri != null && parsedUri.scheme.isNotEmpty) {
      if (parsedUri.scheme != 'https') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(strings.lanShareInvalidAddress)));
        return;
      }
      final uri = parsedUri;
      ip = uri.host;
      advertisedDeviceId = uri.queryParameters['deviceId'];
      final fingerprint = uri.queryParameters['certFingerprint']
          ?.trim()
          .toLowerCase();
      if (fingerprint != null &&
          RegExp(r'^[0-9a-f]{64}$').hasMatch(fingerprint)) {
        advertisedFingerprint = fingerprint;
      }
      final advertisedPort = int.tryParse(
        uri.queryParameters['nativePort'] ?? '',
      );
      port = advertisedPort ?? uri.port;
      // 兼容未包含 nativePort 的旧二维码链接。
      if (advertisedPort == null && port == 53319) {
        port = 53317;
      }
    } else {
      // 解析 IP:端口或纯 IP 地址。
      final parts = input.split(':');
      ip = parts[0].trim();
      if (parts.length > 1) {
        port = int.tryParse(parts[1].trim()) ?? 53317;
      }
    }

    if (ip.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.lanShareInvalidAddress)));
      return;
    }

    // 注册手动输入的设备。
    final deviceId = advertisedDeviceId?.trim().isNotEmpty == true
        ? advertisedDeviceId!.trim()
        : 'manual_${ip}_$port';
    final device = LanDevice(
      id: deviceId,
      alias: ip,
      ip: ip,
      port: port,
      deviceType: LanDeviceType.mobile,
      osName: 'Unknown OS',
      certFingerprint: advertisedFingerprint,
      lastSeen: DateTime.now(),
    );

    unawaited(_requestPairingWithFeedback(context, vm, device, strings));
  }

  /// 请求设备配对，并把网络失败转换成界面提示。
  Future<NetworkResult<void>> _requestPairingWithFeedback(
    BuildContext context,
    LanShareViewModel vm,
    LanDevice device,
    AppStrings strings,
  ) async {
    final result = await vm.requestPairing(device);
    if (result is NetworkFailure && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.lanShareOffline)));
    }
    return result;
  }

  /// 展示手动输入设备 IP、端口或 HTTPS WebShare 链接的对话框。
  Future<String?> _showManualAddDialog(
    BuildContext context,
    AppStrings strings,
  ) async {
    final controller = TextEditingController();
    final isEn = context.read<LanShareViewModel>().appSettings.isEnglish;
    final title = isEn ? 'Connect to Device' : '连接到设备';
    final description = isEn
        ? 'Please enter the target device address (IP, IP:Port, or Web Share link):'
        : '请输入目标设备的快传连接地址（支持 IP、IP:端口 或快传网页链接）：';
    final hint = isEn
        ? 'Enter IP address, IP:Port or Web Share URL'
        : '输入 IP 地址、IP:端口 或快传网页链接';
    final cancelLabel = strings.cancel;
    final confirmLabel = isEn ? 'Connect' : '连接';

    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(description, style: Theme.of(ctx).textTheme.bodyMedium),
              const SizedBox(height: 16),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(
                  hintText: hint,
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (val) => Navigator.pop(ctx, val.trim()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(cancelLabel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
  }

  /// 展示本机 LAN 地址选择器并更新 WebShare 地址覆盖值。
  void _showIpSelectorDialog(
    BuildContext context,
    Map<String, String> ipMap,
    LanShareViewModel vm,
  ) {
    final isEn = vm.appSettings.isEnglish;
    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text(isEn ? 'Select LAN IP Address' : '选择局域网 IP 地址'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ListTile(
                  title: Text(isEn ? 'Automatic (Default)' : '自动选择（默认第一个）'),
                  trailing: vm.customIp == null
                      ? Icon(
                          Icons.check_rounded,
                          color: Theme.of(context).colorScheme.primary,
                        )
                      : null,
                  onTap: () {
                    vm.setCustomIp(null);
                    Navigator.pop(ctx);
                  },
                ),
                ...ipMap.entries.map((entry) {
                  final ip = entry.key;
                  final interfaceName = entry.value;
                  final friendlyName = _getFriendlyInterfaceName(interfaceName);
                  return ListTile(
                    title: Text(ip),
                    subtitle: Text('$friendlyName ($interfaceName)'),
                    trailing: vm.customIp == ip
                        ? Icon(
                            Icons.check_rounded,
                            color: Theme.of(context).colorScheme.primary,
                          )
                        : null,
                    onTap: () {
                      vm.setCustomIp(ip);
                      Navigator.pop(ctx);
                    },
                  );
                }),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(isEn ? 'Cancel' : '取消'),
            ),
          ],
        );
      },
    );
  }

  /// 将系统网卡名称转换为用户可读的本地化类别。
  String _getFriendlyInterfaceName(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('tailscale')) return 'Tailscale';
    if (lower.contains('wlan') ||
        lower.contains('wi-fi') ||
        lower.contains('wifi')) {
      return 'Wi-Fi / 无线网卡';
    }
    if (lower.contains('eth') || lower.contains('ethernet')) {
      return '以太网';
    }
    if (lower.contains('tun') ||
        lower.contains('tap') ||
        lower.contains('vpn')) {
      return 'VPN / 隧道网卡';
    }
    return name;
  }
}

/// 表示对话框中最近一条 LAN 消息对应的设备会话。
class _ChatSession {
  final String deviceId;
  final String alias;
  final String osName;
  final LanMessage lastMessage;
  final bool isOnline;

  /// 创建一条设备会话摘要。
  _ChatSession({
    required this.deviceId,
    required this.alias,
    required this.osName,
    required this.lastMessage,
    required this.isOnline,
  });
}

/// 展示固定 HTTPS WebShare 地址、PIN 和剩余有效时间。
class WebShareDialogContent extends StatefulWidget {
  final LanShareViewModel vm;
  final AppStrings strings;

  /// 创建 WebShare 对话框内容。
  const WebShareDialogContent({
    super.key,
    required this.vm,
    required this.strings,
  });

  /// 创建 WebShare 对话框的有状态实现。
  @override
  State<WebShareDialogContent> createState() => _WebShareDialogContentState();
}

/// 管理 WebShare PIN 倒计时和内容布局。
class _WebShareDialogContentState extends State<WebShareDialogContent> {
  Timer? _timer;
  int _secondsRemaining = 60;

  /// 初始化 WebShare PIN 倒计时。
  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  /// 启动 PIN 倒计时，并在过期后生成新 PIN。
  void _startTimer() {
    _secondsRemaining = widget.vm.securityService.pinSecondsRemaining;
    if (_secondsRemaining <= 0) {
      widget.vm.securityService.generate6DigitPin();
      _secondsRemaining = 60;
    }
    _timer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          if (_secondsRemaining > 0) {
            _secondsRemaining--;
          } else {
            widget.vm.securityService.generate6DigitPin();
            _secondsRemaining = 60;
          }
        });
      }
    });
  }

  /// 释放 PIN 倒计时资源。
  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// 构建 WebShare 地址和安全状态展示内容。
  @override
  Widget build(BuildContext context) {
    final isEn = widget.vm.appSettings.isEnglish;
    final httpsLabel = isEn ? 'WebShare uses HTTPS' : 'WebShare 使用 HTTPS';

    return SizedBox(
      width: 280,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Horizontally scrollable hint text
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Text(
                widget.strings.lanShareWebShareHint,
                maxLines: 1,
                style: Theme.of(context).textTheme.bodyMedium,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              httpsLabel,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            if (widget.vm.webShareUrl != null) ...[
              QrImageView(
                data: widget.vm.webShareUrl!,
                version: QrVersions.auto,
                size: 200.0,
                backgroundColor: Colors.white,
              ),
              const SizedBox(height: 12),
              SelectableText(
                widget.vm.webShareUrl!,
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  color: Colors.blue,
                ),
              ),
            ],
            const SizedBox(height: 16),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primaryContainer,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Stack(
                    alignment: Alignment.center,
                    children: [
                      SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          value: _secondsRemaining / 60.0,
                          strokeWidth: 2.5,
                          backgroundColor: Theme.of(
                            context,
                          ).colorScheme.primary.withValues(alpha: 0.15),
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Theme.of(context).colorScheme.primary,
                          ),
                        ),
                      ),
                      Text(
                        '$_secondsRemaining',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      '${widget.strings.lanSharePinPairing}: ${widget.vm.securityService.activePin ?? ""}',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: Theme.of(context).colorScheme.onPrimaryContainer,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
