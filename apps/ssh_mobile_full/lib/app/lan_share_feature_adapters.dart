// LAN Share Feature 的 App Shell 适配层。
//
// 旧 App Service 和 Network Protocol V2 网络实现仍由 AppRuntime 持有；本文件只把
// 它们转换为 Feature 的公开 Port/Contract，不把实现反向带入 Package。

import 'package:feature_lan_share/feature_lan_share.dart' as lan;
import 'package:flutter/foundation.dart';
import 'package:network_sdk/network_sdk.dart' as sdk;
import 'package:network_transport/network_transport.dart';

import '../core/services/data_protection_service.dart';
import '../services/app_log_service.dart';
import '../services/app_settings.dart';
import '../services/network/network_identity_service.dart';
import '../services/network/network_service.dart';

/// 将旧 AppSettings 适配为 LAN Feature 的最小设置 Port。
final class AppLanShareSettingsAdapter extends ChangeNotifier
    implements lan.LanShareSettingsPort {
  /// 创建不拥有旧 AppSettings 的适配器。
  AppLanShareSettingsAdapter(this._settings) {
    _settings.addListener(_forwardChange);
  }

  final AppSettings _settings;
  bool _disposed = false;

  @override
  lan.LanShareLanguage get language => switch (_settings.language) {
    AppLanguage.zh => lan.LanShareLanguage.zh,
    AppLanguage.en => lan.LanShareLanguage.en,
  };

  @override
  bool get isEnglish => _settings.isEnglish;

  @override
  lan.LanShareStrings get strings =>
      AppLanShareStrings(AppStrings(_settings.language));

  @override
  String get lanDeviceId => _settings.lanDeviceId;

  @override
  String get lanDeviceAlias => _settings.lanDeviceAlias;

  @override
  String get relayEndpoint => _settings.relayEndpoint;

  @override
  String get relayHost => _settings.relayHost;

  @override
  int get relayPort => _settings.relayPort;

  /// 当前版本保持原有行为，后台 LAN Receiver 默认开启。
  @override
  bool get receiverEnabled => true;

  @override
  Future<void> ensureLanIdentity() => _settings.ensureLanIdentity();

  @override
  Future<void> setLanDeviceAlias(String alias) =>
      _settings.setLanDeviceAlias(alias);

  @override
  Future<void> setRelayEndpoint(String endpoint) =>
      _settings.setRelayEndpoint(endpoint);

  @override
  Future<void> setRelayServer({required String host, required int port}) =>
      _settings.setRelayServer(host: host, port: port);

  void _forwardChange() {
    if (!_disposed) notifyListeners();
  }

  /// 只解除监听，不释放 AppSettings。
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _settings.removeListener(_forwardChange);
    super.dispose();
  }
}

/// 将 AppSettings 的完整文案对象限制为 LAN Feature 所需接口。
final class AppLanShareStrings implements lan.LanShareStrings {
  /// 使用当前语言的旧文案快照创建适配器。
  const AppLanShareStrings(this._strings);

  final AppStrings _strings;

  @override
  bool get isEnglish => _strings.isEnglish;

  @override
  String get accept => _strings.accept;
  @override
  String get cancel => _strings.cancel;
  @override
  String get close => _strings.close;
  @override
  String get connected => _strings.connected;
  @override
  String get copy => _strings.copy;
  @override
  String get disconnected => _strings.disconnected;
  @override
  String get delete => _strings.delete;
  @override
  String get deleteConnectionConfirm => _strings.deleteConnectionConfirm;
  @override
  String get externalPreviewContentBlocked =>
      _strings.externalPreviewContentBlocked;
  @override
  String get filePreviewRenderFailed => _strings.filePreviewRenderFailed;
  @override
  String get filePreviewRenderFailedHint =>
      _strings.filePreviewRenderFailedHint;
  @override
  String get filePreviewResourceLimit => _strings.filePreviewResourceLimit;
  @override
  String get filePreviewResourceLimitHint =>
      _strings.filePreviewResourceLimitHint;
  @override
  String get filePreviewTooLarge => _strings.filePreviewTooLarge;
  @override
  String filePreviewTooLargeHint(int maxBytes) =>
      _strings.filePreviewTooLargeHint(maxBytes);
  @override
  String get hostAddress => _strings.hostAddress;
  @override
  String get htmlPreviewUnavailable => _strings.htmlPreviewUnavailable;
  @override
  String get htmlPreviewUnavailableHint => _strings.htmlPreviewUnavailableHint;
  @override
  String get imagePreviewLabel => _strings.imagePreviewLabel;
  @override
  String get invalidPort => _strings.invalidPort;
  @override
  String get loadingFilePreview => _strings.loadingFilePreview;
  @override
  String get moreActions => _strings.moreActions;
  @override
  String networkIncomingTransferDescription(
    String senderId,
    String fileName,
    String fileSize,
  ) =>
      _strings.networkIncomingTransferDescription(senderId, fileName, fileSize);
  @override
  String get networkIncomingTransferTitle =>
      _strings.networkIncomingTransferTitle;
  @override
  String get port => _strings.port;
  @override
  String get reject => _strings.reject;
  @override
  String get retry => _strings.retry;
  @override
  String get save => _strings.save;
  @override
  String get unknown => _strings.unknown;
  @override
  String get unsupportedPreview => _strings.unsupportedPreview;
  @override
  String get unsupportedPreviewTitle => _strings.unsupportedPreviewTitle;
  @override
  String get lanCameraPermission => _strings.lanCameraPermission;
  @override
  String get lanDeviceAlias => _strings.lanDeviceAlias;
  @override
  String get lanDeviceId => _strings.lanDeviceId;
  @override
  String get lanNotificationPermission => _strings.lanNotificationPermission;
  @override
  String get lanPermissions => _strings.lanPermissions;
  @override
  String get lanRelayClear => _strings.lanRelayClear;
  @override
  String get lanRelayConnect => _strings.lanRelayConnect;
  @override
  String get lanRelayConnecting => _strings.lanRelayConnecting;
  @override
  String get lanRelayDisconnect => _strings.lanRelayDisconnect;
  @override
  String get lanRelayEnrollmentRequired => _strings.lanRelayEnrollmentRequired;
  @override
  String get lanRelayEnrollmentToken => _strings.lanRelayEnrollmentToken;
  @override
  String get lanRelayEnrollmentTokenHint =>
      _strings.lanRelayEnrollmentTokenHint;
  @override
  String get lanRelayFailed => _strings.lanRelayFailed;
  @override
  String get lanRelayServer => _strings.lanRelayServer;
  @override
  String get lanRouteDirect => _strings.lanRouteDirect;
  @override
  String get lanRouteRelay => _strings.lanRouteRelay;
  @override
  String get lanRouteUnknown => _strings.lanRouteUnknown;
  @override
  String get lanShare => _strings.lanShare;
  @override
  String get lanShareChatInputHint => _strings.lanShareChatInputHint;
  @override
  String get lanShareClearChatHistory => _strings.lanShareClearChatHistory;
  @override
  String get lanShareClipboard => _strings.lanShareClipboard;
  @override
  String get lanShareCopyAll => _strings.lanShareCopyAll;
  @override
  String get lanShareDeleteMessage => _strings.lanShareDeleteMessage;
  @override
  String get lanShareDeviceList => _strings.lanShareDeviceList;
  @override
  String get lanShareDeviceOfflineHint => _strings.lanShareDeviceOfflineHint;
  @override
  String get lanShareDragDropHint => _strings.lanShareDragDropHint;
  @override
  String get lanShareExport => _strings.lanShareExport;
  @override
  String get lanShareFileExpired => _strings.lanShareFileExpired;
  @override
  String get lanShareForgetConfirm => _strings.lanShareForgetConfirm;
  @override
  String get lanShareForgetConfirmMessage =>
      _strings.lanShareForgetConfirmMessage;
  @override
  String get lanShareForgetDevice => _strings.lanShareForgetDevice;
  @override
  String get lanShareInitializationFailed =>
      _strings.lanShareInitializationFailed;
  @override
  String get lanShareInvalidAddress => _strings.lanShareInvalidAddress;
  @override
  String get lanShareNoDevices => _strings.lanShareNoDevices;
  @override
  String get lanShareNoDevicesRefreshHint =>
      _strings.lanShareNoDevicesRefreshHint;
  @override
  String get lanShareNoHistory => _strings.lanShareNoHistory;
  @override
  String get lanShareOffline => _strings.lanShareOffline;
  @override
  String get lanShareOfflineReauthHint => _strings.lanShareOfflineReauthHint;
  @override
  String get lanShareOnline => _strings.lanShareOnline;
  @override
  String get lanShareOpenBrowser => _strings.lanShareOpenBrowser;
  @override
  String get lanSharePinMismatch => _strings.lanSharePinMismatch;
  @override
  String get lanSharePinPairing => _strings.lanSharePinPairing;
  @override
  String get lanSharePinPrompt => _strings.lanSharePinPrompt;
  @override
  String get lanShareRadarHint => _strings.lanShareRadarHint;
  @override
  String get lanShareRadarStoppedHint => _strings.lanShareRadarStoppedHint;
  @override
  String get lanShareReauthenticate => _strings.lanShareReauthenticate;
  @override
  String get lanShareRecall => _strings.lanShareRecall;
  @override
  String get lanShareRecalled => _strings.lanShareRecalled;
  @override
  String get lanShareSavedToDownloads => _strings.lanShareSavedToDownloads;
  @override
  String get lanShareSavedToGallery => _strings.lanShareSavedToGallery;
  @override
  String get lanShareSaveFailed => _strings.lanShareSaveFailed;
  @override
  String get lanShareScan => _strings.lanShareScan;
  @override
  String get lanShareScanning => _strings.lanShareScanning;
  @override
  String get lanShareScanOrAdd => _strings.lanShareScanOrAdd;
  @override
  String get lanShareScanQrCode => _strings.lanShareScanQrCode;
  @override
  String get lanShareSelectFile => _strings.lanShareSelectFile;
  @override
  String get lanShareSelectImage => _strings.lanShareSelectImage;
  @override
  String get lanShareSelectToCopy => _strings.lanShareSelectToCopy;
  @override
  String get lanShareSelectVideo => _strings.lanShareSelectVideo;
  @override
  String get lanShareSendToNearby => _strings.lanShareSendToNearby;
  @override
  String get lanShareSettings => _strings.lanShareSettings;
  @override
  String get lanShareTransferHistory => _strings.lanShareTransferHistory;
  @override
  String get lanShareWebShare => _strings.lanShareWebShare;
  @override
  String get lanShareWebShareHint => _strings.lanShareWebShareHint;
}

/// 将 AppLogService 适配为 LAN Logger Port。
final class AppLanShareLoggerAdapter implements lan.LanShareLoggerPort {
  /// 创建不拥有日志 Service 的适配器。
  const AppLanShareLoggerAdapter(this._logger);

  final AppLogService _logger;

  @override
  void info(String message, {String? details}) =>
      _logger.info(message, details: details);

  @override
  void warning(String message, {String? details}) =>
      _logger.warning(message, details: details);

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) => _logger.error(
    message,
    error: error,
    stackTrace: stackTrace,
    details: details,
  );
}

/// 将旧数据保护服务适配为 LAN 历史字段保护 Port。
final class AppLanShareDataProtectionAdapter
    implements lan.LanShareDataProtectionPort {
  /// 创建不拥有数据保护服务的适配器。
  const AppLanShareDataProtectionAdapter(this._service);

  final DataProtectionService _service;

  @override
  Future<String> encryptString(String value) => _service.encryptString(value);

  @override
  Future<String> decryptString(String value) => _service.decryptString(value);

  @override
  bool isEncrypted(String value) => _service.isEncrypted(value);
}

/// 将旧 QUIC 身份 Service 适配为 Feature Port。
final class AppLanShareNetworkIdentityAdapter
    implements lan.LanShareNetworkIdentityPort {
  /// 创建不拥有旧身份 Service 的适配器。
  const AppLanShareNetworkIdentityAdapter(this._service);

  final NetworkIdentityService _service;

  @override
  Future<lan.LanShareNetworkIdentityMaterial> loadOrCreate() async {
    final material = await _service.loadOrCreate();
    return lan.LanShareNetworkIdentityMaterial(
      privateSeed: material.privateSeed,
      publicKey: material.publicKey,
    );
  }
}

/// 在 App Shell 创建 [sdk.NetworkFacade]，并隐藏底层 FFI/gateway 具体类型。
///
/// Facade 包装一个基于共享 [NetworkRuntime] gateway 的 [NativeNetworkService]
/// 和 App Scope [RealtimeClient]；业务只消费 [sdk.NetworkFacade] 高层操作。
final class AppLanShareNetworkFactory implements lan.LanShareNetworkFactory {
  /// 创建只使用 AppRuntime-owned NetworkRuntime 与 RealtimeClient 的网络工厂。
  const AppLanShareNetworkFactory(this._networkRuntime, this._realtimeClient);

  final NetworkRuntime _networkRuntime;
  final sdk.RealtimeClient _realtimeClient;

  @override
  Future<sdk.NetworkFacade?> create({
    required String deviceId,
    required Uint8List identityPrivateKey,
    required Uint8List e2ePrivateKey,
    required String listenAddress,
    required String receiveDirectory,
  }) async {
    final gateway = await _networkRuntime.openCommandGateway();
    final sessions = NativeNetworkService.fromGateway(gateway);
    return sdk.NetworkFacadeImpl(sessions: sessions, realtime: _realtimeClient);
  }
}
