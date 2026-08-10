// LAN Share 接收器协调器。
//
// 该类只编排 LAN HTTPS/mDNS、配对、Relay enrollment 和 Feature ViewModel，
// 不创建 SSH、FFI 或全局 Network 实现。NetworkRuntime、身份材料和原生
// NetworkService 均由 App Shell 通过 Port 注入，协调器是它们的使用方。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:uuid/uuid.dart';

import '../../../data/repositories/lan_share_history_repository.dart';
import '../../../domain/lan_share_ports.dart';
import '../../../services/lan_share/lan_discovery_service.dart';
import '../../../services/lan_share/lan_security_service.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import '../../../services/relay/relay_enrollment_service.dart';
import '../viewmodels/lan_share_viewmodel.dart';

/// 负责 LAN Receiver 的激活、停用和最终释放。
final class LanReceiverCoordinator extends ChangeNotifier {
  /// 创建一个只使用注入依赖的 LAN 接收器协调器。
  LanReceiverCoordinator({
    required this.appSettings,
    required this.logger,
    required this.dataProtection,
    required this.networkIdentity,
    required this.networkFactory,
    required this.bootstrapClient,
    required this.historyRepository,
    required this.networkRuntime,
    this.initializeNetwork = true,
  });

  /// App Scope 的 LAN 设置和身份配置。
  final AppSettings appSettings;

  /// App Scope 的日志适配器。
  final LanShareLoggerPort logger;

  /// Module 注入的数据库敏感字段保护服务。
  final LanShareDataProtectionPort dataProtection;

  /// App Scope 的稳定 QUIC 身份加载端口。
  final LanShareNetworkIdentityPort networkIdentity;

  /// App Shell 创建原生网络服务的唯一入口。
  final LanShareNetworkFactory networkFactory;

  /// App Shell 注入的无 Bearer Bootstrap 客户端。
  final BootstrapClient bootstrapClient;

  /// Module 所有的历史 Repository。
  final LanShareHistoryRepository historyRepository;

  /// App Scope 唯一网络运行时，用于按需准备 QUIC Capability。
  final NetworkRuntime networkRuntime;

  /// 测试中可关闭监听器和原生网络初始化，但仍保留服务装配流程。
  final bool initializeNetwork;

  LanDiscoveryService? _discoveryService;
  LanSecurityService? _securityService;
  LanStorageService? _lanStorageService;
  LanTransferService? _transferService;
  RelayEnrollmentService? _relayEnrollmentService;
  NetworkService? _networkService;
  LanShareNetworkIdentityMaterial? _networkIdentityMaterial;
  bool _nativeRelayActive = false;
  bool _receiverActive = false;

  final StreamController<LanPairingRequest> _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final Map<String, LanPairingRequest> _latestPairingRequests = {};
  StreamSubscription<LanPairingRequest>? _pairingInviteSubscription;
  StreamSubscription<LanDevice>? _announcedDeviceSubscription;
  StreamSubscription<LanDevice>? _handshakePendingSubscription;

  bool _initialized = false;
  bool _disposed = false;
  bool _notifierDisposed = false;
  Future<void>? _initFuture;
  Future<void>? _activationFuture;
  Future<void>? _closeFuture;
  LanShareViewModel? _viewModel;
  Future<LanShareViewModel>? _viewModelFuture;

  /// 接收器资源是否已完成初始化。
  bool get initialized => _initialized;

  /// 接收器当前是否正在监听和广播。
  bool get receiverActive => _receiverActive;

  /// 初始化完成后返回共享发现服务。
  LanDiscoveryService? get discoveryService => _discoveryService;

  /// 初始化完成后返回共享 LAN 安全服务。
  LanSecurityService? get securityService => _securityService;

  /// 初始化完成后返回唯一 LAN 存储服务。
  LanStorageService? get lanStorageService => _lanStorageService;

  /// 初始化完成后返回唯一 LAN 传输服务。
  LanTransferService? get transferService => _transferService;

  /// 初始化完成后返回 Relay enrollment 服务。
  RelayEnrollmentService? get relayEnrollmentService => _relayEnrollmentService;

  /// 当前是否已启用原生 Relay 配置。
  bool get nativeRelayActive => _nativeRelayActive;

  /// 可用时返回 App Shell 注入的网络服务。
  NetworkService? get networkService => _networkService;

  /// 接收器初始化后发布原生传入传输申请。
  Stream<IncomingTransferOffer> get nativeIncomingTransferOffers async* {
    await ensureInitialized();
    final network = _networkService;
    if (network == null || !_receiverActive) return;
    yield* network.events
        .where((event) => event is IncomingTransferOffer)
        .cast<IncomingTransferOffer>();
  }

  /// 校验设备配对后接受一个原生传入传输。
  Future<NetworkResult<void>> acceptNativeIncomingTransfer(
    IncomingTransferOffer offer,
  ) async {
    await ensureInitialized();
    await ensureViewModel();
    final network = _networkService;
    final security = _securityService;
    final transfer = _transferService;
    if (network == null || security == null || transfer == null) {
      return _networkFailure(
        NetworkErrorCode.noRoute,
        'native network runtime is unavailable',
        NetworkOperation.respondToIncoming,
      );
    }
    if (!await security.isDevicePaired(offer.peerId)) {
      await network.respondToIncoming(
        transferId: offer.transferId,
        accept: false,
      );
      return _networkFailure(
        NetworkErrorCode.authenticationFailed,
        'incoming transfer peer is no longer paired',
        NetworkOperation.respondToIncoming,
      );
    }
    transfer.handleIncomingMessageFromWeb(
      LanMessage(
        id: offer.transferId,
        senderId: offer.peerId,
        senderAlias: offer.peerId,
        receiverId: appSettings.lanDeviceId,
        payloadType: LanPayloadType.file,
        fileName: offer.fileName,
        fileSize: offer.fileSize,
        status: LanTransferStatus.connecting,
        createdAt: DateTime.now(),
        isIncoming: true,
      ),
    );
    return network.respondToIncoming(
      transferId: offer.transferId,
      accept: true,
    );
  }

  /// 拒绝一个原生传入传输申请。
  Future<NetworkResult<void>> rejectNativeIncomingTransfer(
    IncomingTransferOffer offer,
  ) async {
    await ensureInitialized();
    final network = _networkService;
    if (network == null) {
      return _networkFailure(
        NetworkErrorCode.noRoute,
        'native network runtime is unavailable',
        NetworkOperation.respondToIncoming,
      );
    }
    return network.respondToIncoming(
      transferId: offer.transferId,
      accept: false,
    );
  }

  /// 完成凭据 enrollment，并配置原生 Relay 数据面。
  Future<NetworkResult<void>> enrollRelay({
    required Uri endpoint,
    required String enrollmentToken,
  }) async {
    await ensureInitialized();
    final client = _relayEnrollmentService;
    if (client == null) {
      return _networkFailure(
        NetworkErrorCode.relayError,
        'Relay enrollment service is unavailable',
        NetworkOperation.enrollRelay,
      );
    }
    final relaySettings = RelaySettings(endpoint: endpoint);
    final enrollment = await client.enroll(relaySettings, enrollmentToken);
    if (enrollment is NetworkFailure<void>) return enrollment;
    await appSettings.setRelayEndpoint(endpoint.toString());
    final result = await _connectRelay(relaySettings);
    if (result is NetworkSuccess<void>) notifyListeners();
    return result;
  }

  /// 加载已存储 enrollment，并配置原生 Relay 连接。
  Future<NetworkResult<void>> connectConfiguredRelay() async {
    await ensureInitialized();
    final endpoint = Uri.tryParse(appSettings.relayEndpoint);
    final client = _relayEnrollmentService;
    if (endpoint == null || client == null) {
      return _networkFailure(
        NetworkErrorCode.relayError,
        'Relay configuration is unavailable',
        NetworkOperation.connectRelay,
      );
    }
    final settings = RelaySettings(endpoint: endpoint);
    if (!await client.isEnrolled(settings)) {
      return _networkFailure(
        NetworkErrorCode.authenticationFailed,
        'Relay enrollment is required',
        NetworkOperation.connectRelay,
      );
    }
    final result = await _connectRelay(settings);
    if (result is NetworkSuccess<void>) notifyListeners();
    return result;
  }

  /// 将 enrollment 凭据转换为注入网络服务使用的 Relay 配置。
  Future<NetworkResult<void>> _connectRelay(RelaySettings settings) async {
    final client = _relayEnrollmentService;
    final network = _networkService;
    if (client == null || network == null) {
      return _networkFailure(
        NetworkErrorCode.noRoute,
        'native network runtime is unavailable',
        NetworkOperation.connectRelay,
      );
    }
    final configuration = await client.nativeConfiguration(settings);
    if (configuration == null) {
      return _networkFailure(
        NetworkErrorCode.authenticationFailed,
        'Relay enrollment is required',
        NetworkOperation.connectRelay,
      );
    }
    final result = await network.configureRelay(
      RelayConfig(
        relayUrl: configuration.endpoint.toString(),
        relayCredential: configuration.credential,
        relaySigningSeed: configuration.signingSeed,
      ),
    );
    _nativeRelayActive = result is NetworkSuccess<void>;
    return result;
  }

  /// 发布唯一 LAN 接收器收到的配对请求。
  Stream<LanPairingRequest> get pairingRequestStream =>
      _pairingRequestController.stream;

  /// 返回 [sessionId] 对应的未过期配对请求。
  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestPairingRequests[sessionId];
    if (request == null || request.isExpired) return null;
    return request;
  }

  /// 初始化接收器资源一次，并让并发调用方共享同一个 Future。
  Future<void> ensureInitialized() {
    if (_disposed) {
      return Future<void>.error(
        StateError('LAN receiver coordinator is disposed.'),
      );
    }
    if (_initialized) return Future<void>.value();
    return _initFuture ??= _doInit();
  }

  /// 激活监听、广播和可选的原生网络数据面。
  Future<void> activateReceiver() {
    if (_disposed) {
      return Future<void>.error(
        StateError('LAN receiver coordinator is disposed.'),
      );
    }
    return _activationFuture ??= _activateReceiver();
  }

  Future<void> _activateReceiver() async {
    try {
      await ensureInitialized();
      if (_receiverActive) return;
      await _startReceiverRuntime();
      await _viewModel?.initialize();
      _receiverActive = true;
      notifyListeners();
    } finally {
      _activationFuture = null;
    }
  }

  /// 停止运行时活动但保留可重新激活的服务和数据库依赖。
  Future<void> deactivateReceiver() async {
    if (!_receiverActive) return;
    await _viewModel?.shutdown();
    await _transferService?.stopListening();
    await _discoveryService?.stopAdvertising();
    await _disposeNetworkService();
    _receiverActive = false;
    notifyListeners();
  }

  /// 创建或返回功能范围的 ViewModel。
  Future<LanShareViewModel> ensureViewModel() {
    if (_disposed) {
      return Future<LanShareViewModel>.error(
        StateError('LAN receiver coordinator is disposed.'),
      );
    }
    final existing = _viewModel;
    if (existing != null) return Future<LanShareViewModel>.value(existing);
    return _viewModelFuture ??= _createViewModel();
  }

  /// 使用共享接收器依赖构建 ViewModel。
  Future<LanShareViewModel> _createViewModel() async {
    LanShareViewModel? viewModel;
    try {
      await ensureInitialized();
      viewModel = LanShareViewModel(
        discoveryService: _discoveryService!,
        securityService: _securityService!,
        storageService: _lanStorageService!,
        transferService: _transferService!,
        networkService: _networkService,
        historyDao: historyRepository.dao,
        appSettings: appSettings,
        dataProtection: dataProtection,
        logger: logger,
        ownsRuntime: false,
        pairingRequestPublisher: publishPairingRequest,
      );
      if (_receiverActive) await viewModel.initialize();
      if (_disposed) {
        throw StateError('LAN receiver coordinator is disposed.');
      }
      for (final request in _latestPairingRequests.values) {
        if (!request.isExpired) viewModel.registerManualDevice(request.device);
      }
      _viewModel = viewModel;
      return viewModel;
    } catch (_) {
      viewModel?.dispose();
      _viewModelFuture = null;
      rethrow;
    }
  }

  /// 发布并保留一个未过期配对请求。
  void publishPairingRequest(LanPairingRequest request) {
    if (_disposed || request.isExpired) return;
    _latestPairingRequests.removeWhere((_, value) => value.isExpired);
    _latestPairingRequests[request.sessionId] = request;
    _pairingRequestController.add(request);
  }

  /// 将发现到的传入设备转换为配对请求。
  void _publishIncomingDevice(LanDevice device) {
    publishPairingRequest(
      LanPairingRequest(
        device: device,
        sessionId: const Uuid().v4(),
        isIncoming: true,
        expiresAt: DateTime.now().add(const Duration(minutes: 1)),
      ),
    );
  }

  /// 创建服务并准备一次性身份、事件订阅和历史依赖。
  Future<void> _doInit() async {
    LanDiscoveryService? discovery;
    LanTransferService? transfer;
    try {
      await appSettings.ensureLanIdentity();
      final deviceId = appSettings.lanDeviceId;
      final deviceAlias = appSettings.lanDeviceAlias;
      discovery = LanDiscoveryService(
        currentDeviceId: deviceId,
        currentDeviceAlias: deviceAlias,
      );
      final security = LanSecurityService();
      final lanStorage = LanStorageService(logger: logger);
      final identity = initializeNetwork
          ? await networkIdentity.loadOrCreate()
          : null;
      final relayEnrollmentService = RelayEnrollmentService(
        currentDeviceId: deviceId,
        bootstrapClient: bootstrapClient,
      );
      transfer = LanTransferService(
        currentDeviceId: deviceId,
        securityService: security,
        storageService: lanStorage,
        networkIdentityPublicKeyProvider: identity == null
            ? null
            : () async => identity.publicKey,
      );

      _discoveryService = discovery;
      _securityService = security;
      _lanStorageService = lanStorage;
      _transferService = transfer;
      _relayEnrollmentService = relayEnrollmentService;
      _networkIdentityMaterial = identity;
      _listenToTransferEvents(transfer);
      if (security.activePin == null) security.generate6DigitPin();

      _initialized = true;
      if (initializeNetwork) await _startReceiverRuntime();
      _receiverActive = initializeNetwork;
      notifyListeners();
      if (initializeNetwork) _connectConfiguredRelayInBackground();
    } catch (_) {
      await _cancelReceiverSubscriptions();
      await transfer?.stopListening();
      discovery?.dispose();
      transfer?.dispose();
      await _disposeNetworkService();
      _discoveryService = null;
      _securityService = null;
      _lanStorageService = null;
      _transferService = null;
      _relayEnrollmentService = null;
      _networkIdentityMaterial = null;
      _initialized = false;
      _initFuture = null;
      rethrow;
    }
  }

  /// 订阅一次性传输服务事件，避免 ViewModel 和 Coordinator 重复监听端口。
  void _listenToTransferEvents(LanTransferService transfer) {
    _pairingInviteSubscription = transfer.pairingInviteStream.listen(
      publishPairingRequest,
    );
    _announcedDeviceSubscription = transfer.announcedDeviceStream.listen(
      _publishIncomingDevice,
    );
    _handshakePendingSubscription = transfer.handshakePendingStream.listen(
      _publishIncomingDevice,
    );
  }

  /// 启动 HTTPS/mDNS 和按需原生网络能力。
  Future<void> _startReceiverRuntime() async {
    if (!initializeNetwork) return;
    final transfer = _transferService;
    final discovery = _discoveryService;
    if (transfer == null || discovery == null) return;

    int? boundPort;
    if (!transfer.isListening) {
      final listenerResult = await transfer.startListening();
      if (listenerResult is NetworkFailure<int>) {
        logger.warning(
          'LAN listener failed',
          details: listenerResult.error.toString(),
        );
      } else {
        boundPort = (listenerResult as NetworkSuccess<int>).data;
      }
    } else {
      boundPort = transfer.activePort;
    }
    if (boundPort != null) {
      final advertisingResult = await discovery.startAdvertising(
        port: boundPort,
      );
      if (advertisingResult is NetworkFailure<void>) {
        logger.warning(
          'LAN advertising failed',
          details: advertisingResult.error.toString(),
        );
      }
    }

    if (boundPort == null || _networkService != null) return;
    final identity = _networkIdentityMaterial;
    final security = _securityService;
    final storage = _lanStorageService;
    if (identity == null || security == null || storage == null) return;

    try {
      await networkRuntime.ensureCapability(NetworkCapability.quic);
      final network = await networkFactory.create(
        deviceId: appSettings.lanDeviceId,
        identityPrivateKey: identity.privateSeed,
        e2ePrivateKey: await security.getStaticX25519PrivateKeyBytes(),
        listenAddress: '0.0.0.0:$boundPort',
        receiveDirectory: (await storage.getSandboxDirectory()).path,
      );
      if (network == null) return;
      final startResult = await network.start(
        NetworkRuntimeConfig(
          deviceId: appSettings.lanDeviceId,
          identityPrivateKey: identity.privateSeed,
          e2ePrivateKey: await security.getStaticX25519PrivateKeyBytes(),
          listenAddress: '0.0.0.0:$boundPort',
          receiveDirectory: (await storage.getSandboxDirectory()).path,
        ),
      );
      if (startResult is NetworkFailure<void>) {
        logger.warning(
          'Native network runtime configuration failed',
          details: startResult.error.toString(),
        );
        await network.dispose();
        return;
      }
      _networkService = network;
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Native QUIC runtime initialization failed',
        details: '$error\n$stackTrace',
      );
    }
  }

  /// 在后台尝试恢复已保存的 Relay enrollment。
  void _connectConfiguredRelayInBackground() {
    final endpoint = Uri.tryParse(appSettings.relayEndpoint);
    if (endpoint == null || !endpoint.hasScheme) return;
    unawaited(
      _connectRelay(RelaySettings(endpoint: endpoint))
          .then((_) => notifyListeners())
          .catchError((Object error, StackTrace stackTrace) {
            logger.warning(
              'Configured Relay connection failed',
              details: '$error\n$stackTrace',
            );
          }),
    );
  }

  /// 取消接收器持有的 LAN 事件订阅。
  Future<void> _cancelReceiverSubscriptions() async {
    await _pairingInviteSubscription?.cancel();
    _pairingInviteSubscription = null;
    await _announcedDeviceSubscription?.cancel();
    _announcedDeviceSubscription = null;
    await _handshakePendingSubscription?.cancel();
    _handshakePendingSubscription = null;
  }

  /// 停止并释放 App Shell 创建的网络服务。
  Future<void> _disposeNetworkService() async {
    final network = _networkService;
    _networkService = null;
    _nativeRelayActive = false;
    if (network == null) return;
    try {
      await network.stop();
    } catch (error, stackTrace) {
      logger.warning(
        'Native network runtime stop failed',
        details: '$error\n$stackTrace',
      );
    }
    await network.dispose();
  }

  /// 将统一错误构造成稳定的失败结果。
  NetworkFailure<void> _networkFailure(
    NetworkErrorCode code,
    String message,
    NetworkOperation operation,
  ) => NetworkFailure(
    NetworkError(code: code, message: message, operation: operation),
  );

  /// 异步关闭所有由 Coordinator 使用的网络、传输、订阅和 ViewModel。
  Future<void> close() => _closeFuture ??= _closeResources();

  Future<void> _closeResources() async {
    if (_disposed) return;
    _disposed = true;
    await _viewModel?.shutdown();
    _viewModel?.dispose();
    _viewModel = null;
    await _cancelReceiverSubscriptions();
    await _transferService?.stopListening();
    await _discoveryService?.stopAdvertising();
    await _disposeNetworkService();
    await _relayEnrollmentService?.dispose();
    _relayEnrollmentService = null;
    _transferService?.dispose();
    _discoveryService?.dispose();
    _transferService = null;
    _discoveryService = null;
    _securityService = null;
    _lanStorageService = null;
    _initialized = false;
    _receiverActive = false;
    if (!_pairingRequestController.isClosed) {
      await _pairingRequestController.close();
    }
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
  }

  /// Flutter 兼容入口；正式 Module 会等待 [close] 完成。
  @override
  void dispose() {
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
    unawaited(close());
  }
}
