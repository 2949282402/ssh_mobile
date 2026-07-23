part of '../lan_share_screen.dart';

extension _LanShareDialogActions on _LanShareScreenState {
  void _showTargetDevicePickerAndSend(List<String> filePaths) {
    final vm = context.read<LanShareViewModel>();
    final strings = AppStrings(context.read<AppSettings>().language);

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
                  final opened = await vm.requestPairing(dev);
                  if (!mounted) return;
                  if (!opened) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text(strings.lanShareOffline)),
                    );
                  }
                  return;
                }
                for (final path in filePaths) {
                  final sent = await vm.sendFile(dev, path);
                  if (!sent && mounted) {
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

    // Try parsing as URL first (web share link)
    if (input.startsWith('http://') || input.startsWith('https://')) {
      final uri = Uri.tryParse(input);
      if (uri != null) {
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
        // Compatibility with QR links produced before nativePort was included.
        if (advertisedPort == null && port == 53319) {
          port = 53317;
        }
      }
    } else {
      // Parse as IP:Port or just IP
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

    // Register manual device
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

  Future<bool> _requestPairingWithFeedback(
    BuildContext context,
    LanShareViewModel vm,
    LanDevice device,
    AppStrings strings,
  ) async {
    final opened = await vm.requestPairing(device);
    if (!opened && context.mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(strings.lanShareOffline)));
    }
    return opened;
  }

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

class _ChatSession {
  final String deviceId;
  final String alias;
  final String osName;
  final LanMessage lastMessage;
  final bool isOnline;

  _ChatSession({
    required this.deviceId,
    required this.alias,
    required this.osName,
    required this.lastMessage,
    required this.isOnline,
  });
}

class WebShareDialogContent extends StatefulWidget {
  final LanShareViewModel vm;
  final AppStrings strings;

  const WebShareDialogContent({
    super.key,
    required this.vm,
    required this.strings,
  });

  @override
  State<WebShareDialogContent> createState() => _WebShareDialogContentState();
}

class _WebShareDialogContentState extends State<WebShareDialogContent> {
  Timer? _timer;
  int _secondsRemaining = 60;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

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

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isEn = widget.vm.appSettings.isEnglish;
    final httpsLabel = isEn ? 'Secure Connection (HTTPS)' : '启用安全连接 (HTTPS)';

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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Flexible(
                  child: Text(
                    httpsLabel,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                Switch(
                  value: widget.vm.webShareUseHttps,
                  onChanged: (val) async {
                    await widget.vm.discoveryService.stopWebShareServer();
                    widget.vm.setWebShareUseHttps(val);
                    await widget.vm.discoveryService.startWebShareServer(
                      useHttps: val,
                      securityService: widget.vm.securityService,
                      storageService: widget.vm.storageService,
                      transferService: widget.vm.transferService,
                    );
                    if (mounted) {
                      setState(() {});
                    }
                  },
                ),
              ],
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
