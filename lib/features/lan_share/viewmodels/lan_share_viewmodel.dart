// LAN Share ViewModel：负责 v1 类型化网络命令、事件和持久化传输历史。
// 网络事件处理位于独立 part 文件。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../../../data/database/app_database.dart';
import '../../../core/services/data_protection_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/app_log_service.dart';
import '../../../services/lan_share/lan_discovery_service.dart';
import '../../../services/lan_share/lan_network_models.dart';
import '../../../services/lan_share/lan_security_service.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_transfer_protocol.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import '../../../services/network/network_models.dart';

part 'lan_share_viewmodel_network.dart';
part 'lan_share_viewmodel_history.dart';

/// 功能范围内的 v1 LAN 状态、命令编排与历史记录外观。
class LanShareViewModel extends ChangeNotifier {
  final LanDiscoveryService discoveryService;
  final LanSecurityService securityService;
  final LanStorageService storageService;
  final LanTransferService transferService;
  final NetworkService? networkService;
  final LanHistoryDao historyDao;
  final AppSettings appSettings;
  final bool ownsRuntime;
  final ValueChanged<LanPairingRequest>? pairingRequestPublisher;

  List<LanDevice> _devices = [];
  List<LanMessage> _history = [];
  StreamSubscription? _devicesSubscription;
  StreamSubscription? _incomingMessageSubscription;
  StreamSubscription? _progressSubscription;
  StreamSubscription<NetworkEvent>? _networkProgressSubscription;
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

  /// 以设备标识为 key 的 X25519 公钥缓存（仅保存在内存）。
  final Map<String, Uint8List> _recipientPubKeyCache = {};
  final Map<String, Uint8List> _recipientNetworkIdentityKeyCache = {};
  final Map<String, int> _recipientEncryptedFileLimit = {};
  final _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final Map<String, LanPairingRequest> _latestPairingRequests = {};

  /// 发布当前 LAN UI 范围的配对请求。
  Stream<LanPairingRequest> get pairingRequestStream =>
      _pairingRequestController.stream;

  /// 返回 [sessionId] 对应的未过期配对请求。
  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestPairingRequests[sessionId];
    if (request == null || request.isExpired) return null;
    return request;
  }

  /// 向协调器和 UI 保存并发布一个配对请求。
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

  /// 基于功能拥有的 LAN 与历史服务创建 ViewModel。
  LanShareViewModel({
    required this.discoveryService,
    required this.securityService,
    required this.storageService,
    required this.transferService,
    this.networkService,
    required this.historyDao,
    required this.appSettings,
    this.ownsRuntime = true,
    this.pairingRequestPublisher,
  });

  /// 返回当前发现和手动注册的设备。
  List<LanDevice> get devices => _devices;

  /// 返回持久化 LAN 传输历史快照。
  List<LanMessage> get history => _history;

  /// LAN 发现是否处于活动状态。
  bool get isScanning => discoveryService.isScanning;

  /// WebShare 是否处于活动状态。
  bool get isWebShareActive => discoveryService.isWebShareActive;

  /// WebShare 活动时返回当前 URL。
  String? get webShareUrl => discoveryService.webShareUrl;

  /// 发布 ViewModel part 文件请求的状态变化。
  void _notifyHistoryChanged() => notifyListeners();

  /// 初始化订阅，并在拥有运行时的情况下初始化 LAN 运行时。
  Future<void> initialize() {
    if (_disposed) {
      return Future<void>.error(
        StateError('LAN share view model is disposed.'),
      );
    }
    return _initializationFuture ??= _initialize();
  }

  /// 执行一次性初始化流程。
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

    // 在打开监听器前先订阅，避免 HTTPS/mDNS 启动期间到达的邀请被确认后丢失。
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
          unawaited(_prepareFileTransferPeer(device));
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
    _networkProgressSubscription = networkService?.events.listen(
      _handleNetworkEvent,
    );
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
        final listenerResult = await transferService.startListening();
        if (listenerResult is NetworkFailure<int>) {
          AppLogService.instance.warning(
            'LAN listener failed',
            details: listenerResult.error.toString(),
          );
          return;
        }
        final boundPort = (listenerResult as NetworkSuccess<int>).data;
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

  /// 取消 ViewModel 持有的全部订阅和保活定时器。
  Future<void> _cancelRuntimeSubscriptions() async {
    final subscriptions = <StreamSubscription?>[
      _devicesSubscription,
      _incomingMessageSubscription,
      _progressSubscription,
      _networkProgressSubscription,
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
    _networkProgressSubscription = null;
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

  /// 启动 LAN 发现并刷新 UI 状态。
  Future<void> startScanning() async {
    if (_disposed) return;
    await discoveryService.startDiscovery();
    if (!_disposed) notifyListeners();
  }

  /// 停止 LAN 发现并刷新 UI 状态。
  Future<void> stopScanning() async {
    await discoveryService.stopDiscovery();
    if (!_disposed) notifyListeners();
  }

  bool _webShareUseHttps = false;

  /// WebShare 下次启动是否使用 HTTPS。
  bool get webShareUseHttps => _webShareUseHttps;

  /// 设置 WebShare HTTPS 偏好。
  void setWebShareUseHttps(bool value) {
    if (_webShareUseHttps == value) return;
    _webShareUseHttps = value;
    if (!_disposed) notifyListeners();
  }

  /// 根据当前偏好启动或停止 WebShare。
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
    if (!_disposed) notifyListeners();
  }

  /// 发送文本消息，并持久化稳定结果码。
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
    final result = await transferService.sendMeta(
      device,
      msg,
      recipientPubKeyBytes: pubKey,
    );
    final success = result is NetworkSuccess<void>;

    await historyDao.updateRecordStatus(
      msg.id,
      success
          ? LanTransferStatus.completed.toJson()
          : LanTransferStatus.failed.toJson(),
      failureReason: result is NetworkFailure<void>
          ? result.error.code.name
          : null,
    );
    return success;
  }

  /// 发送剪贴板内容，并持久化稳定结果码。
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
    final result = await transferService.sendMeta(
      device,
      msg,
      recipientPubKeyBytes: pubKey,
    );
    final success = result is NetworkSuccess<void>;

    await historyDao.updateRecordStatus(
      msg.id,
      success
          ? LanTransferStatus.completed.toJson()
          : LanTransferStatus.failed.toJson(),
      failureReason: result is NetworkFailure<void>
          ? result.error.code.name
          : null,
    );
    return success;
  }

  /// 注册原生文件传输，并在历史记录中跟踪终态事件。
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

    final network = networkService;
    if (network == null) {
      await historyDao.updateRecordStatus(
        msg.id,
        LanTransferStatus.failed.toJson(),
        failureReason: NetworkErrorCode.noRoute.name,
      );
      return false;
    }
    final recipientE2eKey =
        pubKey ?? await fetchRecipientE2ECapabilities(device);
    final identityKey = _recipientNetworkIdentityKeyCache[device.id];
    if (recipientE2eKey == null || identityKey == null) {
      await _enqueueMessagePersistence(
        msg.id,
        () => historyDao.updateRecordStatus(
          msg.id,
          LanTransferStatus.failed.toJson(),
          failureReason: NetworkErrorCode.authenticationFailed.name,
        ),
      );
      return false;
    }
    final endpoint = device.ip.contains(':')
        ? '[${device.ip}]:${device.port}'
        : '${device.ip}:${device.port}';
    final upsertResult = await network.upsertPeer(
      PeerConfig(
        peerId: device.id,
        endpointAddress: endpoint,
        identityPublicKey: identityKey,
        e2ePublicKey: recipientE2eKey,
      ),
    );
    if (upsertResult is NetworkFailure) {
      await _enqueueMessagePersistence(
        msg.id,
        () => historyDao.updateRecordStatus(
          msg.id,
          LanTransferStatus.failed.toJson(),
          failureReason: upsertResult.error.code.name,
        ),
      );
      return false;
    }
    final connectResult = await network.connect(device.id);
    if (connectResult is NetworkFailure) {
      await _enqueueMessagePersistence(
        msg.id,
        () => historyDao.updateRecordStatus(
          msg.id,
          LanTransferStatus.failed.toJson(),
          failureReason: connectResult.error.code.name,
        ),
      );
      return false;
    }
    final sendResult = await network.send(
      transferId: msg.id,
      peerId: device.id,
      filePath: file.absolute.path,
    );
    final sendFailure = sendResult is NetworkFailure<TransferSession>
        ? sendResult
        : null;
    if (sendFailure != null) {
      await _enqueueMessagePersistence(
        msg.id,
        () => historyDao.updateRecordStatus(
          msg.id,
          LanTransferStatus.failed.toJson(),
          failureReason: sendFailure.error.code.name,
        ),
      );
      return false;
    }
    await _enqueueMessagePersistence(
      msg.id,
      () => historyDao.updateRecordStatus(
        msg.id,
        LanTransferStatus.transferring.toJson(),
        bytesTotal: fileSize,
      ),
    );
    return true;
  }

  /// 查询并缓存远端设备的 E2E 和原生身份密钥。
  /// 返回接收方 X25519 公钥字节；不支持时返回 null。
  Future<Uint8List?> fetchRecipientE2ECapabilities(LanDevice device) async {
    if (_recipientPubKeyCache.containsKey(device.id)) {
      return _recipientPubKeyCache[device.id];
    }
    final pinnedE2eKey = await securityService.getPeerX25519PublicKey(
      device.id,
    );
    final pinnedIdentityKey = await securityService
        .getPeerNetworkIdentityPublicKey(device.id);
    if (pinnedE2eKey != null && pinnedIdentityKey != null) {
      _recipientPubKeyCache[device.id] = pinnedE2eKey;
      _recipientNetworkIdentityKeyCache[device.id] = pinnedIdentityKey;
      return pinnedE2eKey;
    }
    final client = await transferService.createHttpClientForPeer(device.id);
    try {
      final url = Uri.parse(
        'https://${device.ip}:${device.port}/api/lan/capabilities',
      );
      final req = await client.getUrl(url).timeout(const Duration(seconds: 3));
      final authorization = await transferService.addPairingAuthorization(
        req.headers,
        device.id,
      );
      if (authorization is NetworkFailure<void>) {
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
      final identityKeyValue = json['networkIdentityPubKey'] as String?;
      if (identityKeyValue != null && json['quicFileTransfer'] == true) {
        final identityKey = base64.decode(identityKeyValue);
        if (identityKey.length == 32) {
          _recipientNetworkIdentityKeyCache[device.id] = Uint8List.fromList(
            identityKey,
          );
        }
      }
      final remoteLimit = (json['maxEncryptedFileBytes'] as num?)?.toInt();
      if (remoteLimit != null && remoteLimit > 0) {
        _recipientEncryptedFileLimit[device.id] = remoteLimit
            .clamp(1, LanTransferProtocolGuard.maxEncryptedUploadBytes)
            .toInt();
      }
      _recipientPubKeyCache[device.id] = Uint8List.fromList(pubKeyBytes);
      if (await securityService.isDevicePaired(device.id)) {
        await securityService.storePeerX25519PublicKey(
          device.id,
          _recipientPubKeyCache[device.id]!,
        );
        final identityKey = _recipientNetworkIdentityKeyCache[device.id];
        if (identityKey != null) {
          await securityService.storePeerNetworkIdentityPublicKey(
            device.id,
            identityKey,
          );
        }
      }
      return _recipientPubKeyCache[device.id];
    } catch (e) {
      debugPrint('[LanShareViewModel] E2E capabilities query failed: $e');
      return null;
    } finally {
      client.close();
    }
  }

  /// 返回缓存中或刚查询得到的接收方 E2E 公钥。
  Future<Uint8List?> _getRecipientPubKey(LanDevice device) =>
      fetchRecipientE2ECapabilities(device);

  /// 为原生 QUIC 文件传输准备已配对对端。
  Future<void> _prepareFileTransferPeer(LanDevice device) async {
    final network = networkService;
    if (network == null) return;
    final e2eKey = await fetchRecipientE2ECapabilities(device);
    final identityKey = _recipientNetworkIdentityKeyCache[device.id];
    if (e2eKey == null || identityKey == null) return;
    final endpoint = device.ip.contains(':')
        ? '[${device.ip}]:${device.port}'
        : '${device.ip}:${device.port}';
    final upsert = await network.upsertPeer(
      PeerConfig(
        peerId: device.id,
        endpointAddress: endpoint,
        identityPublicKey: identityKey,
        e2ePublicKey: e2eKey,
      ),
    );
    if (upsert is NetworkFailure) {
      AppLogService.instance.warning(
        'Native peer preparation failed',
        details: upsert.error.toString(),
      );
      return;
    }
    final connect = await network.connect(device.id);
    if (connect is NetworkFailure) {
      AppLogService.instance.warning(
        'Native peer connection failed',
        details: connect.error.toString(),
      );
    }
  }

  /// 远端撤回消息，并将本地历史记录标记为已撤回。
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

  /// 清除全部 LAN 历史记录。
  Future<void> clearHistory() async {
    await historyDao.clearAllRecords();
    if (!_disposed) notifyListeners();
  }

  /// 删除一条 LAN 历史记录。
  Future<void> deleteMessage(String messageId) async {
    await historyDao.deleteRecord(messageId);
  }

  /// 解除设备配对，并清除其内存密钥缓存。
  Future<void> forgetDevice(String deviceId) async {
    await securityService.unpairDevice(deviceId);
    _recipientPubKeyCache.remove(deviceId);
    _recipientNetworkIdentityKeyCache.remove(deviceId);
    _recipientEncryptedFileLimit.remove(deviceId);
    if (!_disposed) notifyListeners();
  }

  /// 删除一个对端关联的全部历史和文件。
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
    if (!_disposed) notifyListeners();
  }

  /// 执行 v1 配对认证，并确认已完成的配对。
  Future<NetworkResult<LanHandshakeData>> authenticateDevice(
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
    if (result is NetworkSuccess<LanHandshakeData> &&
        !result.data.pendingRemote) {
      await securityService.confirmDevicePairing(device.id);
      if (!_disposed) notifyListeners();
    }
    return result;
  }

  /// 请求配对，并发布生成的 UI 会话。
  Future<bool> requestPairing(LanDevice device) async {
    final sessionId = const Uuid().v4();
    final expiresAt = DateTime.now().add(const Duration(minutes: 1));
    NetworkResult<LanPairingEndpoint> result = await transferService
        .sendPairingInvite(
          device,
          appSettings.lanDeviceAlias,
          sessionId: sessionId,
          expiresAt: expiresAt,
        );
    if (result is NetworkFailure<LanPairingEndpoint>) {
      result = await transferService.sendAnnouncement(
        device,
        appSettings.lanDeviceAlias,
      );
      if (result is NetworkFailure<LanPairingEndpoint>) return false;
    }
    final endpoint = (result as NetworkSuccess<LanPairingEndpoint>).data;
    final remoteDeviceId = endpoint.remoteDeviceId;
    final remotePort = endpoint.remotePort;
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

  /// 为 [device] 发布传入配对请求。
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

  /// 向远端 LAN 对端广播本设备。
  Future<bool> sendAnnouncement(LanDevice device) async {
    final result = await transferService.sendAnnouncement(
      device,
      appSettings.lanDeviceAlias,
    );
    return result is NetworkSuccess<LanPairingEndpoint>;
  }

  /// 检查 [deviceId] 是否有有效的已存储配对。
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

  /// 返回已配对对端是否拥有活跃 WebSocket。
  bool isDeviceConnected(String deviceId) {
    return transferService.isWebSocketConnected(deviceId);
  }

  /// 启动已配对 LAN 对端的周期性重连检查。
  void _startKeepAliveTimer() {
    _keepAliveTimer?.cancel();
    _keepAliveTimer = Timer.periodic(const Duration(seconds: 5), (timer) async {
      if (_disposed || !_isInitialized) return;
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

  /// 注册手动解析的对端并刷新监听器。
  void registerManualDevice(LanDevice device) {
    if (_disposed) return;
    discoveryService.registerManualDevice(device);
    notifyListeners();
  }

  /// 返回可选的 WebShare IP 覆盖值。
  String? get customIp => discoveryService.customIp;

  /// 设置可选的 WebShare IP 覆盖值。
  void setCustomIp(String? ip) {
    discoveryService.setCustomIp(ip);
    if (!_disposed) notifyListeners();
  }

  /// 将变更后的应用设置应用到活动发现服务。
  void _onSettingsChanged() {
    if (_disposed) return;
    unawaited(discoveryService.updateDeviceAlias(appSettings.lanDeviceAlias));
    notifyListeners();
  }

  /// 关闭 ViewModel 持有的资源，且只执行一次。
  Future<void> shutdown() {
    return _shutdownFuture ??= _shutdown();
  }

  /// 执行串行化的 ViewModel 关闭流程。
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
      // startListening 可能与上面的第一次 stop 并发完成。
      await discoveryService.stopAdvertising();
      await transferService.closeConnections();
    }
    _devices = [];
    _initializationFuture = null;
    _shutdownFuture = null;
    if (!_disposed) notifyListeners();
  }

  /// 销毁 ViewModel，并安排其拥有的运行时清理。
  @override
  void dispose() {
    _disposed = true;
    _lifecycleGeneration++;
    _keepAliveTimer?.cancel();
    _keepAliveTimer = null;
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
