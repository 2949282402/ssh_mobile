// 协调唯一 v1 LAN 接收器、原生运行时、发现服务和功能 ViewModel 生命周期。

import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../../services/app_log_service.dart';
import '../../../services/app_settings.dart';
import '../../../services/storage_service.dart';
import '../../../services/lan_share/lan_discovery_service.dart';
import '../../../services/lan_share/lan_security_service.dart';
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/network/network_identity_service.dart';
import '../../../services/network/network_models.dart';
import '../../../services/network/network_service.dart';
import '../../../services/relay/relay_enrollment_service.dart';
import '../../../utils/startup_instrumentation.dart';
import '../viewmodels/lan_share_viewmodel.dart';
import 'package:ssh_mobile_network_native/ssh_mobile_network_native.dart';

/// 负责 LAN 后台接收器（HTTPS 接收端口、mDNS 广播、配对事件监听等）的全局生命周期。
/// 不触发 UI Isolate 上的全量历史 watch 和扫描，使冷启动更加轻量。
class LanReceiverCoordinator extends ChangeNotifier {
  final StorageService storageService;
  final AppSettings appSettings;
  @visibleForTesting
  final bool initializeNetwork;

  LanDiscoveryService? _discoveryService;
  LanSecurityService? _securityService;
  LanStorageService? _lanStorageService;
  LanTransferService? _transferService;
  RelayEnrollmentService? _relayEnrollmentService;
  NativeNetworkService? _networkService;
  bool _nativeRelayActive = false;

  final StreamController<LanPairingRequest> _pairingRequestController =
      StreamController<LanPairingRequest>.broadcast();
  final Map<String, LanPairingRequest> _latestPairingRequests = {};
  StreamSubscription<LanPairingRequest>? _pairingInviteSubscription;
  StreamSubscription<LanDevice>? _announcedDeviceSubscription;
  StreamSubscription<LanDevice>? _handshakePendingSubscription;

  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initFuture;
  LanShareViewModel? _viewModel;
  Future<LanShareViewModel>? _viewModelFuture;

  /// 创建应用范围的 LAN 接收器协调器。
  LanReceiverCoordinator({
    required this.storageService,
    required this.appSettings,
    @visibleForTesting this.initializeNetwork = true,
  });

  /// 接收器资源是否已完成初始化。
  bool get initialized => _initialized;

  /// 初始化完成后返回共享发现服务。
  LanDiscoveryService? get discoveryService => _discoveryService;

  /// 初始化完成后返回共享 LAN 安全服务。
  LanSecurityService? get securityService => _securityService;

  /// 初始化完成后返回共享 LAN 存储服务。
  LanStorageService? get lanStorageService => _lanStorageService;

  /// 初始化完成后返回唯一 LAN 传输服务。
  LanTransferService? get transferService => _transferService;

  /// 初始化完成后返回仅负责 enrollment 的 Relay 服务。
  RelayEnrollmentService? get relayEnrollmentService => _relayEnrollmentService;

  /// 当前是否已启用原生 Relay 配置。
  bool get nativeRelayActive => _nativeRelayActive;

  /// 可用时返回共享原生网络服务。
  NetworkService? get networkService => _networkService;

  /// 接收器初始化后发布原生传入传输申请。
  Stream<IncomingTransferOfferEvent> get nativeIncomingTransferOffers async* {
    await ensureInitialized();
    final network = _networkService;
    if (network == null) return;
    yield* network.events
        .where((event) => event is IncomingTransferOfferEvent)
        .cast<IncomingTransferOfferEvent>();
  }

  /// 校验设备配对后接受一个原生传入传输。
  Future<NetworkResult<void>> acceptNativeIncomingTransfer(
    IncomingTransferOfferEvent offer,
  ) async {
    await ensureInitialized();
    await ensureViewModel();
    final network = _networkService;
    if (network == null) {
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'native network runtime is unavailable',
          operation: NetworkOperation.respondToIncoming,
        ),
      );
    }
    if (!await _securityService!.isDevicePaired(offer.peerId)) {
      await network.respondToIncoming(
        transferId: offer.transferId,
        accept: false,
      );
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.authenticationFailed,
          message: 'incoming transfer peer is no longer paired',
          operation: NetworkOperation.respondToIncoming,
        ),
      );
    }
    _transferService!.handleIncomingMessageFromWeb(
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
    IncomingTransferOfferEvent offer,
  ) async {
    await ensureInitialized();
    final network = _networkService;
    if (network == null) {
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'native network runtime is unavailable',
          operation: NetworkOperation.respondToIncoming,
        ),
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
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.relayError,
          message: 'Relay enrollment service is unavailable',
          operation: NetworkOperation.enrollRelay,
        ),
      );
    }
    final relaySettings = RelaySettings(endpoint: endpoint);
    final enrollment = await client.enroll(relaySettings, enrollmentToken);
    if (enrollment is NetworkFailure<void>) {
      return enrollment;
    }
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
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.relayError,
          message: 'Relay configuration is unavailable',
          operation: NetworkOperation.connectRelay,
        ),
      );
    }
    final settings = RelaySettings(endpoint: endpoint);
    if (!await client.isEnrolled(settings)) {
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.authenticationFailed,
          message: 'Relay enrollment is required',
          operation: NetworkOperation.connectRelay,
        ),
      );
    }
    final result = await _connectRelay(settings);
    if (result is NetworkSuccess<void>) notifyListeners();
    return result;
  }

  /// 将 enrollment 凭据转换为原生 Relay 配置。
  Future<NetworkResult<void>> _connectRelay(RelaySettings settings) async {
    final client = _relayEnrollmentService;
    final network = _networkService;
    if (client == null || network == null) {
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.noRoute,
          message: 'native network runtime is unavailable',
          operation: NetworkOperation.connectRelay,
        ),
      );
    }
    final configuration = await client.nativeConfiguration(settings);
    if (configuration == null) {
      return const NetworkFailure(
        NetworkError(
          code: NetworkErrorCode.authenticationFailed,
          message: 'Relay enrollment is required',
          operation: NetworkOperation.connectRelay,
        ),
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
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit();
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
        historyDao: storageService.appDatabase.lanHistoryDao,
        appSettings: appSettings,
        ownsRuntime: false,
        pairingRequestPublisher: publishPairingRequest,
      );
      await viewModel.initialize();
      if (_disposed) {
        throw StateError('LAN receiver coordinator is disposed.');
      }
      for (final request in _latestPairingRequests.values) {
        if (!request.isExpired) {
          viewModel.registerManualDevice(request.device);
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

  /// 创建接收器服务并启动 LAN 监听；按需启动原生运行时，
  /// 不将预期网络失败转换为编程异常。
  Future<void> _doInit() async {
    LanDiscoveryService? discovery;
    LanTransferService? transfer;
    try {
      StartupInstrumentation.instance.recordServiceInitialized(
        'LanReceiverCoordinator',
      );
      await appSettings.ensureLanIdentity();
      final deviceId = appSettings.lanDeviceId;
      final deviceAlias = appSettings.lanDeviceAlias;

      discovery = LanDiscoveryService(
        currentDeviceId: deviceId,
        currentDeviceAlias: deviceAlias,
      );
      final security = LanSecurityService();
      final lanStorage = LanStorageService();
      final networkIdentity = initializeNetwork
          ? await NetworkIdentityService().loadOrCreate()
          : null;
      final relayEnrollmentService = RelayEnrollmentService(
        currentDeviceId: deviceId,
      );
      transfer = LanTransferService(
        currentDeviceId: deviceId,
        securityService: security,
        storageService: lanStorage,
        networkIdentityPublicKeyProvider: networkIdentity == null
            ? null
            : () async => networkIdentity.publicKey,
      );

      _pairingInviteSubscription = transfer.pairingInviteStream.listen(
        publishPairingRequest,
      );
      _announcedDeviceSubscription = transfer.announcedDeviceStream.listen(
        _publishIncomingDevice,
      );
      _handshakePendingSubscription = transfer.handshakePendingStream.listen(
        _publishIncomingDevice,
      );

      if (security.activePin == null) {
        security.generate6DigitPin();
      }

      int? boundPort;
      if (initializeNetwork) {
        final listenerResult = await transfer.startListening();
        if (listenerResult is NetworkFailure<int>) {
          AppLogService.instance.warning(
            'LAN listener failed',
            details: listenerResult.error.toString(),
          );
        } else {
          boundPort = (listenerResult as NetworkSuccess<int>).data;
          final advertisingResult = await discovery.startAdvertising(
            port: boundPort,
          );
          if (advertisingResult is NetworkFailure<void>) {
            AppLogService.instance.warning(
              'LAN advertising failed',
              details: advertisingResult.error.toString(),
            );
          }
        }
      }

      _discoveryService = discovery;
      _securityService = security;
      _lanStorageService = lanStorage;
      _transferService = transfer;
      _relayEnrollmentService = relayEnrollmentService;
      if (initializeNetwork && boundPort != null) {
        NativeNetworkRuntime? nativeRuntime;
        NativeNetworkService? networkService;
        try {
          nativeRuntime = await const SshMobileNetworkNative().createRuntime();
          networkService = NativeNetworkService(nativeRuntime);
          final startResult = await networkService.start(
            NetworkRuntimeConfig(
              deviceId: deviceId,
              identityPrivateKey: networkIdentity!.privateSeed,
              e2ePrivateKey: await security.getStaticX25519PrivateKeyBytes(),
              listenAddress: '0.0.0.0:$boundPort',
              receiveDirectory: (await lanStorage.getSandboxDirectory()).path,
            ),
          );
          if (startResult is NetworkFailure<void>) {
            AppLogService.instance.warning(
              'Native network runtime configuration failed',
              details: startResult.error.toString(),
            );
            await networkService.dispose();
            networkService = null;
            nativeRuntime = null;
          } else {
            _networkService = networkService;
          }
        } on Object catch (error, stackTrace) {
          await networkService?.dispose();
          await nativeRuntime?.dispose();
          _networkService = null;
          AppLogService.instance.warning(
            'Native QUIC runtime initialization failed',
            details: '$error\n$stackTrace',
          );
        }
      }
      _initialized = true;
      notifyListeners();
      if (initializeNetwork) {
        final relayEndpoint = Uri.tryParse(appSettings.relayEndpoint);
        if (relayEndpoint != null && relayEndpoint.hasScheme) {
          unawaited(
            _connectRelay(RelaySettings(endpoint: relayEndpoint))
                .then((_) => notifyListeners())
                .catchError((Object error, StackTrace stackTrace) {
                  AppLogService.instance.warning(
                    'Configured Relay connection failed',
                    details: '$error\n$stackTrace',
                  );
                }),
          );
        }
      }
    } catch (e) {
      await _cancelReceiverSubscriptions();
      await transfer?.stopListening();
      discovery?.dispose();
      transfer?.dispose();
      _initFuture = null;
      rethrow;
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

  /// 销毁原生网络、Relay enrollment 和传输资源。
  Future<void> _disposeTransferRuntime() async {
    await _networkService?.dispose();
    _networkService = null;
    _nativeRelayActive = false;
    _transferService?.dispose();
    await _relayEnrollmentService?.dispose();
    _relayEnrollmentService = null;
  }

  /// 销毁协调器及全部应用范围的接收器资源。
  @override
  void dispose() {
    _disposed = true;
    _viewModel?.dispose();
    unawaited(_cancelReceiverSubscriptions());
    _pairingRequestController.close();
    unawaited(_disposeTransferRuntime());
    _discoveryService?.dispose();
    super.dispose();
  }
}
