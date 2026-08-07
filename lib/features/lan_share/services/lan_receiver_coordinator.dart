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
import '../../../services/network/transfer_transport.dart';
import '../../../services/relay/relay_client.dart';
import '../../../services/relay/relay_models.dart';
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
  RelayClient? _relayClient;
  NativeNetworkRuntime? _nativeNetworkRuntime;
  TransferTransport? _fileTransferTransport;
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

  LanReceiverCoordinator({
    required this.storageService,
    required this.appSettings,
    @visibleForTesting this.initializeNetwork = true,
  });

  bool get initialized => _initialized;
  LanDiscoveryService? get discoveryService => _discoveryService;
  LanSecurityService? get securityService => _securityService;
  LanStorageService? get lanStorageService => _lanStorageService;
  LanTransferService? get transferService => _transferService;
  RelayClient? get relayClient => _relayClient;
  bool get nativeRelayActive => _nativeRelayActive;

  Stream<NativeIncomingTransferOffer> get nativeIncomingTransferOffers async* {
    await ensureInitialized();
    final transport = _fileTransferTransport;
    if (transport is AdaptiveTransferTransport) {
      yield* transport.incomingOffers;
    }
  }

  Future<void> acceptNativeIncomingTransfer(
    NativeIncomingTransferOffer offer,
  ) async {
    await ensureInitialized();
    await ensureViewModel();
    final transport = _fileTransferTransport;
    if (transport is! AdaptiveTransferTransport) return;
    if (!await _securityService!.isDevicePaired(offer.peerId)) {
      await transport.respondToIncoming(
        transferId: offer.transferId,
        accept: false,
      );
      throw StateError('Incoming transfer peer is no longer paired.');
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
    await transport.respondToIncoming(
      transferId: offer.transferId,
      accept: true,
    );
  }

  Future<void> rejectNativeIncomingTransfer(
    NativeIncomingTransferOffer offer,
  ) async {
    await ensureInitialized();
    final transport = _fileTransferTransport;
    if (transport is AdaptiveTransferTransport) {
      await transport.respondToIncoming(
        transferId: offer.transferId,
        accept: false,
      );
    }
  }

  Future<void> enrollRelay({
    required Uri endpoint,
    required String enrollmentToken,
  }) async {
    await ensureInitialized();
    final client = _relayClient;
    if (client == null) {
      throw StateError('Relay client is unavailable.');
    }
    final relaySettings = RelaySettings(endpoint: endpoint);
    await client.enroll(relaySettings, enrollmentToken);
    await appSettings.setRelayEndpoint(endpoint.toString());
    await _connectRelay(relaySettings);
    notifyListeners();
  }

  Future<bool> connectConfiguredRelay() async {
    await ensureInitialized();
    final endpoint = Uri.tryParse(appSettings.relayEndpoint);
    final client = _relayClient;
    if (endpoint == null || client == null) return false;
    final settings = RelaySettings(endpoint: endpoint);
    if (!await client.isEnrolled(settings)) return false;
    await _connectRelay(settings);
    notifyListeners();
    return true;
  }

  Future<void> _connectRelay(RelaySettings settings) async {
    final client = _relayClient;
    if (client == null) {
      throw StateError('Relay client is unavailable.');
    }
    final transport = _fileTransferTransport;
    if (transport is AdaptiveTransferTransport) {
      final configuration = await client.nativeConfiguration(settings);
      if (configuration == null) {
        throw StateError('Relay enrollment is required.');
      }
      if (client.isConnected) {
        await client.disconnect();
      }
      await transport.configureRelay(
        relayUrl: configuration.endpoint.toString(),
        relayCredential: configuration.credential,
        relaySigningSeed: configuration.signingSeed,
      );
      _nativeRelayActive = true;
      return;
    }
    _nativeRelayActive = false;
    throw StateError('Native network runtime is unavailable.');
  }

  Stream<LanPairingRequest> get pairingRequestStream =>
      _pairingRequestController.stream;

  LanPairingRequest? pairingRequestForSession(String sessionId) {
    final request = _latestPairingRequests[sessionId];
    if (request == null || request.isExpired) return null;
    return request;
  }

  Future<void> ensureInitialized() {
    if (_disposed) {
      return Future<void>.error(
        StateError('LAN receiver coordinator is disposed.'),
      );
    }
    if (_initialized) return Future.value();
    return _initFuture ??= _doInit();
  }

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

  Future<LanShareViewModel> _createViewModel() async {
    LanShareViewModel? viewModel;
    try {
      await ensureInitialized();
      viewModel = LanShareViewModel(
        discoveryService: _discoveryService!,
        securityService: _securityService!,
        storageService: _lanStorageService!,
        transferService: _transferService!,
        fileTransferTransport: _fileTransferTransport,
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

  void publishPairingRequest(LanPairingRequest request) {
    if (_disposed || request.isExpired) return;
    _latestPairingRequests.removeWhere((_, value) => value.isExpired);
    _latestPairingRequests[request.sessionId] = request;
    _pairingRequestController.add(request);
  }

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
      final relayClient = RelayClient(
        currentDeviceId: deviceId,
        securityService: security,
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
        boundPort = await transfer.startListening();
        await discovery.startAdvertising(port: boundPort);
      }

      _discoveryService = discovery;
      _securityService = security;
      _lanStorageService = lanStorage;
      _transferService = transfer;
      _relayClient = relayClient;
      if (initializeNetwork) {
        NativeNetworkRuntime? nativeRuntime;
        QuicTransferTransport? directTransport;
        try {
          nativeRuntime = await const SshMobileNetworkNative().createRuntime();
          directTransport = QuicTransferTransport(nativeRuntime);
          await directTransport.configure(
            deviceId: deviceId,
            identityPrivateKey: networkIdentity!.privateSeed,
            e2ePrivateKey: await security.getStaticX25519PrivateKeyBytes(),
            listenAddress: '0.0.0.0:$boundPort',
            receiveDirectory: (await lanStorage.getSandboxDirectory()).path,
          );
          _nativeNetworkRuntime = nativeRuntime;
          _fileTransferTransport = AdaptiveTransferTransport(
            direct: directTransport,
          );
        } on Object catch (error, stackTrace) {
          await directTransport?.dispose();
          await nativeRuntime?.dispose();
          _fileTransferTransport = null;
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

  Future<void> _cancelReceiverSubscriptions() async {
    await _pairingInviteSubscription?.cancel();
    _pairingInviteSubscription = null;
    await _announcedDeviceSubscription?.cancel();
    _announcedDeviceSubscription = null;
    await _handshakePendingSubscription?.cancel();
    _handshakePendingSubscription = null;
  }

  Future<void> _disposeTransferRuntime() async {
    final fileTransport = _fileTransferTransport;
    if (fileTransport is AdaptiveTransferTransport) {
      await fileTransport.dispose();
    }
    await _nativeNetworkRuntime?.dispose();
    _nativeRelayActive = false;
    _transferService?.dispose();
    await _relayClient?.dispose();
  }

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
