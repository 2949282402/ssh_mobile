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
    int? nativePort;
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
      final advertisedLanPort = int.tryParse(
        uri.queryParameters['lanPort'] ?? '',
      );
      final advertisedNativePort = int.tryParse(
        uri.queryParameters['nativePort'] ?? '',
      );
      // 新链接分别携带 HTTPS 控制端口和 native 文件传输端口；旧链接的
      // nativePort 实际是 HTTPS 端口，继续按原有语义兼容。
      port = advertisedLanPort ?? advertisedNativePort ?? uri.port;
      nativePort = advertisedLanPort == null ? null : advertisedNativePort;
      if (advertisedLanPort == null &&
          advertisedNativePort == null &&
          port == 53319) {
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
      nativePort: nativePort,
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
    final desktop = isDesktopLayout(context);
    Map<String, String> currentIpMap = Map<String, String>.from(ipMap);
    bool isRefreshing = false;

    Widget buildIpList(BuildContext ctx, StateSetter setDialogState) {
      final copySuccessMsg = isEn ? 'IP copied to clipboard' : 'IP 已复制到剪贴板';

      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildIpSelectorCardItem(
            context: ctx,
            title: isEn ? 'Automatic (Default)' : '自动选择（默认第一个）',
            subtitle: isEn
                ? 'System automatically uses the primary active network card'
                : '由系统自动判定推荐最适合的活动网卡',
            icon: Icons.alt_route_rounded,
            isSelected: vm.customIp == null,
            badgeText: isEn ? 'Auto' : '自动',
            copySuccessMsg: copySuccessMsg,
            onTap: () {
              vm.setCustomIp(null);
              Navigator.pop(ctx);
            },
          ),
          const SizedBox(height: 4),
          ...currentIpMap.entries.map((entry) {
            final ip = entry.key;
            final interfaceName = entry.value;
            final friendlyName = _getFriendlyInterfaceName(interfaceName);
            final icon = _getInterfaceIcon(interfaceName);
            final isSelected = vm.customIp == ip;
            final isDefaultIp = (currentIpMap.keys.firstOrNull == ip);
            final badgeText = isSelected
                ? (isEn ? 'In Use' : '使用中')
                : (vm.customIp == null && isDefaultIp
                      ? (isEn ? 'Default' : '默认')
                      : null);

            return _buildIpSelectorCardItem(
              context: ctx,
              title: ip,
              subtitle: '$friendlyName ($interfaceName)',
              icon: icon,
              isSelected: isSelected,
              badgeText: badgeText,
              ipToCopy: ip,
              copySuccessMsg: copySuccessMsg,
              onTap: () {
                vm.setCustomIp(ip);
                Navigator.pop(ctx);
              },
            );
          }),
        ],
      );
    }

    if (desktop) {
      showDialog(
        context: context,
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              final colors = Theme.of(ctx).colorScheme;
              final textTheme = Theme.of(ctx).textTheme;

              return Dialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxWidth: 520,
                    minWidth: 440,
                    maxHeight: 620,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    isEn
                                        ? 'Select LAN IP Address'
                                        : '选择局域网 IP 地址',
                                    style: textTheme.titleMedium?.copyWith(
                                      fontWeight: FontWeight.bold,
                                      fontSize: 18,
                                    ),
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    isEn
                                        ? 'Pick the preferred network card for discovery & WebShare'
                                        : '选择用于局域网设备扫描与 WebShare 的优先网卡',
                                    style: textTheme.bodySmall?.copyWith(
                                      color: colors.onSurfaceVariant,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            IconButton(
                              icon: isRefreshing
                                  ? SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: colors.primary,
                                      ),
                                    )
                                  : const Icon(Icons.refresh_rounded),
                              tooltip: isEn ? 'Refresh' : '刷新网卡',
                              onPressed: isRefreshing
                                  ? null
                                  : () async {
                                      setDialogState(() => isRefreshing = true);
                                      try {
                                        final updated =
                                            await LanDiscoveryService.getLocalIpInterfaces();
                                        if (ctx.mounted) {
                                          setDialogState(() {
                                            currentIpMap = updated;
                                            isRefreshing = false;
                                          });
                                        }
                                      } catch (_) {
                                        if (ctx.mounted) {
                                          setDialogState(
                                            () => isRefreshing = false,
                                          );
                                        }
                                      }
                                    },
                            ),
                            IconButton(
                              icon: const Icon(Icons.close_rounded),
                              tooltip: isEn ? 'Close' : '关闭',
                              onPressed: () => Navigator.pop(ctx),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        Flexible(
                          child: SingleChildScrollView(
                            child: buildIpList(ctx, setDialogState),
                          ),
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: TextButton(
                            onPressed: () => Navigator.pop(ctx),
                            child: Text(isEn ? 'Cancel' : '取消'),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          );
        },
      );
    } else {
      showModalBottomSheet(
        context: context,
        isScrollControlled: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        builder: (ctx) {
          return StatefulBuilder(
            builder: (ctx, setDialogState) {
              final colors = Theme.of(ctx).colorScheme;
              final textTheme = Theme.of(ctx).textTheme;

              return SafeArea(
                child: Container(
                  constraints: BoxConstraints(
                    maxHeight: MediaQuery.sizeOf(ctx).height * 0.75,
                  ),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Container(
                          width: 36,
                          height: 4,
                          margin: const EdgeInsets.only(bottom: 12),
                          decoration: BoxDecoration(
                            color: colors.outlineVariant,
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  isEn
                                      ? 'Select LAN IP Address'
                                      : '选择局域网 IP 地址',
                                  style: textTheme.titleMedium?.copyWith(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 17,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  isEn
                                      ? 'Pick the preferred network card'
                                      : '选择用于局域网扫描与传输的网卡',
                                  style: textTheme.bodySmall?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          IconButton(
                            icon: isRefreshing
                                ? SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                      color: colors.primary,
                                    ),
                                  )
                                : const Icon(Icons.refresh_rounded),
                            tooltip: isEn ? 'Refresh' : '刷新网卡',
                            onPressed: isRefreshing
                                ? null
                                : () async {
                                    setDialogState(() => isRefreshing = true);
                                    try {
                                      final updated =
                                          await LanDiscoveryService.getLocalIpInterfaces();
                                      if (ctx.mounted) {
                                        setDialogState(() {
                                          currentIpMap = updated;
                                          isRefreshing = false;
                                        });
                                      }
                                    } catch (_) {
                                      if (ctx.mounted) {
                                        setDialogState(
                                          () => isRefreshing = false,
                                        );
                                      }
                                    }
                                  },
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Flexible(
                        child: SingleChildScrollView(
                          child: buildIpList(ctx, setDialogState),
                        ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    }
  }

  Widget _buildIpSelectorCardItem({
    required BuildContext context,
    required String title,
    required String subtitle,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
    required String copySuccessMsg,
    String? badgeText,
    String? ipToCopy,
  }) {
    final colors = Theme.of(context).colorScheme;

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: isSelected
            ? colors.primaryContainer.withValues(alpha: 0.35)
            : colors.surfaceContainerLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? colors.primary
              : colors.outlineVariant.withValues(alpha: 0.5),
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? colors.primary.withValues(alpha: 0.15)
                        : colors.surfaceContainerHighest.withValues(alpha: 0.6),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    icon,
                    size: 20,
                    color: isSelected
                        ? colors.primary
                        : colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              title,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'monospace',
                                color: colors.onSurface,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (badgeText != null) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: isSelected
                                    ? colors.primary.withValues(alpha: 0.15)
                                    : colors.secondaryContainer,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                badgeText,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? colors.primary
                                      : colors.onSecondaryContainer,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          fontSize: 12,
                          color: colors.onSurfaceVariant.withValues(alpha: 0.8),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (ipToCopy != null) ...[
                  IconButton(
                    icon: const Icon(Icons.copy_rounded, size: 16),
                    tooltip: '复制 IP',
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: ipToCopy));
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(copySuccessMsg),
                          duration: const Duration(seconds: 2),
                          behavior: SnackBarBehavior.floating,
                        ),
                      );
                    },
                  ),
                ],
                if (isSelected) ...[
                  const SizedBox(width: 4),
                  Icon(
                    Icons.check_circle_rounded,
                    color: colors.primary,
                    size: 22,
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 将系统网卡名称转换为网络类型 Icon。
  IconData _getInterfaceIcon(String name) {
    final lower = name.toLowerCase();
    if (lower.contains('tailscale') ||
        lower.contains('vpn') ||
        lower.contains('wireguard') ||
        lower.contains('tun') ||
        lower.contains('tap')) {
      return Icons.vpn_key_rounded;
    }
    if (lower.contains('wlan') ||
        lower.contains('wi-fi') ||
        lower.contains('wifi') ||
        lower.contains('wireless')) {
      return Icons.wifi_rounded;
    }
    if (lower.contains('eth') ||
        lower.contains('ethernet') ||
        lower.contains('lan') ||
        lower.contains('以太网')) {
      return Icons.lan_rounded;
    }
    if (lower.contains('loopback') ||
        lower.contains('lo') ||
        lower.contains('127.0.0.1')) {
      return Icons.dns_rounded;
    }
    return Icons.router_rounded;
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
