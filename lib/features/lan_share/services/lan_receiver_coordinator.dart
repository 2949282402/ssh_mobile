import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';
import '../../../services/app_settings.dart';
import '../../../services/storage_service.dart';
import '../../../services/lan_share/lan_discovery_service.dart';
import '../../../services/lan_share/lan_security_service.dart';
import '../../../services/lan_share/lan_storage_service.dart';
import '../../../services/lan_share/lan_transfer_service.dart';
import '../../../services/lan_share/lan_share_models.dart';
import '../../../services/relay/relay_client.dart';
import '../../../services/relay/relay_models.dart';
import '../../../services/relay/relay_transport.dart';
import '../../../utils/startup_instrumentation.dart';
import '../viewmodels/lan_share_viewmodel.dart';

/// 负责 LAN 后台接收器（HTTPS 接收端口、mDNS 广播、配对事件监听等）的全局生命周期。
/// 不触发 UI Isolate 上的全量历史 watch 和扫描，使冷启动更加轻量。
class LanReceiverCoordinator extends ChangeNotifier {
  final StorageService storageService;
  final AppSettings appSettings;

  LanDiscoveryService? _discoveryService;
  LanSecurityService? _securityService;
  LanStorageService? _lanStorageService;
  LanTransferService? _transferService;
  RelayClient? _relayClient;
  RelayTransport? _relayTransport;

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
  });

  bool get initialized => _initialized;
  LanDiscoveryService? get discoveryService => _discoveryService;
  LanSecurityService? get securityService => _securityService;
  LanStorageService? get lanStorageService => _lanStorageService;
  LanTransferService? get transferService => _transferService;
  RelayClient? get relayClient => _relayClient;
  RelayTransport? get relayTransport => _relayTransport;

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
      final relayClient = RelayClient(
        currentDeviceId: deviceId,
        securityService: security,
      );
      transfer = LanTransferService(
        currentDeviceId: deviceId,
        securityService: security,
        storageService: lanStorage,
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

      final boundPort = await transfer.startListening();
      await discovery.startAdvertising(port: boundPort);

      _discoveryService = discovery;
      _securityService = security;
      _lanStorageService = lanStorage;
      _transferService = transfer;
      _relayClient = relayClient;
      _relayTransport = RelayTransport(
        client: relayClient,
        securityService: security,
      );
      final relayEndpoint = Uri.tryParse(appSettings.relayEndpoint);
      if (relayEndpoint != null && relayEndpoint.hasScheme) {
        unawaited(
          relayClient
              .connect(RelaySettings(endpoint: relayEndpoint))
              .catchError((_) {}),
        );
      }
      _initialized = true;
      notifyListeners();
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

  @override
  void dispose() {
    _disposed = true;
    _viewModel?.dispose();
    unawaited(_cancelReceiverSubscriptions());
    _pairingRequestController.close();
    _transferService?.dispose();
    unawaited(_relayClient?.dispose() ?? Future<void>.value());
    _discoveryService?.dispose();
    super.dispose();
  }
}
