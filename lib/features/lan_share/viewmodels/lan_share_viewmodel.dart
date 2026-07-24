import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../data/database/app_database.dart';
import '../../../core/services/data_protection_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/lan_share/lan_discovery_service.dart';
import '../../../services/lan_share/lan_security_service.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_transfer_protocol.dart';
import '../../../services/lan_share/lan_transfer_service.dart';

class LanShareViewModel extends ChangeNotifier {
  final LanDiscoveryService discoveryService;
  final LanSecurityService securityService;
  final LanStorageService storageService;
  final LanTransferService transferService;
  final LanHistoryDao historyDao;
  final AppSettings appSettings;
  final bool ownsRuntime;
  final ValueChanged<LanPairingRequest>? pairingRequestPublisher;

  List<LanDevice> _devices = [];
  List<LanMessage> _history = [];
  StreamSubscription? _devicesSubscription;
  StreamSubscription? _incomingMessageSubscription;
  StreamSubscription? _progressSubscription;
  StreamSubscription? _recallSubscription;
  StreamSubscription? _historyDbSubscription;
  StreamSubscription? _announcedDeviceSubscription;
  StreamSubscription? _pairingInviteSubscription;
  StreamSubscription? _handshakePendingSubscription;
  StreamSubscription? _handshakeSuccessSubscription;
  StreamSubscription? _connectionStateSubscription;
  Timer? _keepAliveTimer;
  Future<void> _historyRefreshSerial = Future<void>.value();
  final DataProtectionService _dataProtection = DataProtectionService.instance;
  final Map<String, Future<void>> _messagePersistence = {};

  /// Cache of X25519 public keys keyed by device ID (in-memory only).
  final Map<String, Uint8List> _recipientPubKeyCache = {};
  final Map<String, int> _recipientEncryptedFileLimit = {};
  final _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final Map<String, LanPairingRequest> _latestPairingRequests = {};

  Stream<LanPairingRequest> get pairingRequestStream =>
      _pairingRequestController.stream;

  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestPairingRequests[sessionId];
    if (request == null || request.isExpired) return null;
    return request;
  }

  void _publishPairingRequest(LanPairingRequest request) {
    _latestPairingRequests.removeWhere((_, value) => value.isExpired);
    _latestPairingRequests[request.sessionId] = request;
    _pairingRequestController.add(request);
    pairingRequestPublisher?.call(request);
  }

  bool _isInitialized = false;
  bool _disposed = false;
  int _lifecycleGeneration = 0;
  Future<void>? _initializationFuture;
  Future<void>? _shutdownFuture;

  LanShareViewModel({
    required this.discoveryService,
    required this.securityService,
    required this.storageService,
    required this.transferService,
    required this.historyDao,
    required this.appSettings,
    this.ownsRuntime = true,
    this.pairingRequestPublisher,
  });

  List<LanDevice> get devices => _devices;
  List<LanMessage> get history => _history;
  bool get isScanning => discoveryService.isScanning;
  bool get isWebShareActive => discoveryService.isWebShareActive;
  String? get webShareUrl => discoveryService.webShareUrl;

  Future<void> initialize() {
    if (_disposed) {
      return Future<void>.error(
        StateError('LAN share view model is disposed.'),
      );
    }
    return _initializationFuture ??= _initialize();
  }

  Future<void> _initialize() async {
    if (_isInitialized) return;
    final generation = _lifecycleGeneration;
    await appSettings.ensureLanIdentity();
    if (_disposed || generation != _lifecycleGeneration) return;
    if (appSettings.lanDeviceId.trim().isEmpty ||
        discoveryService.currentDeviceId.trim().isEmpty ||
        transferService.currentDeviceId.trim().isEmpty) {
      _initializationFuture = null;
      throw StateError(
        'LAN Quick Share cannot start without a stable device identity.',
      );
    }

    appSettings.addListener(_onSettingsChanged);

    // Subscribe before opening the listener so an invitation arriving during
    // HTTPS/mDNS startup cannot be acknowledged and then lost.
    _devicesSubscription = discoveryService.discoveredDevicesStream.listen((
      devs,
    ) {
      _devices = List.from(devs);
      if (!_disposed) notifyListeners();
    });
    _incomingMessageSubscription = transferService.incomingMessageStream.listen(
      (msg) async {
        await _enqueueMessagePersistence(msg.id, () => _saveMessageToDb(msg));
      },
    );
    _announcedDeviceSubscription = transferService.announcedDeviceStream.listen(
      (device) {
        registerManualDevice(device);
        _emitIncomingPairingRequest(device);
      },
    );
    _pairingInviteSubscription = transferService.pairingInviteStream.listen((
      request,
    ) {
      if (request.isExpired) return;
      registerManualDevice(request.device);
      _publishPairingRequest(request);
    });
    _handshakePendingSubscription = transferService.handshakePendingStream
        .listen((device) {
          registerManualDevice(device);
          _emitIncomingPairingRequest(device);
        });
    _handshakeSuccessSubscription = transferService.handshakeSuccessStream
        .listen((device) {
          registerManualDevice(device);
        });
    _progressSubscription = transferService.messageProgressStream.listen((
      msg,
    ) async {
      await _enqueueMessagePersistence(
        msg.id,
        () => historyDao.updateRecordStatus(
          msg.id,
          msg.status.toJson(),
          bytesTransferred: msg.bytesTransferred,
          localPath: msg.localPath,
        ),
      );
    });
    _recallSubscription = transferService.recalledMessageIdStream.listen((
      recall,
    ) async {
      final record = await historyDao.getRecord(recall.messageId);
      if (record == null ||
          !record.isIncoming ||
          record.senderId != recall.senderDeviceId) {
        return;
      }
      final localPath = record.localPath;
      if (localPath != null && localPath.isNotEmpty) {
        await storageService.deleteSandboxFile(localPath);
      }
      await _enqueueMessagePersistence(
        recall.messageId,
        () => historyDao.updateRecordStatus(
          recall.messageId,
          LanTransferStatus.recalled.toJson(),
          isRecalled: true,
        ),
      );
    });
    _historyDbSubscription = historyDao.watchAllRecords().listen((records) {
      _historyRefreshSerial = _historyRefreshSerial
          .then((_) => _refreshHistory(records))
          .catchError((error, stackTrace) {
            debugPrint('[LanShareViewModel] History refresh failed: $error');
          });
    });
    _connectionStateSubscription = transferService.connectionStateStream.listen(
      (_) {
        if (!_disposed) notifyListeners();
      },
    );

    try {
      if (securityService.activePin == null) {
        securityService.generate6DigitPin();
      }
      unawaited(storageService.perform7DayGarbageCollection());

      if (_disposed || generation != _lifecycleGeneration) return;
      if (ownsRuntime) {
        final boundPort = await transferService.startListening();
        if (_disposed || generation != _lifecycleGeneration) {
          await transferService.stopListening();
          return;
        }
        await discoveryService.startAdvertising(port: boundPort);
      }

      _isInitialized = true;
      _startKeepAliveTimer();
    } catch (_) {
      appSettings.removeListener(_onSettingsChanged);
      await _cancelRuntimeSubscriptions();
      _initializationFuture = null;
      rethrow;
    }
  }

  Future<void> _cancelRuntimeSubscriptions() async {
    final subscriptions = <StreamSubscription?>[
      _devicesSubscription,
      _incomingMessageSubscription,
      _progressSubscription,
      _recallSubscription,
      _historyDbSubscription,
      _announcedDeviceSubscription,
      _pairingInviteSubscription,
      _handshakePendingSubscription,
      _handshakeSuccessSubscription,
      _connectionStateSubscription,
    ];
    for (final subscription in subscriptions) {
      await subscription?.cancel();
    }
    _devicesSubscription = null;
    _incomingMessageSubscription = null;
    _progressSubscription = null;
    _recallSubscription = null;
    _historyDbSubscription = null;
    _announcedDeviceSubscription = null;
    _pairingInviteSubscription = null;
    _handshakePendingSubscription = null;
    _handshakeSuccessSubscription = null;
    _connectionStateSubscription = null;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
  }

  Future<void> startScanning() async {
    if (_disposed) return;
    await discoveryService.startDiscovery();
    if (!_disposed) notifyListeners();
  }

  Future<void> stopScanning() async {
    await discoveryService.stopDiscovery();
    if (!_disposed) notifyListeners();
  }

  bool _webShareUseHttps = false;
  bool get webShareUseHttps => _webShareUseHttps;

  void setWebShareUseHttps(bool value) {
    if (_webShareUseHttps == value) return;
    _webShareUseHttps = value;
    notifyListeners();
  }

  Future<void> toggleWebShare() async {
    if (isWebShareActive) {
      await discoveryService.stopWebShareServer();
    } else {
      await discoveryService.startWebShareServer(
        useHttps: _webShareUseHttps,
        securityService: securityService,
        storageService: storageService,
        transferService: transferService,
      );
    }
    notifyListeners();
  }

  Future<bool> sendText(
    LanDevice device,
    String text, {
    bool encrypted = false,
  }) async {
    final msg = LanMessage(
      id: const Uuid().v4(),
      senderId: discoveryService.currentDeviceId,
      senderAlias: discoveryService.currentDeviceAlias,
      receiverId: device.id,
      payloadType: LanPayloadType.text,
      textContent: text,
      status: LanTransferStatus.transferring,
      createdAt: DateTime.now(),
      isIncoming: false,
    );

    await _saveMessageToDb(msg);
    final pubKey = encrypted ? await _getRecipientPubKey(device) : null;
    if (encrypted && pubKey == null) {
      await historyDao.updateRecordStatus(
        msg.id,
        LanTransferStatus.failed.toJson(),
      );
      return false;
    }
    final success = await transferService.sendMeta(
      device,
      msg,
      recipientPubKeyBytes: pubKey,
    );

    await historyDao.updateRecordStatus(
      msg.id,
      success
          ? LanTransferStatus.completed.toJson()
          : LanTransferStatus.failed.toJson(),
    );
    return success;
  }

  Future<bool> sendClipboard(
    LanDevice device,
    String text, {
    bool encrypted = false,
  }) async {
    final msg = LanMessage(
      id: const Uuid().v4(),
      senderId: discoveryService.currentDeviceId,
      senderAlias: discoveryService.currentDeviceAlias,
      receiverId: device.id,
      payloadType: LanPayloadType.clipboard,
      textContent: text,
      status: LanTransferStatus.transferring,
      createdAt: DateTime.now(),
      isIncoming: false,
    );

    await _saveMessageToDb(msg);
    final pubKey = encrypted ? await _getRecipientPubKey(device) : null;
    if (encrypted && pubKey == null) {
      await historyDao.updateRecordStatus(
        msg.id,
        LanTransferStatus.failed.toJson(),
      );
      return false;
    }
    final success = await transferService.sendMeta(
      device,
      msg,
      recipientPubKeyBytes: pubKey,
    );

    await historyDao.updateRecordStatus(
      msg.id,
      success
          ? LanTransferStatus.completed.toJson()
          : LanTransferStatus.failed.toJson(),
    );
    return success;
  }

  Future<bool> sendFile(
    LanDevice device,
    String filePath, {
    bool encrypted = false,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) return false;

    final fileName = file.path.split(Platform.pathSeparator).last;
    final fileSize = await file.length();

    final msg = LanMessage(
      id: const Uuid().v4(),
      senderId: discoveryService.currentDeviceId,
      senderAlias: discoveryService.currentDeviceAlias,
      receiverId: device.id,
      payloadType: _guessPayloadType(fileName),
      fileName: fileName,
      fileSize: fileSize,
      localPath: filePath,
      status: LanTransferStatus.transferring,
      createdAt: DateTime.now(),
      isIncoming: false,
    );

    await _saveMessageToDb(msg);

    final pubKey = encrypted ? await _getRecipientPubKey(device) : null;
    if (encrypted && pubKey == null) {
      await historyDao.updateRecordStatus(
        msg.id,
        LanTransferStatus.failed.toJson(),
      );
      return false;
    }
    if (encrypted &&
        fileSize >
            (_recipientEncryptedFileLimit[device.id] ??
                LanTransferProtocolGuard.maxEncryptedUploadBytes)) {
      await historyDao.updateRecordStatus(
        msg.id,
        LanTransferStatus.failed.toJson(),
      );
      return false;
    }

    final accepted = await transferService.sendMeta(
      device,
      msg,
      recipientPubKeyBytes: pubKey,
    );
    if (!accepted) {
      await historyDao.updateRecordStatus(
        msg.id,
        LanTransferStatus.failed.toJson(),
      );
      return false;
    }

    final success = await transferService.sendFileStream(
      device: device,
      message: msg,
      fileStream: file.openRead(),
      totalBytes: fileSize,
      recipientPubKeyBytes: pubKey,
      onProgress: (bytesSent) {
        unawaited(
          _enqueueMessagePersistence(
            msg.id,
            () => historyDao.updateRecordStatus(
              msg.id,
              LanTransferStatus.transferring.toJson(),
              bytesTransferred: bytesSent,
            ),
          ),
        );
      },
    );

    await _enqueueMessagePersistence(
      msg.id,
      () => historyDao.updateRecordStatus(
        msg.id,
        success
            ? LanTransferStatus.completed.toJson()
            : LanTransferStatus.failed.toJson(),
        bytesTransferred: success ? fileSize : 0,
      ),
    );
    return success;
  }

  /// Query the remote device's E2E capabilities.
  /// Returns the recipient's X25519 public key bytes, or null if not supported.
  Future<Uint8List?> fetchRecipientE2ECapabilities(LanDevice device) async {
    if (_recipientPubKeyCache.containsKey(device.id)) {
      return _recipientPubKeyCache[device.id];
    }
    final client = await transferService.createHttpClientForPeer(device.id);
    try {
      final url = Uri.parse(
        'https://${device.ip}:${device.port}/api/lan/capabilities',
      );
      final req = await client.getUrl(url).timeout(const Duration(seconds: 3));
      if (!await transferService.addPairingAuthorization(
        req.headers,
        device.id,
      )) {
        return null;
      }
      final resp = await req.close().timeout(const Duration(seconds: 3));
      if (resp.statusCode != HttpStatus.ok) return null;
      final json = await transferService.readBoundedJsonResponse(resp);
      if (json['e2eEncryption'] != true) return null;
      final pubKeyB64 = json['x25519PubKey'] as String?;
      if (pubKeyB64 == null) return null;
      final pubKeyBytes = base64.decode(pubKeyB64);
      if (pubKeyBytes.length != 32) return null;
      final remoteLimit = (json['maxEncryptedFileBytes'] as num?)?.toInt();
      if (remoteLimit != null && remoteLimit > 0) {
        _recipientEncryptedFileLimit[device.id] = remoteLimit
            .clamp(1, LanTransferProtocolGuard.maxEncryptedUploadBytes)
            .toInt();
      }
      _recipientPubKeyCache[device.id] = Uint8List.fromList(pubKeyBytes);
      return _recipientPubKeyCache[device.id];
    } catch (e) {
      debugPrint('[LanShareViewModel] E2E capabilities query failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// Internal: get (and cache) recipient pub key; null if not supported.
  Future<Uint8List?> _getRecipientPubKey(LanDevice device) =>
      fetchRecipientE2ECapabilities(device);

  Future<void> recallMessage(LanMessage message, LanDevice? device) async {
    if (device != null) {
      await transferService.sendRecall(device, message.id);
    }
    if (message.isIncoming && message.localPath != null) {
      await storageService.deleteSandboxFile(message.localPath!);
    }
    await historyDao.updateRecordStatus(
      message.id,
      LanTransferStatus.recalled.toJson(),
      isRecalled: true,
    );
  }

  Future<void> clearHistory() async {
    await historyDao.clearAllRecords();
    notifyListeners();
  }

  Future<void> deleteMessage(String messageId) async {
    await historyDao.deleteRecord(messageId);
  }

  Future<void> forgetDevice(String deviceId) async {
    await securityService.unpairDevice(deviceId);
    if (!_disposed) notifyListeners();
  }

  Future<void> clearChatHistory(String targetDeviceId) async {
    final records = await historyDao.getAllRecords();
    for (final r in records) {
      final otherId = r.isIncoming ? r.senderId : r.receiverId;
      if (otherId == targetDeviceId) {
        if (r.localPath != null && r.localPath!.isNotEmpty) {
          await storageService.deleteSandboxFile(r.localPath!);
        }
        await historyDao.deleteRecord(r.id);
      }
    }
    notifyListeners();
  }

  LanPayloadType _guessPayloadType(String fileName) {
    final ext = fileName.split('.').last.toLowerCase();
    if (['jpg', 'jpeg', 'png', 'gif', 'webp', 'svg'].contains(ext)) {
      return LanPayloadType.image;
    }
    if (['mp4', 'mov', 'mkv', 'avi', 'webm'].contains(ext)) {
      return LanPayloadType.video;
    }
    if (['mp3', 'wav', 'm4a', 'flac', 'ogg'].contains(ext)) {
      return LanPayloadType.audio;
    }
    return LanPayloadType.file;
  }

  Future<String?> _encryptSensitive(String? value) {
    if (value == null) return Future<String?>.value();
    return _dataProtection.encryptString(value);
  }

  Future<String?> _decryptSensitive(String? value) async {
    if (value == null) return null;
    return _dataProtection.decryptString(value);
  }

  Future<void> _saveMessageToDb(LanMessage msg) async {
    await historyDao.insertRecord(
      LanTransferRecordsCompanion(
        id: Value(msg.id),
        senderId: Value(msg.senderId),
        senderAlias: Value(msg.senderAlias),
        receiverId: Value(msg.receiverId),
        payloadType: Value(msg.payloadType.toJson()),
        textContent: Value(await _encryptSensitive(msg.textContent)),
        fileName: Value(msg.fileName),
        fileSize: Value(msg.fileSize),
        localPath: Value(msg.localPath),
        manifestJson: Value(
          await _encryptSensitive(msg.manifest?.encodeJson()),
        ),
        status: Value(msg.status.toJson()),
        bytesTransferred: Value(msg.bytesTransferred),
        createdAt: Value(msg.createdAt.millisecondsSinceEpoch),
        isIncoming: Value(msg.isIncoming),
        isRecalled: Value(msg.isRecalled),
        sftpServerId: Value(msg.sftpServerId),
        sftpRemotePath: Value(await _encryptSensitive(msg.sftpRemotePath)),
      ),
    );
  }

  Future<void> _enqueueMessagePersistence(
    String messageId,
    Future<void> Function() operation,
  ) async {
    final previous = _messagePersistence[messageId] ?? Future<void>.value();
    late final Future<void> next;
    next = previous.then((_) => operation());
    _messagePersistence[messageId] = next;
    try {
      await next;
    } finally {
      if (identical(_messagePersistence[messageId], next)) {
        _messagePersistence.remove(messageId);
      }
    }
  }

  Future<LanMessage> _mapRecordToMessage(LanTransferRecord record) async {
    final textContent = await _decryptSensitive(record.textContent);
    final manifestJson = await _decryptSensitive(record.manifestJson);
    final sftpRemotePath = await _decryptSensitive(record.sftpRemotePath);
    if ((record.textContent != null &&
            !_dataProtection.isEncrypted(record.textContent!)) ||
        (record.manifestJson != null &&
            !_dataProtection.isEncrypted(record.manifestJson!)) ||
        (record.sftpRemotePath != null &&
            !_dataProtection.isEncrypted(record.sftpRemotePath!))) {
      unawaited(
        historyDao.updateSensitiveFields(
          record.id,
          textContent: Value(await _encryptSensitive(textContent)),
          manifestJson: Value(await _encryptSensitive(manifestJson)),
          sftpRemotePath: Value(await _encryptSensitive(sftpRemotePath)),
        ),
      );
    }
    return LanMessage(
      id: record.id,
      senderId: record.senderId,
      senderAlias: record.senderAlias,
      receiverId: record.receiverId,
      payloadType: LanPayloadType.fromJson(record.payloadType),
      textContent: textContent,
      fileName: record.fileName,
      fileSize: record.fileSize,
      localPath: record.localPath,
      manifest: manifestJson != null
          ? FileManifest.decodeJson(manifestJson)
          : null,
      status: LanTransferStatus.fromJson(record.status),
      bytesTransferred: record.bytesTransferred,
      createdAt: DateTime.fromMillisecondsSinceEpoch(record.createdAt),
      isIncoming: record.isIncoming,
      isRecalled: record.isRecalled,
      sftpServerId: record.sftpServerId,
      sftpRemotePath: sftpRemotePath,
    );
  }

  Future<void> _refreshHistory(List<LanTransferRecord> records) async {
    final mapped = await Future.wait(records.map(_mapRecordToMessage));
    if (_disposed) return;
    _history = mapped;
    notifyListeners();
  }

  Future<HandshakeResult> authenticateDevice(
    LanDevice device,
    String pin, {
    bool isInitiator = true,
  }) async {
    final result = await transferService.sendHandshake(
      device,
      pin,
      appSettings.lanDeviceAlias,
      isInitiator: isInitiator,
    );
    if (result.success && !result.pendingRemote) {
      await securityService.confirmDevicePairing(device.id);
      if (!_disposed) notifyListeners();
    }
    return result;
  }

  Future<bool> requestPairing(LanDevice device) async {
    final sessionId = const Uuid().v4();
    final expiresAt = DateTime.now().add(const Duration(minutes: 1));
    var result = await transferService.sendPairingInvite(
      device,
      appSettings.lanDeviceAlias,
      sessionId: sessionId,
      expiresAt: expiresAt,
    );
    if (!result.success) {
      result = await transferService.sendAnnouncement(
        device,
        appSettings.lanDeviceAlias,
      );
      if (!result.success) return false;
    }
    final remoteDeviceId = result.remoteDeviceId;
    final remotePort = result.remotePort;
    var resolvedDevice = device;
    if (remoteDeviceId != null &&
        remoteDeviceId.isNotEmpty &&
        (remoteDeviceId != device.id ||
            (remotePort != null && remotePort != device.port))) {
      resolvedDevice = device.copyWith(
        id: remoteDeviceId,
        port: remotePort,
        lastSeen: DateTime.now(),
      );
      discoveryService.removeDevice(device.id);
    }
    registerManualDevice(resolvedDevice);
    _publishPairingRequest(
      LanPairingRequest(
        device: resolvedDevice,
        sessionId: sessionId,
        isIncoming: false,
        expiresAt: expiresAt,
      ),
    );
    return true;
  }

  void _emitIncomingPairingRequest(LanDevice device) {
    _publishPairingRequest(
      LanPairingRequest(
        device: device,
        sessionId: const Uuid().v4(),
        isIncoming: true,
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      ),
    );
  }

  Future<bool> sendAnnouncement(LanDevice device) async {
    final result = await transferService.sendAnnouncement(
      device,
      appSettings.lanDeviceAlias,
    );
    return result.success;
  }

  Future<bool> isDevicePaired(String deviceId) async {
    String? ip;
    int? port;
    for (final d in _devices) {
      if (d.id == deviceId) {
        ip = d.ip;
        port = d.port;
        break;
      }
    }
    return securityService.isDevicePaired(
      deviceId,
      ip: ip,
      port: port,
      localDeviceId: appSettings.lanDeviceId,
    );
  }

  bool isDeviceConnected(String deviceId) {
    return transferService.isWebSocketConnected(deviceId);
  }

  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (!_isInitialized) return;
      for (final device in _devices) {
        final paired = await isDevicePaired(device.id);
        if (paired) {
          final isConnected = transferService.isWebSocketConnected(device.id);
          if (!isConnected) {
            unawaited(transferService.connectWebSocket(device));
          }
        }
      }
    });
  }

  void registerManualDevice(LanDevice device) {
    if (_disposed) return;
    discoveryService.registerManualDevice(device);
    notifyListeners();
  }

  String? get customIp => discoveryService.customIp;

  void setCustomIp(String? ip) {
    discoveryService.setCustomIp(ip);
    notifyListeners();
  }

  void _onSettingsChanged() {
    if (_disposed) return;
    unawaited(discoveryService.updateDeviceAlias(appSettings.lanDeviceAlias));
    notifyListeners();
  }

  Future<void> shutdown() {
    return _shutdownFuture ??= _shutdown();
  }

  Future<void> _shutdown() async {
    _lifecycleGeneration++;
    _isInitialized = false;
    appSettings.removeListener(_onSettingsChanged);
    await _cancelRuntimeSubscriptions();
    await stopScanning();
    if (ownsRuntime) {
      await discoveryService.stopAdvertising();
      await transferService.stopListening();
    }

    final initialization = _initializationFuture;
    if (initialization != null) {
      try {
        await initialization;
      } catch (_) {}
    }
    if (ownsRuntime) {
      // startListening can finish concurrently with the first stop above.
      await discoveryService.stopAdvertising();
      await transferService.closeConnections();
    }
    _devices = [];
    _initializationFuture = null;
    _shutdownFuture = null;
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _lifecycleGeneration++;
    unawaited(
      shutdown().whenComplete(() {
        if (ownsRuntime) {
          discoveryService.dispose();
          transferService.dispose();
        }
        _pairingRequestController.close();
      }),
    );
    super.dispose();
  }
}
