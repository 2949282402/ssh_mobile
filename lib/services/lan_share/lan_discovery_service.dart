import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:nsd/nsd.dart' as nsd;
import 'lan_multicast_lock.dart';
import 'lan_share_models.dart';
import 'lan_security_service.dart';
import 'lan_storage_service.dart';
import 'lan_transfer_protocol.dart';
import 'lan_transfer_service.dart';

part 'lan_web_share_server.dart';
part 'lan_web_share_upload.dart';

/// Service responsible for LAN device discovery (mDNS + UDP fallback)
/// and Web Share server.
class LanDiscoveryService {
  static const String serviceType = '_ssh-mobile-share._tcp';
  static const int defaultPort = 53317;
  static const int udpDiscoveryPort = 53318;
  // Keep manually entered and QR-resolved peers alive longer than the
  // one-minute pairing session so cleanup cannot invalidate an active PIN UI.
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
  bool get isScanning => _isScanning;

  /// The native HTTPS port currently announced through mDNS and UDP.
  int? get advertisedPort => _advertisedPort;

  HttpServer? _webShareServer;
  bool _isWebShareActive = false;
  bool get isWebShareActive => _isWebShareActive;
  String? _webShareUrl;
  String? get webShareUrl => _webShareUrl;
  String? _webShareToken;
  final Map<String, _PendingWebUpload> _pendingWebUploads = {};

  String? _customIp;
  String? get customIp => _customIp;

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

  LanDiscoveryService({
    required this.currentDeviceId,
    required this.currentDeviceAlias,
    LanMulticastLock? multicastLock,
  }) : multicastLock = multicastLock ?? PlatformLanMulticastLock();

  /// Update the active device alias dynamically (restarts advertising if active)
  Future<void> updateDeviceAlias(String newAlias) async {
    if (currentDeviceAlias == newAlias) return;
    currentDeviceAlias = newAlias;
    final activePort = _advertisedPort;
    if (activePort != null) {
      debugPrint(
        '[LanDiscoveryService] Restarting advertising with new alias: $newAlias',
      );
      await stopAdvertising();
      await startAdvertising(port: activePort);
    }
  }

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

  String _extractCleanAlias(String rawAlias) {
    if (rawAlias.contains('(') && rawAlias.endsWith(')')) {
      final start = rawAlias.lastIndexOf('(');
      if (start > 0) {
        return rawAlias.substring(0, start).trim();
      }
    }
    return rawAlias;
  }

  Stream<List<LanDevice>> get discoveredDevicesStream =>
      _discoveredDevicesController.stream;

  List<LanDevice> get currentDiscoveredDevices {
    final uniqueDevices = <String, LanDevice>{};
    final sorted = _deviceMap.values.toList()
      ..sort((a, b) => b.lastSeen.compareTo(a.lastSeen));

    for (final device in sorted) {
      final cleanId = _extractCleanId(device.id);
      if (uniqueDevices.containsKey(cleanId)) {
        // Keep the one with the later lastSeen if already present
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

  /// Filter out virtual network interfaces (VPN/Docker/vEthernet)
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

  /// Get local IPv4 addresses mapped to their network interface names
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

  /// Start mDNS registration to announce this device to nearby peers
  Future<void> startAdvertising({int port = defaultPort}) async {
    _advertisedPort = port;
    await performStartAdvertising(port);
  }

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

  /// Stop mDNS registration
  Future<void> stopAdvertising() async {
    await performStopAdvertising();
    _advertisedPort = null;
  }

  @protected
  Future<void> performStopAdvertising() async {
    await sendUdpDisconnect();
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

  /// Start active discovery (mDNS + rate-limited UDP broadcast fallback)
  Future<void> startDiscovery() {
    if (_isScanning) return _discoveryLifecycle;
    _isScanning = true;
    final generation = ++_discoveryGeneration;
    _deviceMap.clear();
    _notifyDevicesUpdated();

    return _enqueueDiscoveryLifecycle(() => _performStartDiscovery(generation));
  }

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

  /// Stop active discovery to save battery and network bandwidth
  Future<void> stopDiscovery() {
    final generation = ++_discoveryGeneration;
    _isScanning = false;
    _cancelDiscoveryTimers();
    return _enqueueDiscoveryLifecycle(() => _performStopDiscovery(generation));
  }

  Future<void> _performStopDiscovery(int generation) async {
    // Cleanup is intentionally unconditional. A stale start may have created
    // resources after stopDiscovery() was requested.
    _cancelDiscoveryTimers();
    final discovery = _discovery;
    _discovery = null;
    if (discovery != null) {
      await _stopNsdDiscovery(discovery);
    }

    // Lifecycle operations are serialized, so a newer generation cannot
    // acquire this shared lock until the current stop has released it.
    await _releaseMulticastLock();
    if (generation == _discoveryGeneration || !_isScanning) {
      debugPrint('[LanDiscoveryService] Discovery stopped');
    }
  }

  Future<void> _stopNsdDiscovery(nsd.Discovery discovery) async {
    try {
      await performStopDiscovery(discovery);
    } catch (e) {
      debugPrint('[LanDiscoveryService] mDNS Stop Discovery error: $e');
    }
  }

  Future<void> _releaseMulticastLock() async {
    try {
      await multicastLock.release();
    } catch (e) {
      debugPrint('[LanDiscoveryService] Multicast unlock error: $e');
    }
  }

  void _cancelDiscoveryTimers() {
    _deviceCleanupTimer?.cancel();
    _deviceCleanupTimer = null;
    _udpBroadcastTimer?.cancel();
    _udpBroadcastTimer = null;
  }

  bool _isCurrentDiscoveryStart(int generation) =>
      _isScanning && generation == _discoveryGeneration;

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

  @protected
  Future<nsd.Discovery> performStartDiscovery() =>
      nsd.startDiscovery(serviceType);

  @protected
  Future<void> performStopDiscovery(nsd.Discovery discovery) =>
      nsd.stopDiscovery(discovery);

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

  void _notifyDevicesUpdated() {
    if (!_discoveredDevicesController.isClosed) {
      _discoveredDevicesController.add(currentDiscoveredDevices);
    }
  }

  void _startDeviceCleanup() {
    _deviceCleanupTimer?.cancel();
    _deviceCleanupTimer = Timer.periodic(
      _deviceCleanupInterval,
      (_) => removeStaleDevices(),
    );
  }

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

  /// UDP Listener for fallback ping packets
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

  void _stopUdpListener() {
    _udpSocket?.close();
    _udpSocket = null;
  }

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

  Future<void> sendUdpDisconnect() async {
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

  /// Fast 1s/scan for the first 30s. Auto-stop if no device found after 30s.
  void _startRateLimitedUdpBroadcast() {
    _udpBroadcastCount = 0;
    _udpBroadcastTimer?.cancel();
    _sendUdpPing();

    _scheduleNextUdpPing();
  }

  void _scheduleNextUdpPing() {
    if (!_isScanning) return;
    _udpBroadcastCount++;

    // Keep a low-rate scan alive so a peer that joins after hotspot/network
    // setup can still appear without requiring the user to restart discovery.
    final int delaySeconds = _udpBroadcastCount < 10 ? 1 : 5;

    _udpBroadcastTimer = Timer(Duration(seconds: delaySeconds), () {
      if (_isScanning) {
        _sendUdpPing();
        _scheduleNextUdpPing();
      }
    });
  }

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

  static String _calculateSubnetBroadcast(String ip) {
    final parts = ip.split('.');
    if (parts.length == 4) {
      return '${parts[0]}.${parts[1]}.${parts[2]}.255';
    }
    return '255.255.255.255';
  }

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

      // 1. Send to global broadcast address
      _udpSocket!.send(
        bytes,
        InternetAddress('255.255.255.255'),
        udpDiscoveryPort,
      );

      // 2. Send to all local subnet broadcast addresses (crucial for Hotspot AP mode)
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

        // 3. A periodic /24 unicast fallback helps hotspot implementations
        // that suppress broadcast. Do not repeat it every second.
        final shouldProbeSubnet =
            _udpBroadcastCount <= 1 || _udpBroadcastCount % 6 == 0;
        if (shouldProbeSubnet && _isPrivateIPv4(ip)) {
          final parts = ip.split('.');
          if (parts.length == 4) {
            final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';
            final selfHost = int.tryParse(parts[3]);
            for (int i = 1; i <= 254; i++) {
              if (i == selfHost) continue; // skip self
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

  /// Start Web Share Mode (serve clean Web UI for no-app browser transfers)
  Future<String?> startWebShareServer({
    int port = 53319,
    bool useHttps = false,
    required LanSecurityService securityService,
    required LanStorageService storageService,
    required LanTransferService transferService,
  }) {
    return _LanWebShareServerOperations(this)._startWebShareServer(
      port: port,
      useHttps: useHttps,
      securityService: securityService,
      storageService: storageService,
      transferService: transferService,
    );
  }

  /// Stop Web Share server
  Future<void> stopWebShareServer() =>
      _LanWebShareServerOperations(this)._stopWebShareServer();

  void registerManualDevice(LanDevice device) {
    _deviceMap[device.id] = device;
    _notifyDevicesUpdated();
  }

  void removeDevice(String deviceId) {
    _deviceMap.remove(deviceId);
    _deviceMap.removeWhere(
      (key, device) => _extractCleanId(device.id) == deviceId,
    );
    _notifyDevicesUpdated();
  }

  void dispose() {
    stopDiscovery();
    stopAdvertising();
    stopWebShareServer();
    _discoveredDevicesController.close();
  }
}
