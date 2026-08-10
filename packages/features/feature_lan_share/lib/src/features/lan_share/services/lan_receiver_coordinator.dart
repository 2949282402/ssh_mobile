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

/// Relay 配置和数据面状态的安全快照；不包含 token、credential 或签名材料。
final class LanRelayStatus {
  /// 创建一个 Relay 状态快照。
  const LanRelayStatus({
    required this.endpoint,
    required this.state,
    required this.enrolled,
    required this.reconnectAttempt,
    this.error,
  });

  /// 当前保存的 HTTPS Relay origin。
  final String endpoint;

  /// 原生 Relay WebSocket 的最终观察状态。
  final RelayConnectionState state;

  /// 当前设备是否有绑定到该 endpoint 的有效 enrollment。
  final bool enrolled;

  /// 当前自动重连序号；0 表示尚未开始自动重连。
  final int reconnectAttempt;

  /// 最近一次安全可展示的错误。
  final NetworkError? error;

  /// Relay 数据面是否已连接。
  bool get isConnected => state == RelayConnectionState.connected;

  /// Relay 是否正在建立连接。
  bool get isConnecting => state == RelayConnectionState.connecting;
}

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
  RelayConnectionState _relayConnectionState =
      RelayConnectionState.disconnected;
  NetworkError? _relayError;
  bool _relayEnrolled = false;
  int _relayReconnectAttempt = 0;
  Timer? _relayReconnectTimer;
  Future<NetworkResult<void>>? _relayConnectFuture;
  bool _relayReconnectEnabled = true;
  bool _relayExplicitlyDisconnected = false;
  bool _applyingRelayEndpoint = false;
  String _observedRelayEndpoint = '';
  bool _receiverActive = false;

  final StreamController<LanPairingRequest> _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final Map<String, LanPairingRequest> _latestPairingRequests = {};
  StreamSubscription<LanPairingRequest>? _pairingInviteSubscription;
  StreamSubscription<LanDevice>? _announcedDeviceSubscription;
  StreamSubscription<LanDevice>? _handshakePendingSubscription;
  StreamSubscription<NetworkEvent>? _networkEventSubscription;

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

  /// 当前 Relay 配置、连接和自动重连状态。
  LanRelayStatus get relayStatus => LanRelayStatus(
    endpoint: appSettings.relayEndpoint,
    state: _relayConnectionState,
    enrolled: _relayEnrolled,
    reconnectAttempt: _relayReconnectAttempt,
    error: _relayError,
  );

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
        routeType: offer.routeType,
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

  /// 仅保存 Relay origin；端点变化会断开旧 socket 并清除旧 enrollment。
  Future<NetworkResult<void>> saveRelayEndpoint(Uri endpoint) async {
    await ensureInitialized();
    if (!_isValidRelayEndpoint(endpoint)) {
      return _networkFailure(
        NetworkErrorCode.invalidArgument,
        'Relay endpoint must be an HTTPS origin',
        NetworkOperation.connectRelay,
      );
    }
    final normalized = endpoint
        .replace(path: '', query: null, fragment: null)
        .toString();
    if (normalized != appSettings.relayEndpoint) {
      _stopRelayReconnect();
      _relayReconnectEnabled = false;
      _relayExplicitlyDisconnected = true;
      await _waitForRelayConnect();
      final disconnected = await _disconnectRelaySocket();
      if (disconnected is NetworkFailure<void>) return disconnected;
      await _relayEnrollmentService?.clearEnrollment();
      _relayEnrolled = false;
    }
    try {
      _applyingRelayEndpoint = true;
      await appSettings.setRelayEndpoint(normalized);
    } on ArgumentError catch (error) {
      return _networkFailure(
        NetworkErrorCode.invalidArgument,
        error.message?.toString() ?? 'Relay endpoint is invalid',
        NetworkOperation.connectRelay,
      );
    } finally {
      _applyingRelayEndpoint = false;
    }
    _relayError = null;
    _notifyIfActive();
    return const NetworkSuccess<void>(null);
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
    if (!_isValidRelayEndpoint(endpoint)) {
      return _networkFailure(
        NetworkErrorCode.invalidArgument,
        'Relay enrollment endpoint must be an HTTPS origin',
        NetworkOperation.enrollRelay,
      );
    }
    _stopRelayReconnect();
    _relayReconnectEnabled = false;
    _relayExplicitlyDisconnected = true;
    await _waitForRelayConnect();
    final disconnected = await _disconnectRelaySocket();
    if (disconnected is NetworkFailure<void>) return disconnected;

    final relaySettings = RelaySettings(
      endpoint: endpoint.replace(path: '', query: null, fragment: null),
    );
    final enrollment = await client.enroll(
      relaySettings,
      enrollmentToken.trim(),
    );
    if (enrollment is NetworkFailure<void>) {
      _relayEnrolled = false;
      _relayError = enrollment.error;
      _notifyIfActive();
      return enrollment;
    }
    try {
      _applyingRelayEndpoint = true;
      await appSettings.setRelayEndpoint(relaySettings.endpoint.toString());
    } finally {
      _applyingRelayEndpoint = false;
    }
    _relayReconnectEnabled = true;
    _relayExplicitlyDisconnected = false;
    _relayEnrolled = true;
    _relayError = null;
    final result = await _connectRelay(relaySettings);
    if (result is NetworkFailure<void>) _relayError = result.error;
    _notifyIfActive();
    return result;
  }

  /// 加载已存储 enrollment，并配置原生 Relay 连接。
  Future<NetworkResult<void>> connectConfiguredRelay() async {
    await ensureInitialized();
    _stopRelayReconnect();
    _relayReconnectAttempt = 0;
    _relayReconnectEnabled = true;
    _relayExplicitlyDisconnected = false;
    return _connectConfiguredRelay();
  }

  /// 主动断开 Relay，但保留 endpoint 和 enrollment 供下次连接使用。
  Future<NetworkResult<void>> disconnectRelay() async {
    await ensureInitialized();
    _stopRelayReconnect();
    _relayReconnectEnabled = false;
    _relayExplicitlyDisconnected = true;
    await _waitForRelayConnect();
    final result = await _disconnectRelaySocket();
    _notifyIfActive();
    return result;
  }

  /// 清除 endpoint 与短期 enrollment credential，但保留设备签名种子。
  Future<NetworkResult<void>> clearRelayEnrollment() async {
    await ensureInitialized();
    _stopRelayReconnect();
    _relayReconnectEnabled = false;
    _relayExplicitlyDisconnected = true;
    await _waitForRelayConnect();
    final disconnected = await _disconnectRelaySocket();
    await _relayEnrollmentService?.clearEnrollment();
    _relayEnrolled = false;
    _relayError = null;
    try {
      _applyingRelayEndpoint = true;
      await appSettings.setRelayEndpoint('');
    } finally {
      _applyingRelayEndpoint = false;
    }
    _notifyIfActive();
    return disconnected;
  }

  /// 将 enrollment 凭据转换为注入网络服务使用的 Relay 配置。
  Future<NetworkResult<void>> _connectRelay(RelaySettings settings) async {
    final existing = _relayConnectFuture;
    if (existing != null) return existing;
    final operation = _doConnectRelay(settings);
    _relayConnectFuture = operation;
    try {
      return await operation;
    } finally {
      if (identical(_relayConnectFuture, operation)) _relayConnectFuture = null;
    }
  }

  /// 等待已有配置操作完成，避免旧任务在显式断开后重新打开 Relay。
  Future<void> _waitForRelayConnect() async {
    final operation = _relayConnectFuture;
    if (operation == null) return;
    try {
      await operation;
    } on Object {
      // 连接结果通过 NetworkResult 传播；这里仅等待其生命周期结束。
    }
  }

  Future<NetworkResult<void>> _doConnectRelay(RelaySettings settings) async {
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
      _relayEnrolled = false;
      return _networkFailure(
        NetworkErrorCode.authenticationFailed,
        'Relay enrollment is required',
        NetworkOperation.connectRelay,
      );
    }
    if (_nativeRelayActive ||
        _relayConnectionState == RelayConnectionState.connected ||
        _relayConnectionState == RelayConnectionState.connecting) {
      final disconnected = await _disconnectRelaySocket();
      if (disconnected is NetworkFailure<void>) return disconnected;
    }
    final result = await network.configureRelay(
      RelayConfig(
        relayUrl: configuration.endpoint.toString(),
        relayCredential: configuration.credential,
        relaySigningSeed: configuration.signingSeed,
      ),
    );
    _nativeRelayActive = result is NetworkSuccess<void>;
    if (result is NetworkFailure<void>) _relayError = result.error;
    return result;
  }

  Future<NetworkResult<void>> _connectConfiguredRelay() async {
    final endpoint = Uri.tryParse(appSettings.relayEndpoint);
    final client = _relayEnrollmentService;
    if (endpoint == null ||
        client == null ||
        !_isValidRelayEndpoint(endpoint)) {
      return _networkFailure(
        NetworkErrorCode.relayError,
        'Relay configuration is unavailable',
        NetworkOperation.connectRelay,
      );
    }
    final settings = RelaySettings(endpoint: endpoint);
    _relayEnrolled = await client.isEnrolled(settings);
    if (!_relayEnrolled) {
      final failure = _networkFailure(
        NetworkErrorCode.authenticationFailed,
        'Relay enrollment is required',
        NetworkOperation.connectRelay,
      );
      _relayError = failure.error;
      _notifyIfActive();
      return failure;
    }
    final result = await _connectRelay(settings);
    if (result is NetworkFailure<void>) {
      _relayError = result.error;
      _scheduleRelayReconnect();
    }
    _notifyIfActive();
    return result;
  }

  Future<NetworkResult<void>> _disconnectRelaySocket() async {
    final network = _networkService;
    _nativeRelayActive = false;
    if (network == null) {
      _relayConnectionState = RelayConnectionState.disconnected;
      return const NetworkSuccess<void>(null);
    }
    final result = await network.disconnectRelay();
    if (result is NetworkSuccess<void>) {
      _relayConnectionState = RelayConnectionState.disconnected;
      _relayError = null;
    }
    return result;
  }

  bool _isValidRelayEndpoint(Uri endpoint) =>
      endpoint.scheme == 'https' &&
      endpoint.host.isNotEmpty &&
      endpoint.userInfo.isEmpty &&
      endpoint.query.isEmpty &&
      endpoint.fragment.isEmpty &&
      (endpoint.path.isEmpty || endpoint.path == '/');

  /// 观察从 App Shell 传入的 Relay endpoint 变化。
  void _onAppSettingsChanged() {
    final endpoint = appSettings.relayEndpoint;
    if (_observedRelayEndpoint == endpoint) return;
    final previous = _observedRelayEndpoint;
    _observedRelayEndpoint = endpoint;
    if (_applyingRelayEndpoint || previous.isEmpty) return;
    unawaited(_handleExternalRelayEndpointChange());
  }

  /// 外部修改 endpoint 时撤销旧 socket 和旧 credential，强制重新 enrollment。
  Future<void> _handleExternalRelayEndpointChange() async {
    _stopRelayReconnect();
    _relayReconnectEnabled = false;
    _relayExplicitlyDisconnected = true;
    await _waitForRelayConnect();
    await _disconnectRelaySocket();
    await _relayEnrollmentService?.clearEnrollment();
    _relayEnrolled = false;
    _relayError = null;
    if (!_disposed) notifyListeners();
  }

  /// 应用原生 Relay 的类型化生命周期事件，并安排有限次数自动重连。
  void _handleNetworkEvent(NetworkEvent event) {
    if (event is! RelayStateChanged) return;
    _relayConnectionState = event.state;
    _relayError = event.error;
    _nativeRelayActive = event.state == RelayConnectionState.connected;
    if (event.state == RelayConnectionState.connected) {
      _relayReconnectAttempt = 0;
      _relayReconnectTimer?.cancel();
      _relayReconnectTimer = null;
      _relayError = null;
    } else if (event.state == RelayConnectionState.failed ||
        event.state == RelayConnectionState.disconnected) {
      _nativeRelayActive = false;
      if (_relayReconnectEnabled &&
          !_relayExplicitlyDisconnected &&
          _relayEnrolled) {
        _scheduleRelayReconnect();
      }
    }
    if (!_disposed) notifyListeners();
  }

  /// 安排 1/2/4/8/16/30 秒退避，最多尝试六次。
  void _scheduleRelayReconnect() {
    const delays = <Duration>[
      Duration(seconds: 1),
      Duration(seconds: 2),
      Duration(seconds: 4),
      Duration(seconds: 8),
      Duration(seconds: 16),
      Duration(seconds: 30),
    ];
    if (_relayReconnectTimer != null ||
        !_relayReconnectEnabled ||
        _relayExplicitlyDisconnected ||
        !_relayEnrolled ||
        _relayReconnectAttempt >= delays.length ||
        _relayConnectionState == RelayConnectionState.connected ||
        _relayConnectionState == RelayConnectionState.connecting) {
      return;
    }
    final delay = delays[_relayReconnectAttempt];
    _relayReconnectAttempt++;
    _relayReconnectTimer = Timer(delay, () {
      _relayReconnectTimer = null;
      if (_relayReconnectEnabled && !_relayExplicitlyDisconnected) {
        unawaited(_connectConfiguredRelay());
      }
    });
    if (!_disposed) notifyListeners();
  }

  /// 取消自动重连并重置退避计数。
  void _stopRelayReconnect() {
    _relayReconnectTimer?.cancel();
    _relayReconnectTimer = null;
    _relayReconnectAttempt = 0;
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
      _observedRelayEndpoint = appSettings.relayEndpoint;
      appSettings.addListener(_onAppSettingsChanged);
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
      appSettings.removeListener(_onAppSettingsChanged);
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
      _networkEventSubscription = network.events.listen(_handleNetworkEvent);
      _connectConfiguredRelayInBackground();
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
    if (endpoint == null || !_isValidRelayEndpoint(endpoint)) return;
    _relayReconnectEnabled = true;
    _relayExplicitlyDisconnected = false;
    unawaited(_connectConfiguredRelayInBackgroundAsync());
  }

  Future<void> _connectConfiguredRelayInBackgroundAsync() async {
    try {
      final result = await _connectConfiguredRelay();
      if (result is NetworkFailure<void>) {
        logger.warning(
          'Configured Relay connection failed',
          details: result.error.toString(),
        );
      }
    } on Object catch (error, stackTrace) {
      logger.warning(
        'Configured Relay connection failed',
        details: '$error\n$stackTrace',
      );
    }
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
    _relayConnectionState = RelayConnectionState.disconnected;
    await _networkEventSubscription?.cancel();
    _networkEventSubscription = null;
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
    _stopRelayReconnect();
    _relayReconnectEnabled = false;
    _relayExplicitlyDisconnected = true;
    appSettings.removeListener(_onAppSettingsChanged);
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
