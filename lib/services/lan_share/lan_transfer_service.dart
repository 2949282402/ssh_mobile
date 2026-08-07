// v1 LAN HTTPS、WebSocket、配对与消息传输服务。
//
// 服务向调用方暴露类型化网络结果，同时将端点专属 HTTP 实现限制在本库内。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import 'lan_security_service.dart';
import 'lan_network_models.dart';
import 'lan_pairing_crypto.dart';
import 'lan_share_models.dart';
import 'lan_storage_service.dart';
import 'lan_transfer_protocol.dart';
import '../network/network_models.dart';

part 'lan_transfer_client.dart';
part 'lan_pairing_server.dart';

/// 管理 v1 HTTPS 上传、元数据、WebSocket 与 RECALL 信号的服务。
class LanTransferService {
  static const int defaultHttpPort = 53317;

  /// 主端口被占用时按顺序尝试的备用端口。
  static const List<int> httpPortCandidates = [
    53317,
    53320,
    53325,
    53330,
    53335,
  ];
  static const int chunkSize = 512 * 1024; // 512 KB 流式缓冲区。

  final String currentDeviceId;
  final LanSecurityService securityService;
  final LanStorageService storageService;
  final Future<Uint8List> Function()? networkIdentityPublicKeyProvider;
  late final LanTransferProtocolGuard _protocolGuard;

  HttpServer? _server;
  bool _isListening = false;

  /// LAN HTTPS 监听器当前是否已绑定。
  bool get isListening => _isListening;

  final Map<String, WebSocket> _activeWebSockets = {};
  final Set<String> _connectingDeviceIds = {};
  final Map<String, _PendingPairingHandshake> _pendingPairingHandshakes = {};
  final _connectionStateController =
      StreamController<LanConnectionStateChanged>.broadcast();

  /// 发布类型化 WebSocket 连接变化。
  Stream<LanConnectionStateChanged> get connectionStateStream =>
      _connectionStateController.stream;

  final _incomingMessageController = StreamController<LanMessage>.broadcast();
  final _messageProgressController = StreamController<LanMessage>.broadcast();
  final _recalledMessageIdController =
      StreamController<LanRecallRequest>.broadcast();
  final _handshakeSuccessController = StreamController<LanDevice>.broadcast();
  final _handshakePendingController = StreamController<LanDevice>.broadcast();
  final _announcedDeviceController = StreamController<LanDevice>.broadcast();
  final _pairingInviteController =
      StreamController<LanPairingRequest>.broadcast();

  /// 使用安全与存储依赖创建 LAN 传输服务。
  LanTransferService({
    required this.currentDeviceId,
    required this.securityService,
    required this.storageService,
    this.networkIdentityPublicKeyProvider,
  }) {
    _protocolGuard = LanTransferProtocolGuard(
      currentDeviceId: currentDeviceId,
      securityService: securityService,
    );
  }

  /// 发布收到的元数据和传输消息。
  Stream<LanMessage> get incomingMessageStream =>
      _incomingMessageController.stream;

  /// 发布收到的传输进度消息。
  Stream<LanMessage> get messageProgressStream =>
      _messageProgressController.stream;

  /// 发布已配对对端发来的撤回请求。
  Stream<LanRecallRequest> get recalledMessageIdStream =>
      _recalledMessageIdController.stream;

  /// 发布握手成功的传入设备。
  Stream<LanDevice> get handshakeSuccessStream =>
      _handshakeSuccessController.stream;

  /// 发布仍需完成相互配对的传入握手。
  Stream<LanDevice> get handshakePendingStream =>
      _handshakePendingController.stream;

  /// 发布在 LAN 上广播的设备。
  Stream<LanDevice> get announcedDeviceStream =>
      _announcedDeviceController.stream;

  /// 发布收到的配对邀请。
  Stream<LanPairingRequest> get pairingInviteStream =>
      _pairingInviteController.stream;

  /// 返回已绑定监听端口；绑定前返回默认端口。
  int get activePort => _server?.port ?? defaultHttpPort;

  /// 启动接收 LAN 传输的 HTTPS 服务。
  /// 按 [httpPortCandidates] 顺序尝试，直到一个端口绑定成功。
  Future<NetworkResult<int>> startListening({
    int port = defaultHttpPort,
  }) async {
    if (_isListening) return NetworkSuccess(_server!.port);
    try {
      return NetworkSuccess(await _bindListeningServer(port: port));
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(error, operation: NetworkOperation.startLanListener),
      );
    }
  }

  /// 在 [startListening] 完成生命周期校验后绑定 HTTPS 监听器。
  Future<int> _bindListeningServer({required int port}) async {
    final securityContext = await securityService.getOrCreateSecurityContext(
      currentDeviceId,
    );
    final candidates = [port, ...httpPortCandidates.where((p) => p != port)];

    for (final candidate in candidates) {
      try {
        _server = await HttpServer.bindSecure(
          InternetAddress.anyIPv4,
          candidate,
          securityContext,
          requestClientCertificate: false,
        );
        _isListening = true;
        _server!.listen(handleHttpRequest);
        debugPrint(
          '[LanTransferService] HTTPS server listening on port ${_server!.port}',
        );
        return _server!.port;
      } catch (error) {
        debugPrint(
          '[LanTransferService] HTTPS port $candidate unavailable: $error',
        );
      }
    }

    _server = await HttpServer.bindSecure(
      InternetAddress.anyIPv4,
      0,
      securityContext,
      requestClientCertificate: false,
    );
    _isListening = true;
    _server!.listen(handleHttpRequest);
    debugPrint(
      '[LanTransferService] HTTPS server listening on ephemeral port ${_server!.port}',
    );
    return _server!.port;
  }

  /// 停止 HTTPS 监听器并返回类型化 v1 结果。
  Future<NetworkResult<void>> stopListening() async {
    try {
      if (_server != null) {
        await _server!.close(force: true);
        _server = null;
      }
      _isListening = false;
      _pendingPairingHandshakes.clear();
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(error, operation: NetworkOperation.stopLanListener),
      );
    }
  }

  /// 关闭所有活跃的 LAN WebSocket 连接。
  Future<NetworkResult<void>> closeConnections() async {
    try {
      for (final ws in _activeWebSockets.values.toList()) {
        try {
          await ws.close();
        } catch (_) {}
      }
      _activeWebSockets.clear();
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(error, operation: NetworkOperation.closeLanConnections),
      );
    }
  }

  /// 路由一个传入 LAN HTTP 请求，并写入规范化安全响应。
  void handleHttpRequest(HttpRequest request) async {
    final path = request.uri.path;
    try {
      if (request.method == 'POST' && path == '/api/lan/handshake') {
        await _handleSecureHandshakeRequest(request);
      } else if (request.method == 'GET' && path == '/api/lan/ws') {
        await _handleWebSocketUpgrade(request);
      } else if (request.method == 'GET' && path == '/api/lan/check_pair') {
        await _handleCheckPairRequest(request);
      } else if (request.method == 'POST' && path == '/api/lan/announce') {
        await _handleAnnounceRequest(request);
      } else if (request.method == 'POST' &&
          path == '/api/lan/pairing_invite') {
        await _handlePairingInviteRequest(request);
      } else if (request.method == 'GET' && path == '/api/lan/capabilities') {
        await _handleCapabilitiesRequest(request);
      } else if (request.method == 'POST' && path == '/api/lan/meta') {
        await _handleMetaRequest(request);
      } else if (request.method == 'POST' && path == '/api/lan/upload') {
        await _handleUploadRequest(request);
      } else if (request.method == 'POST' && path == '/api/lan/recall') {
        await _handleRecallRequest(request);
      } else {
        throw const LanHttpException(
          HttpStatus.notFound,
          'LAN endpoint not found.',
        );
      }
    } on LanHttpException catch (error) {
      try {
        request.response.statusCode = error.statusCode;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'code': _httpErrorCode(error.statusCode).wireValue,
            'message': error.message,
            'operation': _operationForPath(path),
            if (request.headers.value('x-device-id') case final peerId?
                when peerId.isNotEmpty)
              'peer_id': peerId,
          }),
        );
        await request.response.close();
      } catch (_) {}
    } catch (error, stackTrace) {
      debugPrint(
        '[LanTransferService] Error handling request $path: $error\n$stackTrace',
      );
      try {
        request.response.statusCode = HttpStatus.internalServerError;
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'code': NetworkErrorCode.ioError.wireValue,
            'message': 'LAN request failed.',
            'operation': _operationForPath(path),
            if (request.headers.value('x-device-id') case final peerId?
                when peerId.isNotEmpty)
              'peer_id': peerId,
          }),
        );
        await request.response.close();
      } catch (_) {}
    }
  }

  /// 将 HTTP 状态映射为稳定的 v1 LAN 错误码。
  NetworkErrorCode _httpErrorCode(int statusCode) {
    if (statusCode == HttpStatus.badRequest ||
        statusCode == HttpStatus.requestEntityTooLarge) {
      return NetworkErrorCode.invalidArgument;
    }
    if (statusCode == HttpStatus.unauthorized ||
        statusCode == HttpStatus.forbidden ||
        statusCode == HttpStatus.upgradeRequired) {
      return NetworkErrorCode.authenticationFailed;
    }
    if (statusCode == HttpStatus.requestTimeout ||
        statusCode == HttpStatus.gatewayTimeout) {
      return NetworkErrorCode.timeout;
    }
    if (statusCode == HttpStatus.notFound) {
      return NetworkErrorCode.noRoute;
    }
    return NetworkErrorCode.ioError;
  }

  /// 返回 HTTP 端点路径对应的稳定操作名称。
  String _operationForPath(String path) {
    return switch (path) {
      '/api/lan/handshake' => 'send_handshake',
      '/api/lan/ws' => 'connect_websocket',
      '/api/lan/check_pair' => 'check_pair',
      '/api/lan/announce' => 'send_announcement',
      '/api/lan/pairing_invite' => 'send_pairing_invite',
      '/api/lan/capabilities' => 'read_capabilities',
      '/api/lan/meta' => 'send_meta',
      '/api/lan/upload' => 'send_file',
      '/api/lan/recall' => 'send_recall',
      _ => 'lan_request',
    };
  }

  /// 提供端点专属的原生能力数据。
  Future<void> _handleCapabilitiesRequest(HttpRequest request) async {
    await _protocolGuard.authorize(request);
    final pubKeyBytes = await securityService.getStaticX25519PublicKeyBytes();
    final networkIdentityKey = await networkIdentityPublicKeyProvider?.call();
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({
        'e2eEncryption': LanSecurityService.supportsE2EEncryption,
        'x25519PubKey': base64.encode(pubKeyBytes),
        if (networkIdentityKey != null)
          'networkIdentityPubKey': base64.encode(networkIdentityKey),
        if (networkIdentityKey != null) 'quicFileTransfer': true,
        if (networkIdentityKey != null) 'quicPort': activePort,
        'maxEncryptedFileBytes':
            LanTransferProtocolGuard.maxEncryptedUploadBytes,
      }),
    );
    await request.response.close();
  }

  /// 确认已认证调用方正在检查自身配对状态。
  Future<void> _handleCheckPairRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final requestedDeviceId = request.uri.queryParameters['deviceId'] ?? '';
    if (requestedDeviceId != senderDeviceId) {
      throw const LanHttpException(
        HttpStatus.forbidden,
        'Pairing identity does not match.',
      );
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'paired': true}));
    await request.response.close();
  }

  /// 认证 LAN 请求并将其升级为 WebSocket。
  Future<void> _handleWebSocketUpgrade(HttpRequest request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'LAN WebSocket upgrade is required.',
      );
    }

    final deviceId = await _protocolGuard.authorize(request);
    if (request.uri.queryParameters['deviceId'] != deviceId) {
      throw const LanHttpException(
        HttpStatus.forbidden,
        'Pairing identity does not match.',
      );
    }

    try {
      final socket = await WebSocketTransformer.upgrade(request);
      _registerActiveWebSocket(deviceId, socket);
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.internalServerError,
        'LAN WebSocket upgrade failed.',
      );
    }
  }

  /// 连接一个已配对 LAN 对端，只返回命令层状态。
  Future<NetworkResult<void>> connectWebSocket(LanDevice device) async {
    if (_activeWebSockets.containsKey(device.id)) {
      return const NetworkSuccess<void>(null);
    }
    if (_connectingDeviceIds.contains(device.id)) {
      return NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.peerOffline,
          message: 'LAN peer connection is already in progress.',
          operation: NetworkOperation.connectWebSocket,
          peerId: device.id,
        ),
      );
    }

    _connectingDeviceIds.add(device.id);
    final url = Uri.parse(
      'wss://${device.ip}:${device.port}/api/lan/ws?deviceId=$currentDeviceId',
    );

    try {
      final token = await securityService.getOutboundAccessToken(device.id);
      if (token == null || token.isEmpty) {
        return NetworkFailure(
          NetworkError(
            code: NetworkErrorCode.authenticationFailed,
            message: 'LAN pairing credentials are unavailable.',
            operation: NetworkOperation.connectWebSocket,
            peerId: device.id,
          ),
        );
      }
      final client = await _createHttpClient(peerDeviceId: device.id);
      final socket = await WebSocket.connect(
        url.toString(),
        headers: {
          'x-device-id': currentDeviceId,
          HttpHeaders.authorizationHeader: 'Bearer $token',
        },
        customClient: client,
      ).timeout(const Duration(seconds: 4));
      _registerActiveWebSocket(device.id, socket);
      return const NetworkSuccess<void>(null);
    } catch (error) {
      return NetworkFailure(
        lanNetworkError(
          error,
          operation: NetworkOperation.connectWebSocket,
          peerId: device.id,
        ),
      );
    } finally {
      _connectingDeviceIds.remove(device.id);
    }
  }

  /// 返回 [deviceId] 是否注册了活跃 WebSocket。
  bool isWebSocketConnected(String deviceId) {
    return _activeWebSockets.containsKey(deviceId);
  }

  /// 注册 socket，并发布类型化的已连接事件。
  void _registerActiveWebSocket(String deviceId, WebSocket socket) {
    socket.pingInterval = const Duration(seconds: 5);
    final previousSocket = _activeWebSockets[deviceId];
    _activeWebSockets[deviceId] = socket;
    if (previousSocket != null && !identical(previousSocket, socket)) {
      unawaited(previousSocket.close());
    }

    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(
        LanConnectionStateChanged(deviceId: deviceId, connected: true),
      );
    }

    socket.listen(
      (data) {},
      onError: (e) {
        debugPrint('[LanTransferService] WebSocket error for $deviceId: $e');
        _unregisterActiveWebSocket(deviceId, socket);
      },
      onDone: () {
        debugPrint('[LanTransferService] WebSocket disconnected for $deviceId');
        _unregisterActiveWebSocket(deviceId, socket);
      },
      cancelOnError: true,
    );
  }

  /// 仅当 socket 仍是该对端的活跃 socket 时移除它。
  void _unregisterActiveWebSocket(String deviceId, WebSocket socket) {
    if (!identical(_activeWebSockets[deviceId], socket)) return;
    _activeWebSockets.remove(deviceId);
    unawaited(socket.close());
    if (!_connectionStateController.isClosed) {
      _connectionStateController.add(
        LanConnectionStateChanged(deviceId: deviceId, connected: false),
      );
    }
  }

  /// 为生命周期测试注册可控 socket。
  @visibleForTesting
  void registerActiveWebSocketForTesting(String deviceId, WebSocket socket) {
    _registerActiveWebSocket(deviceId, socket);
  }

  /// 校验并记录对端广播。
  Future<void> _handleAnnounceRequest(HttpRequest request) async {
    final json = await _protocolGuard.readJson(request);

    final senderId = json['id'] is String ? (json['id'] as String).trim() : '';
    final alias = json['alias'] is String
        ? (json['alias'] as String).trim()
        : '';
    final os = json['os'] is String ? (json['os'] as String).trim() : '';
    var hostIp = request.connectionInfo?.remoteAddress.address ?? '';
    if (hostIp.startsWith('::ffff:')) {
      hostIp = hostIp.substring(7);
    }
    final port = (json['port'] as num?)?.toInt() ?? defaultHttpPort;

    if (senderId.isEmpty ||
        senderId == currentDeviceId ||
        senderId.length > 128 ||
        alias.isEmpty ||
        alias.length > 128 ||
        os.isEmpty ||
        os.length > 64 ||
        hostIp.isEmpty ||
        port < 1 ||
        port > 65535) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid device announcement.',
      );
    }
    _protocolGuard.checkPairingInviteRate(hostIp);
    {
      final device = LanDevice(
        id: senderId,
        alias: alias,
        ip: hostIp,
        port: port,
        deviceType: _guessDeviceType(os),
        osName: os,
        lastSeen: DateTime.now(),
      );
      _announcedDeviceController.add(device);
    }

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'deviceId': currentDeviceId, 'port': activePort}),
    );
    await request.response.close();
  }

  /// 校验并记录传入配对邀请。
  Future<void> _handlePairingInviteRequest(HttpRequest request) async {
    final json = await _protocolGuard.readJson(request);
    final senderId = json['deviceId'] is String
        ? (json['deviceId'] as String).trim()
        : '';
    final sessionId = json['sessionId'] is String
        ? (json['sessionId'] as String).trim()
        : '';
    final validForMs = (json['validForMs'] as num?)?.toInt() ?? 0;
    final alias = json['alias'] is String
        ? (json['alias'] as String).trim()
        : '';
    final os = json['os'] is String ? (json['os'] as String).trim() : '';
    final port = (json['port'] as num?)?.toInt() ?? defaultHttpPort;
    if (senderId.isEmpty ||
        senderId == currentDeviceId ||
        senderId.length > 128 ||
        sessionId.isEmpty ||
        sessionId.length > 128 ||
        alias.isEmpty ||
        alias.length > 128 ||
        os.isEmpty ||
        os.length > 64 ||
        port < 1 ||
        port > 65535 ||
        validForMs <= 0 ||
        validForMs > const Duration(minutes: 2).inMilliseconds) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid pairing invitation.',
      );
    }
    final expiresAt = DateTime.now().add(Duration(milliseconds: validForMs));
    var hostIp = request.connectionInfo?.remoteAddress.address ?? '';
    if (hostIp.startsWith('::ffff:')) {
      hostIp = hostIp.substring(7);
    }
    if (hostIp.isEmpty) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Pairing invitation has no source address.',
      );
    }
    _protocolGuard.checkPairingInviteRate(hostIp);
    final device = LanDevice(
      id: senderId,
      alias: alias,
      ip: hostIp,
      port: port,
      deviceType: _guessDeviceType(os),
      osName: os,
      lastSeen: DateTime.now(),
    );
    _pairingInviteController.add(
      LanPairingRequest(
        device: device,
        sessionId: sessionId,
        isIncoming: true,
        expiresAt: expiresAt,
      ),
    );
    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(
      jsonEncode({'deviceId': currentDeviceId, 'port': activePort}),
    );
    await request.response.close();
  }

  /// 将对端操作系统标签映射为功能使用的设备类别。
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

  /// 校验元数据，按需执行 E2E 解密，并注册文件。
  Future<void> _handleMetaRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final e2ePubKeyHeader = request.headers.value('x-e2e-pubkey');
    final isEncrypted = e2ePubKeyHeader == '1';
    Map<String, dynamic> json;
    if (isEncrypted) {
      final blob = await _protocolGuard.readBytes(
        request,
        maxBytes: LanTransferProtocolGuard.maxMetadataBodyBytes + 60,
      );
      try {
        final plainBytes = await securityService.decryptE2E(blob);
        if (plainBytes.length > LanTransferProtocolGuard.maxMetadataBodyBytes) {
          throw const LanHttpException(
            HttpStatus.requestEntityTooLarge,
            'Metadata is too large.',
          );
        }
        final decoded = jsonDecode(utf8.decode(plainBytes));
        if (decoded is! Map<String, dynamic>) {
          throw const FormatException('Expected a JSON object.');
        }
        json = decoded;
      } on LanHttpException {
        rethrow;
      } catch (_) {
        throw const LanHttpException(
          HttpStatus.badRequest,
          'Encrypted metadata is invalid.',
        );
      }
    } else {
      json = await _protocolGuard.readJson(
        request,
        maxBytes: LanTransferProtocolGuard.maxMetadataBodyBytes,
      );
    }

    final payloadName = json['payloadType'];
    final validPayload =
        payloadName is String &&
        LanPayloadType.values.any((value) => value.name == payloadName);
    if (!validPayload) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Unsupported LAN payload type.',
      );
    }

    late final LanMessage decodedMessage;
    try {
      decodedMessage = LanMessage.fromJson({
        ...json,
        'localPath': null,
        'isIncoming': true,
        'isRecalled': false,
      });
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN message metadata.',
      );
    }
    final isFilePayload =
        decodedMessage.payloadType != LanPayloadType.text &&
        decodedMessage.payloadType != LanPayloadType.clipboard;
    final fileName = decodedMessage.fileName?.trim() ?? '';
    if (decodedMessage.id.isEmpty ||
        decodedMessage.id.length > 128 ||
        decodedMessage.senderId != senderDeviceId ||
        decodedMessage.receiverId != currentDeviceId ||
        decodedMessage.senderAlias.isEmpty ||
        decodedMessage.senderAlias.length > 128 ||
        decodedMessage.fileSize < 0 ||
        decodedMessage.fileSize >
            LanTransferProtocolGuard.maxAdvertisedFileBytes ||
        (decodedMessage.textContent?.length ?? 0) > 512 * 1024 ||
        (isFilePayload &&
            (fileName.isEmpty ||
                fileName == '.' ||
                fileName == '..' ||
                fileName.length > 255 ||
                fileName.contains('/') ||
                fileName.contains('\\')))) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid LAN message metadata.',
      );
    }

    final message = LanMessage(
      id: decodedMessage.id,
      senderId: senderDeviceId,
      senderAlias: decodedMessage.senderAlias,
      receiverId: currentDeviceId,
      payloadType: decodedMessage.payloadType,
      textContent: decodedMessage.textContent,
      fileName: isFilePayload ? fileName : null,
      fileSize: isFilePayload ? decodedMessage.fileSize : 0,
      manifest: decodedMessage.manifest,
      status: isFilePayload
          ? LanTransferStatus.pending
          : LanTransferStatus.completed,
      bytesTransferred: 0,
      createdAt: DateTime.now(),
      isIncoming: true,
    );

    // 预先检查磁盘空间。
    final hasSpace =
        !isFilePayload ||
        await storageService.hasSufficientSpace(message.fileSize);
    if (!hasSpace) {
      throw const LanHttpException(
        HttpStatus.insufficientStorage,
        'Insufficient LAN storage.',
      );
    }

    if (isFilePayload) {
      _protocolGuard.registerPendingUpload(
        LanPendingUpload(
          messageId: message.id,
          senderDeviceId: senderDeviceId,
          fileName: fileName,
          expectedBytes: message.fileSize,
          encrypted: isEncrypted,
          expiresAt: DateTime.now().add(const Duration(minutes: 2)),
        ),
      );
    }

    _incomingMessageController.add(message);

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'id': message.id}));
    await request.response.close();
  }

  /// 流式接收或解密一个已接受的文件上传，失败时清理临时数据。
  Future<void> _handleUploadRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final messageId = request.headers.value('x-message-id') ?? '';
    final encodedFileName = request.headers.value('x-file-name') ?? '';
    late final String fileName;
    try {
      fileName = Uri.decodeComponent(encodedFileName);
    } catch (_) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid upload file name.',
      );
    }
    final isEncrypted = request.headers.value('x-e2e-pubkey') == '1';
    final pending = _protocolGuard.requirePendingUpload(
      messageId: messageId,
      senderDeviceId: senderDeviceId,
      fileName: fileName,
      encrypted: isEncrypted,
    );
    if (!isEncrypted &&
        request.contentLength >= 0 &&
        request.contentLength != pending.expectedBytes) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Upload size does not match accepted metadata.',
      );
    }

    File? targetFile;
    var bytesReceived = 0;
    var completed = false;
    try {
      final file = await storageService.getSandboxTargetFile(fileName);
      targetFile = file;
      if (isEncrypted) {
        final blob = await _protocolGuard.readBytes(
          request,
          maxBytes: pending.expectedBytes + 60,
        );
        final plainBytes = await securityService.decryptE2E(blob);
        if (plainBytes.length != pending.expectedBytes) {
          throw const LanHttpException(
            HttpStatus.badRequest,
            'Decrypted upload size does not match accepted metadata.',
          );
        }
        bytesReceived = plainBytes.length;
        await file.writeAsBytes(plainBytes, flush: true);
      } else {
        final sink = file.openWrite();
        try {
          await for (final chunk in request) {
            bytesReceived += chunk.length;
            if (bytesReceived > pending.expectedBytes) {
              throw const LanHttpException(
                HttpStatus.requestEntityTooLarge,
                'Upload exceeded its accepted size.',
              );
            }
            sink.add(chunk);
          }
          await sink.flush();
        } finally {
          await sink.close();
        }
        if (bytesReceived != pending.expectedBytes) {
          throw const LanHttpException(
            HttpStatus.badRequest,
            'Upload size does not match accepted metadata.',
          );
        }
      }
      completed = true;
    } catch (_) {
      _protocolGuard.completePendingUpload(senderDeviceId, messageId);
      _messageProgressController.add(
        LanMessage(
          id: messageId,
          senderId: senderDeviceId,
          senderAlias: '',
          receiverId: currentDeviceId,
          payloadType: LanPayloadType.file,
          fileName: fileName,
          localPath: null,
          bytesTransferred: bytesReceived,
          fileSize: pending.expectedBytes,
          status: LanTransferStatus.failed,
          createdAt: DateTime.now(),
          isIncoming: true,
        ),
      );
      rethrow;
    } finally {
      final partialFile = targetFile;
      if (!completed && partialFile != null && await partialFile.exists()) {
        try {
          await partialFile.delete();
        } catch (_) {}
      }
    }

    _protocolGuard.completePendingUpload(senderDeviceId, messageId);

    _messageProgressController.add(
      LanMessage(
        id: messageId,
        senderId: senderDeviceId,
        senderAlias: '',
        receiverId: currentDeviceId,
        payloadType: LanPayloadType.file,
        fileName: fileName,
        localPath: targetFile.path,
        bytesTransferred: bytesReceived,
        fileSize: bytesReceived,
        status: LanTransferStatus.completed,
        createdAt: DateTime.now(),
        isIncoming: true,
      ),
    );

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'messageId': messageId}));
    await request.response.close();
  }

  /// 校验并广播已配对对端发来的撤回请求。
  Future<void> _handleRecallRequest(HttpRequest request) async {
    final senderDeviceId = await _protocolGuard.authorize(request);
    final json = await _protocolGuard.readJson(request);
    final messageId = json['messageId'] is String
        ? (json['messageId'] as String).trim()
        : '';
    if (messageId.isEmpty || messageId.length > 128) {
      throw const LanHttpException(
        HttpStatus.badRequest,
        'Invalid recalled message ID.',
      );
    }
    _recalledMessageIdController.add(
      LanRecallRequest(senderDeviceId: senderDeviceId, messageId: messageId),
    );

    request.response.statusCode = HttpStatus.ok;
    request.response.headers.contentType = ContentType.json;
    request.response.write(jsonEncode({'messageId': messageId}));
    await request.response.close();
  }

  // ── 带重试的客户端发送 API ──

  /// 创建用于 LAN 请求的证书固定 HTTP 客户端。
  Future<HttpClient> _createHttpClient({
    String? peerDeviceId,
    String? expectedFingerprint,
    bool allowUntrusted = false,
  }) async {
    final storedFingerprint = peerDeviceId == null
        ? null
        : await securityService.getPeerCertificateFingerprint(peerDeviceId);
    final providedFingerprint = expectedFingerprint?.trim().toLowerCase();
    if (providedFingerprint != null &&
        providedFingerprint.isNotEmpty &&
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(providedFingerprint)) {
      throw const FormatException('Invalid LAN certificate fingerprint');
    }
    if (storedFingerprint != null &&
        providedFingerprint != null &&
        providedFingerprint.isNotEmpty &&
        storedFingerprint.toLowerCase() != providedFingerprint) {
      throw const FormatException('LAN certificate fingerprint changed');
    }
    final pinnedFingerprint =
        storedFingerprint?.toLowerCase() ??
        (providedFingerprint?.isNotEmpty == true ? providedFingerprint : null);
    // 使用空信任库，确保每张证书都会到达回调。
    // 否则链到系统或企业 CA 的证书可能绕过应用层指纹固定。
    final client = HttpClient(context: SecurityContext())
      ..connectionTimeout = const Duration(seconds: 4)
      ..idleTimeout = const Duration(seconds: 15)
      ..findProxy = (_) => 'DIRECT';
    client.badCertificateCallback = (cert, host, port) {
      if (pinnedFingerprint == null) {
        return allowUntrusted;
      }
      return crypto.sha256.convert(cert.der).toString() == pinnedFingerprint;
    };
    return client;
  }

  /// 手动分发 Web Share 服务传入的 LanMessage。
  void handleIncomingMessageFromWeb(LanMessage message) {
    _incomingMessageController.add(message);
  }

  /// 手动分发 Web Share 服务的消息进度更新。
  void handleMessageProgressFromWeb(LanMessage message) {
    _messageProgressController.add(message);
  }

  /// 停止网络资源并关闭所有事件流。
  void dispose() {
    unawaited(stopListening());
    unawaited(closeConnections());
    _activeWebSockets.clear();
    _pendingPairingHandshakes.clear();
    _incomingMessageController.close();
    _messageProgressController.close();
    _recalledMessageIdController.close();
    _handshakeSuccessController.close();
    _handshakePendingController.close();
    _announcedDeviceController.close();
    _pairingInviteController.close();
    _connectionStateController.close();
  }
}
