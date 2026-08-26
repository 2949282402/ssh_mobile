// LAN Share 接收器协调器。
//
// 该类只编排 LAN HTTPS/mDNS、配对、Relay enrollment 和 Feature ViewModel，
// 不创建 SSH、FFI 或全局 Network 实现。NetworkRuntime、身份材料和原生
// NetworkFacade 均由 App Shell 通过 Port 注入，协调器是它们的使用方。

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:network_transport/network_transport.dart';
import 'package:uuid/uuid.dart';

import '../../../data/repositories/lan_share_history_repository.dart';
import '../../../domain/lan_share_ports.dart';
import '../../../services/lan_share/lan_discovery_service.dart';
import '../../../services/lan_share/lan_native_transfer_coordinator.dart';
import '../../../services/lan_share/lan_peer_trust.dart';
import '../../../services/lan_share/lan_security_service.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import '../../../services/relay/relay_enrollment_service.dart';
import '../viewmodels/lan_share_viewmodel.dart';
import 'lan_native_peer_registry.dart';
import 'lan_relay_coordinator.dart';

export 'lan_relay_coordinator.dart' show LanRelayStatus;

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
    LanPeerTrustStore? peerTrustStore,
    this.initializeNetwork = true,
    this.transferServiceOverride,
    this.discoveryServiceOverride,
    this.storageServiceOverride,
  }) : peerTrustStore = peerTrustStore ?? LanPeerTrustStore(),
       _ownsPeerTrustStore = peerTrustStore == null;

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

  /// App Scope 唯一网络运行时，用于按需准备 native runtime Capability。
  final NetworkRuntime networkRuntime;

  /// Module-owned atomic trust store. The Coordinator only consumes it and
  /// never treats discovery/reachability as trust.
  final LanPeerTrustStore peerTrustStore;
  final bool _ownsPeerTrustStore;

  /// The single Feature owner for native peer registration and revocation.
  late final LanNativePeerRegistry peerRegistry = LanNativePeerRegistry(
    trustStore: peerTrustStore,
  );

  /// 测试中可关闭监听器和原生网络初始化，但仍保留服务装配流程。
  final bool initializeNetwork;

  /// 可选的 LAN 传输服务覆盖；缺省时由初始化流程内部构造真实服务。
  ///
  /// 供测试注入 fake，避免在测试环境触发真实 HTTPS 绑定、TLS 证书 isolate
  /// 生成或 multicast 网络路径。
  final LanTransferService? transferServiceOverride;

  /// 可选的 LAN 发现服务覆盖；缺省时由初始化流程内部构造真实服务。
  final LanDiscoveryService? discoveryServiceOverride;

  /// 可选的 LAN 存储服务覆盖；缺省时由初始化流程内部构造真实服务。
  final LanStorageService? storageServiceOverride;

  LanDiscoveryService? _discoveryService;
  LanSecurityService? _securityService;
  LanStorageService? _lanStorageService;
  LanTransferService? _transferService;
  LanRelayCoordinator? _relayCoordinator;
  LanNativeTransferCoordinator? _nativeTransferCoordinator;
  NetworkFacade? _networkFacade;
  LanShareNetworkIdentityMaterial? _networkIdentityMaterial;
  bool _receiverActive = false;

  final StreamController<LanPairingRequest> _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final Map<String, LanPairingRequest> _latestPairingRequests = {};
  StreamSubscription<LanPairingRequest>? _pairingInviteSubscription;
  StreamSubscription<LanDiscoveredPeer>? _announcedPeerSubscription;
  StreamSubscription<List<LanDiscoveredPeer>>? _discoveredPeersSubscription;
  StreamSubscription<LanDiscoveredPeer>? _handshakeSuccessSubscription;
  StreamSubscription<IncomingTransferOffer>? _nativeOfferSubscription;
  final StreamController<IncomingTransferOffer> _incomingTransferController =
      StreamController<IncomingTransferOffer>.broadcast();

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
  LanRelayEnrollmentPort? get relayEnrollmentService =>
      _relayCoordinator?.enrollmentService;

  /// 当前是否已启用原生 Relay 配置。
  bool get nativeRelayActive => _relayCoordinator?.nativeRelayActive ?? false;

  /// 当前 Relay 配置、连接和自动重连状态。
  LanRelayStatus get relayStatus =>
      _relayCoordinator?.status ??
      LanRelayStatus(
        endpoint: appSettings.relayEndpoint,
        state: RelayConnectionState.disconnected,
        enrolled: false,
        reconnectAttempt: 0,
      );

  /// 可用时返回 App Shell 注入的网络 Facade。
  NetworkFacade? get networkFacade => _networkFacade;

  /// 当前 runtime generation 的 Network V2 file-transfer coordinator。
  LanNativeTransferCoordinator? get nativeTransferCoordinator =>
      _nativeTransferCoordinator;

  /// 接收器初始化后发布原生传入传输申请。
  Stream<IncomingTransferOffer> get nativeIncomingTransferOffers =>
      _incomingTransferController.stream;

  /// 校验设备配对后接受一个原生传入传输。
  Future<NetworkResult<void>> acceptNativeIncomingTransfer(
    IncomingTransferOffer offer,
  ) async {
    await ensureInitialized();
    await ensureViewModel();
    final nativeTransfer = _nativeTransferCoordinator;
    final transfer = _transferService;
    if (nativeTransfer == null || transfer == null) {
      return _networkFailure(
        NetworkErrorCode.noRoute,
        'native network runtime is unavailable',
        NetworkOperation.respondToIncoming,
      );
    }
    final trust = await peerTrustStore.read(offer.peerId);
    if (trust == null ||
        !isIncomingRouteAuthorized(trust.authorization, offer.routeType)) {
      // Keep the transfer decision inside the generation-scoped native
      // coordinator. It re-checks the complete trust record and performs the
      // one-shot native rejection, so this facade never becomes a second
      // incoming-transfer owner.
      return nativeTransfer.reject(offer);
    }
    final nativeResult = await nativeTransfer.accept(offer);
    if (nativeResult is NetworkFailure<void>) return nativeResult;
    transfer.handleIncomingMessageFromWeb(
      LanMessage(
        id: offer.transferId,
        senderId: offer.peerId,
        senderAlias: offer.peerId,
        receiverId: appSettings.lanDeviceId,
        payloadType: classifyAttachment(fileName: offer.fileName),
        fileName: offer.fileName,
        fileSize: offer.fileSize,
        status: LanTransferStatus.connecting,
        createdAt: DateTime.now(),
        isIncoming: true,
        routeType: offer.routeType,
      ),
    );
    return nativeResult;
  }

  /// 拒绝一个原生传入传输申请。
  Future<NetworkResult<void>> rejectNativeIncomingTransfer(
    IncomingTransferOffer offer,
  ) async {
    await ensureInitialized();
    final nativeTransfer = _nativeTransferCoordinator;
    if (nativeTransfer == null) {
      return _networkFailure(
        NetworkErrorCode.noRoute,
        'native network runtime is unavailable',
        NetworkOperation.respondToIncoming,
      );
    }
    return nativeTransfer.reject(offer);
  }

  /// 仅保存 Relay origin；端点变化会断开旧 socket 并清除旧 enrollment。
  Future<NetworkResult<void>> saveRelayEndpoint(Uri endpoint) async {
    await ensureInitialized();
    return _relayCoordinator!.saveEndpoint(endpoint);
  }

  /// 完成凭据 enrollment，并配置原生 Relay 数据面。
  Future<NetworkResult<void>> enrollRelay({
    required Uri endpoint,
    required String enrollmentToken,
  }) async {
    await ensureInitialized();
    return _relayCoordinator!.enroll(
      endpoint: endpoint,
      enrollmentToken: enrollmentToken,
    );
  }

  /// 加载已存储 enrollment，并配置原生 Relay 连接。
  Future<NetworkResult<void>> connectConfiguredRelay() async {
    await ensureInitialized();
    return _relayCoordinator!.connectConfigured();
  }

  /// 主动断开 Relay，但保留 endpoint 和 enrollment 供下次连接使用。
  Future<NetworkResult<void>> disconnectRelay() async {
    await ensureInitialized();
    return _relayCoordinator!.disconnect();
  }

  /// 清除 endpoint 与短期 enrollment credential，但保留设备签名种子。
  Future<NetworkResult<void>> clearRelayEnrollment() async {
    await ensureInitialized();
    return _relayCoordinator!.clearEnrollment();
  }

  /// Explicitly revoke one complete trust record and its native peer.
  ///
  /// Discovery loss, relay disconnect, and Feature deactivation never call
  /// this method; only an explicit unpair action may remove trust.
  Future<NetworkResult<void>> removeTrustedPeer(String deviceId) async {
    await ensureInitialized();
    return peerRegistry.removeTrust(deviceId);
  }

  Future<NetworkResult<void>> authorizeRelayForPeer(String deviceId) async {
    await ensureInitialized();
    return peerRegistry.authorizeRelayForPeer(deviceId);
  }

  Future<NetworkResult<void>> revokeRelayForPeer(String deviceId) async {
    await ensureInitialized();
    return peerRegistry.revokeRelayForPeer(deviceId);
  }

  /// 仅在 Coordinator 仍活跃时通知路由级观察者。
  void _notifyIfActive() {
    if (!_disposed && !_notifierDisposed) notifyListeners();
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

  /// 停止 Feature listener/discovery 活动但保留 App-owned network runtime。
  Future<void> deactivateReceiver() async {
    if (!_receiverActive) return;
    await _viewModel?.shutdown();
    await _transferService?.stopListening();
    await _discoveryService?.stopAdvertising();
    await _disposeNetworkFacade();
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
        nativeTransferCoordinator: _nativeTransferCoordinator,
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
        if (!request.isExpired && request.peer.discovery != null) {
          viewModel.registerDiscoveredPeer(request.peer.discovery!);
        }
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

  /// 将发现到的传入对端转换为配对请求。
  void _publishIncomingPeer(LanDiscoveredPeer peer) {
    publishPairingRequest(
      LanPairingRequest(
        peer: LanPeerViewState(discovery: peer),
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
    LanRelayCoordinator? relay;
    try {
      await appSettings.ensureLanIdentity();
      final deviceId = appSettings.lanDeviceId;
      final deviceAlias = appSettings.lanDeviceAlias;
      discovery =
          discoveryServiceOverride ??
          LanDiscoveryService(
            currentDeviceId: deviceId,
            currentDeviceAlias: deviceAlias,
          );
      // Network identity belongs to App Scope and is needed by LAN security
      // even when this Feature's listener/runtime activation is disabled.
      // `initializeNetwork` only gates native capability/listener borrowing.
      final identity = await networkIdentity.loadOrCreate();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: identity.x25519PrivateSeed,
        peerTrustStore: peerTrustStore,
      );
      final lanStorage =
          storageServiceOverride ?? LanStorageService(logger: logger);
      final relayEnrollmentService = RelayEnrollmentService(
        currentDeviceId: deviceId,
        bootstrapClient: bootstrapClient,
      );
      relay = LanRelayCoordinator(
        appSettings: appSettings,
        logger: logger,
        enrollmentService: relayEnrollmentService,
        capability: _LanRelayCapabilityAdapter(networkRuntime),
        onChanged: _notifyIfActive,
      );
      transfer =
          transferServiceOverride ??
          LanTransferService(
            currentDeviceId: deviceId,
            securityService: security,
            storageService: lanStorage,
            networkIdentityPublicKeyProvider: () async => identity.publicKey,
            nativeTransferPortProvider: () => networkFactory.boundLocalPort,
          );

      _discoveryService = discovery;
      _securityService = security;
      _lanStorageService = lanStorage;
      _transferService = transfer;
      _relayCoordinator = relay;
      _networkIdentityMaterial = identity;
      _listenToTransferEvents(transfer, discovery);
      if (security.activePin == null) security.generate6DigitPin();

      _initialized = true;
      if (initializeNetwork) await _startReceiverRuntime();
      _receiverActive = initializeNetwork;
      notifyListeners();
      if (initializeNetwork) relay.connectConfiguredInBackground();
    } catch (_) {
      await _cancelReceiverSubscriptions();
      await discovery?.close();
      await transfer?.close();
      await _disposeNetworkFacade();
      await relay?.close();
      _discoveryService = null;
      _securityService = null;
      _lanStorageService = null;
      _transferService = null;
      _relayCoordinator = null;
      _networkIdentityMaterial = null;
      _initialized = false;
      _initFuture = null;
      rethrow;
    }
  }

  /// 订阅一次性传输服务事件，避免 ViewModel 和 Coordinator 重复监听端口。
  void _listenToTransferEvents(
    LanTransferService transfer,
    LanDiscoveryService discovery,
  ) {
    _pairingInviteSubscription = transfer.pairingInviteStream.listen(
      publishPairingRequest,
    );
    _announcedPeerSubscription = transfer.announcedPeerStream.listen(
      _publishIncomingPeer,
    );
    _handshakeSuccessSubscription = transfer.handshakeSuccessPeerStream.listen(
      (device) => unawaited(_registerNewlyPairedPeer(device)),
    );
    _discoveredPeersSubscription = discovery.discoveredPeersStream.listen(
      (peers) => unawaited(_syncDiscoveredEndpoints(peers)),
      onError: (Object error, StackTrace stackTrace) {
        logger.warning(
          'LAN discovery endpoint synchronization failed',
          details: '$error\n$stackTrace',
        );
      },
    );
  }

  Future<void> _syncDiscoveredEndpoints(
    Iterable<LanDiscoveredPeer> peers,
  ) async {
    try {
      await peerRegistry.syncDiscoveredEndpoints(peers);
    } on Object catch (error, stackTrace) {
      logger.warning(
        'LAN discovery endpoint synchronization failed',
        details: '$error\n$stackTrace',
      );
    }
  }

  /// 配对完成后立即同步当前 native runtime 的完整信任注册。
  Future<void> _registerNewlyPairedPeer(LanDiscoveredPeer peer) async {
    final facade = _networkFacade;
    if (facade == null || _disposed) return;
    try {
      if (_disposed || !identical(_networkFacade, facade)) return;
      final trust = await peerTrustStore.read(peer.deviceId);
      if (trust == null) return;
      final registerResult = await peerRegistry.reconcilePersistedTrust(trust);
      if (registerResult is NetworkFailure<void>) {
        logger.warning(
          'Native paired peer registration failed',
          details: registerResult.error.toString(),
        );
        return;
      }
      await peerRegistry.syncDiscoveredEndpoints(<LanDiscoveredPeer>[peer]);
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Native paired peer synchronization failed',
        details: '$error\n$stackTrace',
      );
    }
  }

  /// 启动 HTTPS/mDNS 和按需原生网络能力。
  Future<void> _startReceiverRuntime() async {
    if (!initializeNetwork) return;
    final transfer = _transferService;
    final discovery = _discoveryService;
    if (transfer == null || discovery == null) return;

    // The App Scope has already configured the shared native runtime. Borrow
    // its facade and restore the complete trust snapshot before starting the
    // HTTPS listener: once the control listener can accept trusted traffic,
    // the corresponding native peers must already be registered. The native
    // endpoint is independent of the HTTPS listener's bound port, so a
    // control-listener failure must not suppress inbound trust restoration.
    int? nativePort;
    if (_networkFacade == null) {
      final identity = _networkIdentityMaterial;
      final security = _securityService;
      final storage = _lanStorageService;
      if (identity != null && security != null && storage != null) {
        try {
          await networkRuntime.ensureCapability(NetworkCapability.runtime);
          final facade = await networkFactory.create(
            deviceId: appSettings.lanDeviceId,
            identityPrivateKey: identity.privateSeed,
            e2ePrivateKey: identity.x25519PrivateSeed,
            listenAddress: '0.0.0.0:0',
            receiveDirectory: (await storage.getSandboxDirectory()).path,
          );
          if (facade != null) {
            _networkFacade = facade;
            peerRegistry.attachFacade(facade);
            await peerRegistry.restoreAll();
            _nativeTransferCoordinator = LanNativeTransferCoordinator(
              transferService: transfer,
              networkFacade: facade,
              policyPort: peerRegistry,
              storageService: storage,
            );
            await _bindNativeOfferStream(_nativeTransferCoordinator!);
            final discoveredPeers = discovery.currentDiscoveredPeers;
            if (discoveredPeers.isNotEmpty) {
              await peerRegistry.syncDiscoveredEndpoints(discoveredPeers);
            }
            nativePort = networkFactory.boundLocalPort;
            await _relayCoordinator?.attachFacade(facade);
            _relayCoordinator?.connectConfiguredInBackground();
          }
        } on Object catch (error, stackTrace) {
          logger.warning(
            'Native network runtime initialization failed',
            details: '$error\n$stackTrace',
          );
          await _disposeNetworkFacade();
        }
      }
    } else {
      nativePort = networkFactory.boundLocalPort;
    }

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
    if (boundPort != null && nativePort == null) {
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

    if (boundPort != null && nativePort != null) {
      final nativeAdvertisingResult = await discovery.startAdvertising(
        port: boundPort,
        nativePort: nativePort,
      );
      if (nativeAdvertisingResult is NetworkFailure<void>) {
        logger.warning(
          'LAN native endpoint advertising failed',
          details: nativeAdvertisingResult.error.toString(),
        );
      }
    }
  }

  /// 把每一代 Facade 的 offer 事件桥接到 Coordinator 稳定生命周期流。
  Future<void> _bindNativeOfferStream(
    LanNativeTransferCoordinator nativeTransfer,
  ) async {
    await _nativeOfferSubscription?.cancel();
    _nativeOfferSubscription = nativeTransfer.incomingOffers.listen(
      (offer) => unawaited(_publishTrustedIncomingOffer(offer)),
      onError: (Object error, StackTrace stackTrace) {
        logger.warning(
          'Native incoming transfer stream failed',
          details: '$error\n$stackTrace',
        );
      },
    );
  }

  Future<void> _publishTrustedIncomingOffer(IncomingTransferOffer offer) async {
    if (_disposed || _incomingTransferController.isClosed) return;
    final trust = await peerTrustStore.read(offer.peerId);
    if (trust == null ||
        !isIncomingRouteAuthorized(trust.authorization, offer.routeType)) {
      return;
    }
    if (!_disposed && !_incomingTransferController.isClosed) {
      _incomingTransferController.add(offer);
    }
  }

  /// 取消接收器持有的 LAN 事件订阅。
  Future<void> _cancelReceiverSubscriptions() async {
    await _pairingInviteSubscription?.cancel();
    _pairingInviteSubscription = null;
    await _announcedPeerSubscription?.cancel();
    _announcedPeerSubscription = null;
    await _handshakeSuccessSubscription?.cancel();
    _handshakeSuccessSubscription = null;
    await _discoveredPeersSubscription?.cancel();
    _discoveredPeersSubscription = null;
  }

  /// 撤销 Feature 对 App-owned Facade 的订阅；不停止或释放共享 Runtime。
  Future<void> _disposeNetworkFacade() async {
    _networkFacade = null;
    peerRegistry.detachFacade();
    await _nativeOfferSubscription?.cancel();
    _nativeOfferSubscription = null;
    await _nativeTransferCoordinator?.dispose();
    _nativeTransferCoordinator = null;
    await _relayCoordinator?.detachFacade();
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
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    final viewModel = _viewModel;
    final transferService = _transferService;
    final discoveryService = _discoveryService;
    final relayCoordinator = _relayCoordinator;
    await attempt(() => viewModel?.shutdown());
    await attempt(() => viewModel?.dispose());
    _viewModel = null;
    await attempt(_cancelReceiverSubscriptions);
    await attempt(() => transferService?.stopListening());
    await attempt(() => discoveryService?.stopAdvertising());
    await attempt(_disposeNetworkFacade);
    await attempt(() => relayCoordinator?.close());
    _relayCoordinator = null;
    await attempt(() => discoveryService?.close());
    await attempt(() => transferService?.close());
    if (_ownsPeerTrustStore) {
      await attempt(peerTrustStore.dispose);
    }
    _transferService = null;
    _discoveryService = null;
    _securityService = null;
    _lanStorageService = null;
    _initialized = false;
    _receiverActive = false;
    if (!_pairingRequestController.isClosed) {
      await attempt(_pairingRequestController.close);
    }
    if (!_incomingTransferController.isClosed) {
      await attempt(_incomingTransferController.close);
    }
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  /// Flutter 兼容入口；正式 Module 会等待 [close] 完成。
  @override
  void dispose() {
    if (!_notifierDisposed) {
      _notifierDisposed = true;
      super.dispose();
    }
    unawaited(
      close().catchError((Object error) {
        logger.warning(
          'LAN receiver cleanup failed',
          details: 'errorType=${error.runtimeType}',
        );
      }),
    );
  }
}

/// 将 App Scope Runtime 收窄为 Relay Owner 可借用的单一能力。
final class _LanRelayCapabilityAdapter implements LanRelayCapabilityPort {
  const _LanRelayCapabilityAdapter(this._runtime);

  final NetworkRuntime _runtime;

  @override
  Future<void> ensureWebSocketRelay() =>
      _runtime.ensureCapability(NetworkCapability.webSocketRelay);
}
