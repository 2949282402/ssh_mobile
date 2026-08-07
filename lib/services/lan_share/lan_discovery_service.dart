// v1 LAN 发现、广播与 WebShare 生命周期服务。
//
// 设备事件保持类型化事件流，生命周期和 WebShare 命令返回统一
// NetworkResult 模型。

import 'dart:async';

import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'lan_multicast_lock.dart';
import 'lan_network_models.dart';
import '../network/network_models.dart';
import 'lan_share_models.dart';
import 'lan_security_service.dart';
import 'lan_storage_service.dart';
import 'lan_transfer_protocol.dart';
import 'lan_transfer_service.dart';

part 'lan_web_share_server.dart';
part 'lan_web_share_upload.dart';

/// 负责 LAN 设备发现（mDNS 与 UDP 备用路径）以及 Web Share 服务。
class LanDiscoveryService {
  static const String serviceType = '_ssh-mobile-share._tcp';
  static const int defaultPort = 53317;
  static const int udpDiscoveryPort = 53318;
  // 手动输入和二维码解析得到的对端需要比一分钟配对会话存活更久，
  // 避免清理逻辑使正在显示的 PIN 界面失效。
  static const Duration devicePresenceTtl = Duration(seconds: 90);
  static const Duration _deviceCleanupInterval = Duration(seconds: 10);
  static const Duration _pendingWebUploadTtl = Duration(minutes: 5);
  static const int _maxPendingWebUploads = 32;
  static const int _e2eEnvelopeOverheadBytes = 60;
  static const String _webShareTokenHeader = 'x-web-share-token';

  final String currentDeviceId;
  String currentDeviceAlias;
  final LanMulticastLock multicastLock;

  nsd.Registration? _registration;
  int? _advertisedPort;
  nsd.Discovery? _discovery;
  RawDatagramSocket? _udpSocket;
  Timer? _udpBroadcastTimer;
  Timer? _deviceCleanupTimer;
  int _udpBroadcastCount = 0;
  int _discoveryGeneration = 0;
  Future<void> _discoveryLifecycle = Future<void>.value();

  final _discoveredDevicesController =
      StreamController<List<LanDevice>>.broadcast();
  final Map<String, LanDevice> _deviceMap = {};

  bool _isScanning = false;

  /// 当前是否正在运行主动发现。
  bool get isScanning => _isScanning;

  /// 当前通过 mDNS 和 UDP 广播的原生 HTTPS 端口。
  int? get advertisedPort => _advertisedPort;

  HttpServer? _webShareServer;
  bool _isWebShareActive = false;

  /// 当前是否正在运行 WebShare 服务。
  bool get isWebShareActive => _isWebShareActive;
  String? _webShareUrl;

  /// WebShare 激活时返回当前 URL。
  String? get webShareUrl => _webShareUrl;
  String? _webShareToken;
  final Map<String, _PendingWebUpload> _pendingWebUploads = {};

  String? _customIp;

  /// 返回 WebShare URL 使用的可选 IP 覆盖值。
  String? get customIp => _customIp;

  /// 更新 WebShare IP 覆盖值，不改变已绑定的服务。
  void setCustomIp(String? ip) {
    _customIp = ip;
    if (_isWebShareActive && _webShareServer != null) {
      final hostIp = ip ?? '127.0.0.1';
      final currentUrl = Uri.tryParse(_webShareUrl ?? '');
      if (currentUrl != null) {
        _webShareUrl = currentUrl.replace(host: hostIp).toString();
      }
    }
  }

  /// 使用可选的平台组播锁创建发现服务。
  LanDiscoveryService({
    required this.currentDeviceId,
    required this.currentDeviceAlias,
    LanMulticastLock? multicastLock,
  }) : multicastLock = multicastLock ?? PlatformLanMulticastLock();

  /// 动态更新当前设备别名；若正在广播则重新启动广播。
  Future<NetworkResult<void>> updateDeviceAlias(String newAlias) async {
    if (currentDeviceAlias == newAlias) {
      return const NetworkSuccess<void>(null);
    }
    currentDeviceAlias = newAlias;
    final activePort = _advertisedPort;
    if (activePort != null) {
      debugPrint(
        '[LanDiscoveryService] Restarting advertising with new alias: $newAlias',
      );
      await stopAdvertising();
      await startAdvertising(port: activePort);
    }
    return const NetworkSuccess<void>(null);
  }

  /// 移除 mDNS 设备标识中的显示后缀。
  String _extractCleanId(String rawId) {
    if (rawId.contains('(') && rawId.endsWith(')')) {
      final start = rawId.lastIndexOf('(') + 1;
      final end = rawId.length - 1;
      if (start < end) {
        return rawId.substring(start, end).trim();
      }
    }
    return rawId;
  }

  /// 移除 mDNS 显示别名中的标识后缀。
  String _extractCleanAlias(String rawAlias) {
    if (rawAlias.contains('(') && rawAlias.endsWith(')')) {
      final start = rawAlias.lastIndexOf('(');
      if (start > 0) {
        return rawAlias.substring(0, start).trim();
      }
    }
    return rawAlias;
  }

  /// 发布去重后的已发现设备列表。
  Stream<List<LanDevice>> get discoveredDevicesStream =>
      _discoveredDevicesController.stream;

  /// 返回按最近观察时间排序的已发现设备。
  List<LanDevice> get currentDiscoveredDevices {
    final uniqueDevices = <String, LanDevice>{};
    final sorted = _deviceMap.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    for (final device in sorted) {
      final cleanId = _extractCleanId(device.id);
      if (uniqueDevices.containsKey(cleanId)) {
        // 已存在时保留 lastSeen 更新的记录。
        final existing = uniqueDevices[cleanId]!;
        if (device.lastSeen.isAfter(existing.lastSeen)) {
          uniqueDevices[cleanId] = device.copyWith(id: cleanId);
        }
        continue;
      }
      uniqueDevices[cleanId] = device.copyWith(id: cleanId);
    }
    return uniqueDevices.values.toList();
  }

  /// 过滤虚拟网络接口（VPN、Docker、vEthernet）。
  static Future<List<String>> getLocalIpAddresses() async {
    final addresses = <String>[];
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        final name = interface.name.toLowerCase();
        if (name.contains('docker') ||
            name.contains('vethernet') ||
            name.contains('vbox') ||
            name.contains('vmnet') ||
            name.contains('vEthernet')) {
          continue;
        }
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('169.254.')) {
            addresses.add(addr.address);
          }
        }
      }
    } catch (e) {
      debugPrint('[LanDiscoveryService] Error listing network interfaces: $e');
    }
    return addresses;
  }

  /// 获取映射到网络接口名称的本地 IPv4 地址。
  static Future<Map<String, String>> getLocalIpInterfaces() async {
    final map = <String, String>{};
    try {
      final interfaces = await NetworkInterface.list(
        includeLoopback: false,
        type: InternetAddressType.IPv4,
      );
      for (final interface in interfaces) {
        final name = interface.name;
        final lowerName = name.toLowerCase();
        if (lowerName.contains('docker') ||
            lowerName.contains('vethernet') ||
            lowerName.contains('vbox') ||
            lowerName.contains('vmnet') ||
            lowerName.contains('vEthernet')) {
          continue;
        }
        for (final addr in interface.addresses) {
          if (!addr.isLoopback && !addr.address.startsWith('169.254.')) {
            map[addr.address] = name;
          }
        }
      }
    } catch (e) {
      debugPrint('[LanDiscoveryService] Error listing network interfaces: $e');
    }
    return map;
  }

  /// 启动 mDNS 注册，向附近对端广播本设备。
  Future<NetworkResult<void>> startAdvertising({int port = defaultPort}) async {
    _advertisedPort = port;
    try {
      await performStartAdvertising(port);
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'LAN advertising failed.',
          operation: NetworkOperation.startAdvertising,
        ),
      );
    }
  }

  /// 执行平台 mDNS/UDP 广播初始化。
  @protected
  Future<void> performStartAdvertising(int port) async {
    try {
      final ips = await getLocalIpAddresses();
      final primaryIp = ips.isNotEmpty ? ips.first : '0.0.0.0';
      _registration = await nsd.register(
        nsd.Service(
          name: '$currentDeviceAlias ($currentDeviceId)',
          type: serviceType,
          port: port,
          txt: {
            'id': utf8.encode(currentDeviceId),
            'alias': utf8.encode(currentDeviceAlias),
            'os': utf8.encode(Platform.operatingSystem),
            'ip': utf8.encode(primaryIp),
          },
        ),
      );
      debugPrint(
        '[LanDiscoveryService] mDNS Advertising started on port $port',
      );
    } catch (e) {
      debugPrint('[LanDiscoveryService] mDNS Advertising error: $e');
    }

    await _startUdpListener(port);
  }

  /// 停止 mDNS 注册。
  Future<NetworkResult<void>> stopAdvertising() async {
    try {
      await performStopAdvertising();
      _advertisedPort = null;
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'LAN advertising stop failed.',
          operation: NetworkOperation.stopAdvertising,
        ),
      );
    }
  }

  /// 执行平台 mDNS/UDP 广播清理。
  @protected
  Future<void> performStopAdvertising() async {
    await _sendUdpDisconnect();
    if (_registration != null) {
      try {
        await nsd.unregister(_registration!);
        _registration = null;
      } catch (e) {
        debugPrint('[LanDiscoveryService] mDNS Unregister error: $e');
      }
    }
    _stopUdpListener();
  }

  /// 启动主动发现（mDNS 与限速 UDP 广播备用路径）。
  Future<NetworkResult<void>> startDiscovery() async {
    if (_isScanning) return const NetworkSuccess<void>(null);
    _isScanning = true;
    final generation = ++_discoveryGeneration;
    _deviceMap.clear();
    _notifyDevicesUpdated();

    try {
      await _enqueueDiscoveryLifecycle(
        () => _performStartDiscovery(generation),
      );
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'LAN discovery start failed.',
          operation: NetworkOperation.startDiscovery,
        ),
      );
    }
  }

  /// 为一个串行化生命周期代次启动发现资源。
  Future<void> _performStartDiscovery(int generation) async {
    if (!_isCurrentDiscoveryStart(generation)) return;

    var multicastLockAcquired = false;
    try {
      await multicastLock.acquire();
      multicastLockAcquired = true;
    } catch (e) {
      debugPrint('[LanDiscoveryService] Multicast lock error: $e');
    }
    if (!_isCurrentDiscoveryStart(generation)) {
      if (multicastLockAcquired) {
        await _releaseMulticastLock();
      }
      return;
    }

    nsd.Discovery? discovery;
    try {
      discovery = await performStartDiscovery();
    } catch (e) {
      debugPrint('[LanDiscoveryService] mDNS Discovery error: $e');
    }
    if (!_isCurrentDiscoveryStart(generation)) {
      if (discovery != null) {
        await _stopNsdDiscovery(discovery);
      }
      if (multicastLockAcquired) {
        await _releaseMulticastLock();
      }
      return;
    }

    if (discovery != null) {
      _discovery = discovery;
      discovery.addListener(() {
        if (!_isCurrentDiscoveryStart(generation) ||
            !identical(_discovery, discovery)) {
          return;
        }
        for (final service in discovery!.services) {
          _handleDiscoveredNsdService(service);
        }
      });
      debugPrint('[LanDiscoveryService] mDNS Discovery started');
    }

    _startRateLimitedUdpBroadcast();
    _startDeviceCleanup();
  }

  /// 停止主动发现以节省电量和网络带宽。
  Future<NetworkResult<void>> stopDiscovery() async {
    final generation = ++_discoveryGeneration;
    _isScanning = false;
    _cancelDiscoveryTimers();
    try {
      await _enqueueDiscoveryLifecycle(() => _performStopDiscovery(generation));
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'LAN discovery stop failed.',
          operation: NetworkOperation.stopDiscovery,
        ),
      );
    }
  }

  /// 停止发现资源并释放组播锁。
  Future<void> _performStopDiscovery(int generation) async {
    // 清理必须无条件执行。过期的启动任务可能在请求 stopDiscovery() 后仍创建资源。
    _cancelDiscoveryTimers();
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      await _stopNsdDiscovery(discovery);
    }

    // 生命周期操作已串行化，因此当前停止操作释放共享锁前，更新代次无法获取它。
    await _releaseMulticastLock();
    if (generation == _discoveryGeneration || !_isScanning) {
      debugPrint('[LanDiscoveryService] Discovery stopped');
    }
  }

  /// 停止一个 mDNS 发现实例，同时保持清理安全性。
  Future<void> _stopNsdDiscovery(nsd.Discovery discovery) async {
    try {
      await performStopDiscovery(discovery);
    } catch (e) {
      debugPrint('[LanDiscoveryService] mDNS Stop Discovery error: $e');
    }
  }

  /// 释放平台组播锁。
  Future<void> _releaseMulticastLock() async {
    try {
      await multicastLock.release();
    } catch (e) {
      debugPrint('[LanDiscoveryService] Multicast unlock error: $e');
    }
  }

  /// 取消发现广播和过期设备定时器。
  void _cancelDiscoveryTimers() {
    _deviceCleanupTimer?.cancel();
    _deviceCleanupTimer = null;
    _udpBroadcastTimer?.cancel();
    _udpBroadcastTimer = null;
  }

  /// 返回 [generation] 是否仍是当前主动发现请求。
  bool _isCurrentDiscoveryStart(int generation) =>
      _isScanning && generation == _discoveryGeneration;

  /// 串行化发现生命周期操作。
  Future<void> _enqueueDiscoveryLifecycle(Future<void> Function() operation) {
    final next = _discoveryLifecycle.then((_) => operation());
    _discoveryLifecycle = next.catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      debugPrint('[LanDiscoveryService] Discovery lifecycle error: $error');
    });
    return next;
  }

  /// 创建平台 mDNS 发现实例。
  @protected
  Future<nsd.Discovery> performStartDiscovery() =>
      nsd.startDiscovery(serviceType);

  /// 停止平台 mDNS 发现实例。
  @protected
  Future<void> performStopDiscovery(nsd.Discovery discovery) =>
      nsd.stopDiscovery(discovery);

  /// 将一个 mDNS 服务记录转换为类型化 LAN 设备。
  void _handleDiscoveredNsdService(nsd.Service service) {
    final txt = service.txt ?? {};
    final rawId = txt['id'] != null
        ? utf8.decode(txt['id']!)
        : service.name ?? '';
    final id = _extractCleanId(rawId);
    if (id.isEmpty || id == currentDeviceId) return;

    final rawAlias = txt['alias'] != null
        ? utf8.decode(txt['alias']!)
        : service.name ?? 'Device';
    final alias = _extractCleanAlias(rawAlias);
    final os = txt['os'] != null ? utf8.decode(txt['os']!) : 'Unknown';
    var hostIp =
        service.host ?? (txt['ip'] != null ? utf8.decode(txt['ip']!) : '');
    if (hostIp.startsWith('::ffff:')) {
      hostIp = hostIp.substring(7);
    }
    final port = service.port ?? defaultPort;

    if (hostIp.isEmpty) return;

    final device = LanDevice(
      id: id,
      alias: alias,
      ip: hostIp,
      port: port,
      deviceType: _guessDeviceType(os),
      osName: os,
      lastSeen: DateTime.now(),
    );

    _deviceMap[id] = device;
    _notifyDevicesUpdated();
  }

  /// 将发现到的操作系统标签映射为功能使用的设备类别。
  LanDeviceType _guessDeviceType(String os) {
    final lower = os.toLowerCase();
    if (lower.contains('android') || lower.contains('ios')) {
      return LanDeviceType.mobile;
    }
    if (lower.contains('web')) {
      return LanDeviceType.webBrowser;
    }
    return LanDeviceType.desktop;
  }

  /// 发布当前已发现设备快照。
  void _notifyDevicesUpdated() {
    if (!_discoveredDevicesController.isClosed) {
      _discoveredDevicesController.add(currentDiscoveredDevices);
    }
  }

  /// 启动过期发现记录的定期清理。
  void _startDeviceCleanup() {
    _deviceCleanupTimer?.cancel();
    _deviceCleanupTimer = Timer.periodic(
      _deviceCleanupInterval,
      (_) => removeStaleDevices(),
    );
  }

  /// 清理过期设备，同时保留当前可见的 mDNS 对端。
  @visibleForTesting
  int removeStaleDevices({DateTime? now, Duration ttl = devicePresenceTtl}) {
    final cutoff = (now ?? DateTime.now()).subtract(ttl);
    final activeNsdDeviceIds = <String>{};
    final discovery = _discovery;
    if (discovery != null) {
      for (final service in discovery.services) {
        try {
          final txtId = service.txt?['id'];
          final rawId = txtId != null ? utf8.decode(txtId) : service.name ?? '';
          final id = _extractCleanId(rawId);
          if (id.isNotEmpty) activeNsdDeviceIds.add(id);
        } catch (_) {}
      }
    }
    final before = _deviceMap.length;
    _deviceMap.removeWhere(
      (_, device) =>
          device.lastSeen.isBefore(cutoff) &&
          !activeNsdDeviceIds.contains(_extractCleanId(device.id)),
    );
    final removed = before - _deviceMap.length;
    if (removed > 0) _notifyDevicesUpdated();
    return removed;
  }

  /// UDP 备用 ping 数据包监听器。
  /// 启动接收发现广播的 UDP 备用监听器。
  Future<void> _startUdpListener(int listeningHttpPort) async {
    try {
      _udpSocket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        udpDiscoveryPort,
        reuseAddress: true,
        reusePort: false,
      );
      _udpSocket!.broadcastEnabled = true;
      _udpSocket!.listen((event) {
        if (event == RawSocketEvent.read) {
          final datagram = _udpSocket!.receive();
          if (datagram == null) return;
          try {
            final messageStr = utf8.decode(datagram.data);
            final json = jsonDecode(messageStr) as Map<String, dynamic>;

            /// 注册一个通过 UDP 发现的对端，并发布设备快照。
            void registerDiscoveredDevice(
              String rawId,
              Map<String, dynamic> json,
              String hostIp,
            ) {
              final id = _extractCleanId(rawId);
              if (id.isEmpty || id == currentDeviceId) return;
              final cleanHostIp = hostIp.startsWith('::ffff:')
                  ? hostIp.substring(7)
                  : hostIp;
              final device = LanDevice(
                id: id,
                alias: json['alias'] as String? ?? 'Device',
                ip: cleanHostIp,
                port: (json['port'] as num?)?.toInt() ?? defaultPort,
                deviceType: _guessDeviceType(json['os'] as String? ?? ''),
                osName: json['os'] as String? ?? 'Unknown',
                lastSeen: DateTime.now(),
              );
              _deviceMap[id] = device;
              _notifyDevicesUpdated();
            }

            final type = json['type'] as String?;
            if (type == 'PING') {
              final senderId = json['id'] as String?;
              if (senderId != null && senderId != currentDeviceId) {
                _sendUdpPong(datagram.address, listeningHttpPort);
                registerDiscoveredDevice(
                  senderId,
                  json,
                  datagram.address.address,
                );
              }
            } else if (type == 'PONG') {
              final id = json['id'] as String?;
              if (id != null && id != currentDeviceId) {
                registerDiscoveredDevice(id, json, datagram.address.address);
              }
            } else if (type == 'BYE' ||
                type == 'DISCONNECT' ||
                type == 'OFFLINE') {
              final id = json['id'] as String?;
              if (id != null) {
                final cleanId = _extractCleanId(id);
                _deviceMap.remove(cleanId);
                _deviceMap.remove(id);
                _notifyDevicesUpdated();
              }
            }
          } catch (_) {}
        }
      });
    } catch (e) {
      debugPrint('[LanDiscoveryService] UDP listener error: $e');
    }
  }

  /// 停止 UDP 发现监听器。
  void _stopUdpListener() {
    _udpSocket?.close();
    _udpSocket = null;
  }

  /// 向发现 ping 发送 UDP 响应。
  void _sendUdpPong(InternetAddress targetAddress, int port) {
    if (_udpSocket == null) return;
    try {
      final payload = jsonEncode({
        'type': 'PONG',
        'id': currentDeviceId,
        'alias': currentDeviceAlias,
        'port': port,
        'os': Platform.operatingSystem,
      });
      final bytes = utf8.encode(payload);
      _udpSocket!.send(bytes, targetAddress, udpDiscoveryPort);
    } catch (_) {}
  }

  /// 向已发现对端广播 v1 离线通知。
  Future<void> _sendUdpDisconnect() async {
    if (_udpSocket == null) return;
    try {
      final payload = jsonEncode({
        'type': 'BYE',
        'id': currentDeviceId,
        'alias': currentDeviceAlias,
        'os': Platform.operatingSystem,
      });
      final bytes = utf8.encode(payload);
      _udpSocket!.send(
        bytes,
        InternetAddress('255.255.255.255'),
        udpDiscoveryPort,
      );

      final localIps = await getLocalIpAddresses();
      for (final ip in localIps) {
        final subnetBroadcast = _calculateSubnetBroadcast(ip);
        if (subnetBroadcast != '255.255.255.255') {
          _udpSocket!.send(
            bytes,
            InternetAddress(subnetBroadcast),
            udpDiscoveryPort,
          );
        }
      }
      debugPrint('[LanDiscoveryService] UDP Disconnect/BYE broadcast sent');
    } catch (e) {
      debugPrint('[LanDiscoveryService] Failed to send UDP disconnect: $e');
    }
  }

  /// 前 30 秒每秒快速扫描；30 秒内没有发现设备时自动停止。
  /// 启动限速 UDP 发现广播循环。
  void _startRateLimitedUdpBroadcast() {
    _udpBroadcastCount = 0;
    _udpBroadcastTimer?.cancel();
    _sendUdpPing();

    _scheduleNextUdpPing();
  }

  /// 根据扫描速率限制安排下一次 UDP 发现 ping。
  void _scheduleNextUdpPing() {
    if (!_isScanning) return;
    _udpBroadcastCount++;

    // 保持低频扫描，使热点或网络配置完成后加入的对端仍能出现，
    // 不要求用户重新启动发现。
    final int delaySeconds = _udpBroadcastCount < 10 ? 1 : 5;

    _udpBroadcastTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_isScanning) {
        _sendUdpPing();
        _scheduleNextUdpPing();
      }
    });
  }

  /// 返回 [ip] 是否属于私有 IPv4 地址范围。
  static bool _isPrivateIPv4(String ip) {
    try {
      final parts = ip.split('.');
      if (parts.length != 4) return false;
      final first = int.parse(parts[0]);
      final second = int.parse(parts[1]);
      if (first == 192 && second == 168) return true;
      if (first == 10) return true;
      if (first == 172 && second >= 16 && second <= 31) return true;
      return false;
    } catch (_) {
      return false;
    }
  }

  /// 计算 UDP 备用路径使用的 /24 广播地址。
  static String _calculateSubnetBroadcast(String ip) {
    final parts = ip.split('.');
    if (parts.length == 4) {
      return '${parts[0]}.${parts[1]}.${parts[2]}.255';
    }
    return '255.255.255.255';
  }

  /// 向全局、子网和限速主机目标发送发现 ping。
  Future<void> _sendUdpPing() async {
    if (_udpSocket == null) return;
    try {
      final payload = jsonEncode(
        createUdpPingPayload(
          deviceId: currentDeviceId,
          alias: currentDeviceAlias,
          os: Platform.operatingSystem,
          port: _advertisedPort ?? defaultPort,
        ),
      );
      final bytes = utf8.encode(payload);

      // 1. 发送到全局广播地址。
      _udpSocket!.send(
        bytes,
        InternetAddress('255.255.255.255'),
        udpDiscoveryPort,
      );

      // 2. 发送到所有本地子网广播地址（热点 AP 模式必须支持）。
      final localIps = await getLocalIpAddresses();
      for (final ip in localIps) {
        final subnetBroadcast = _calculateSubnetBroadcast(ip);
        if (subnetBroadcast != '255.255.255.255') {
          _udpSocket!.send(
            bytes,
            InternetAddress(subnetBroadcast),
            udpDiscoveryPort,
          );
        }

        // 3. 周期性的 /24 单播备用路径可帮助屏蔽广播的热点实现。
        // 不要每秒重复发送。
        final shouldProbeSubnet =
            _udpBroadcastCount <= 1 || _udpBroadcastCount % 6 == 0;
        if (shouldProbeSubnet && _isPrivateIPv4(ip)) {
          final parts = ip.split('.');
          if (parts.length == 4) {
            final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
            final selfHost = int.tryParse(parts[3]);
            for (int i = 1; i <= 254; i++) {
              if (i == selfHost) continue; // 跳过本机。
              try {
                _udpSocket!.send(
                  bytes,
                  InternetAddress('$prefix.$i'),
                  udpDiscoveryPort,
                );
              } catch (_) {}
            }
          }
        }
      }
    } catch (_) {}
  }

  /// 构建稳定的 v1 UDP 发现载荷。
  @visibleForTesting
  static Map<String, Object> createUdpPingPayload({
    required String deviceId,
    required String alias,
    required String os,
    required int port,
  }) {
    return {
      'type': 'PING',
      'id': deviceId,
      'alias': alias,
      'port': port,
      'os': os,
    };
  }

  /// 启动 Web Share 模式（为无 App 浏览器传输提供简洁 Web UI）。
  Future<NetworkResult<String>> startWebShareServer({
    int port = 53319,
    required LanSecurityService securityService,
    required LanStorageService storageService,
    required LanTransferService transferService,
  }) {
    return _startWebShareServerResult(
      port: port,
      securityService: securityService,
      storageService: storageService,
      transferService: transferService,
    );
  }

  /// 启动 WebShare 实现，并将失败转换为 v1 结果。
  Future<NetworkResult<String>> _startWebShareServerResult({
    required int port,
    required LanSecurityService securityService,
    required LanStorageService storageService,
    required LanTransferService transferService,
  }) async {
    try {
      final url = await _LanWebShareServerOperations(this)._startWebShareServer(
        port: port,
        securityService: securityService,
        storageService: storageService,
        transferService: transferService,
      );
      if (url == null || url.isEmpty) {
        return NetworkFailure(
          const NetworkError(
            code: NetworkErrorCode.ioError,
            message: 'WebShare did not provide an endpoint.',
            operation: NetworkOperation.startWebShare,
          ),
        );
      }
      return NetworkSuccess(url);
    } catch (error) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'WebShare start failed.',
          operation: NetworkOperation.startWebShare,
        ),
      );
    }
  }

  /// 停止 WebShare 服务并返回类型化结果。
  Future<NetworkResult<void>> stopWebShareServer() async {
    try {
      await _LanWebShareServerOperations(this)._stopWebShareServer();
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.ioError,
          message: 'WebShare stop failed.',
          operation: NetworkOperation.stopWebShare,
        ),
      );
    }
  }

  /// 新增或替换手动配置的对端。
  void registerManualDevice(LanDevice device) {
    _deviceMap[device.id] = device;
    _notifyDevicesUpdated();
  }

  /// 根据标识移除已发现或手动配置的对端。
  void removeDevice(String deviceId) {
    _deviceMap.remove(deviceId);
    _deviceMap.removeWhere(
      (key, device) => _extractCleanId(device.id) == deviceId,
    );
    _notifyDevicesUpdated();
  }

  /// 停止发现、广播、WebShare 以及设备事件流。
  void dispose() {
    stopDiscovery();
    stopAdvertising();
    stopWebShareServer();
    _discoveredDevicesController.close();
  }
}
