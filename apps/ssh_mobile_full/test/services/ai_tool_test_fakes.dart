part of 'ai_tool_service_test.dart';

AiToolService _buildTools({
  required TestStorageAdapter storage,
  required SshClientAdapter ssh,
  required SftpClientAdapter sftp,
  required ClientSystemToolAdapter clientSystem,
  required ClientWebViewAdapter clientWebView,
  required ServerCatalogAdapter serverCatalog,
  required ai.AiMonitoringPort performanceMonitor,
  required ServerDiagnosticsAdapter diagnostics,
  required AppSettings appSettings,
  String? chatId,
}) {
  return createAiToolServiceFromLegacy(
    storageService: storage,
    sshService: ssh,
    sftpService: sftp,
    clientSystemToolService: clientSystem,
    clientWebViewService: clientWebView,
    serverCatalogService: serverCatalog,
    performanceMonitorToolService: performanceMonitor,
    serverDiagnosticsService: diagnostics,
    appSettings: appSettings,
    clientWebViewSessionId: chatId,
  );
}

class _FakeSshClient implements SshClientAdapter {
  final SshSession session;
  int ensureCalls = 0;

  _FakeSshClient(this.session);

  @override
  List<SshSession> get sessions => [session];

  @override
  SshSession? getSession(String sessionId) {
    return session.id == sessionId ? session : null;
  }

  @override
  Future<bool> ensureSessionConnected(
    String sessionId,
    String connectionId,
  ) async {
    ensureCalls += 1;
    return session.id == sessionId && session.connectionId == connectionId;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeClientSystemToolService implements ClientSystemToolAdapter {
  String? lastQueryLevel;
  String? lastQueryContains;
  int? lastQueryLimit;
  String? lastSavedFileName;
  List<int>? lastSavedBytes;
  String? lastSaveDialogTitle;
  bool cancelNextSave = false;
  bool getLogCountsCalled = false;
  List<int>? deletedLogIds;
  bool clearLogsCalled = false;
  ClientPickedFile? nextPickedFile;
  Map<String, dynamic>? networkInfo;
  Map<String, dynamic>? batteryStatus;
  Map<String, dynamic>? permissionStatus;

  @override
  Map<String, dynamic> getClientTime() => {'execution': 'client'};

  @override
  Map<String, dynamic> getClientDeviceInfo() => {'execution': 'client'};

  @override
  Future<Map<String, dynamic>> getNetworkInfo() async =>
      networkInfo ??
      {
        'execution': 'client',
        'target': 'client_device',
        'supported': true,
        'connected': true,
        'validated': true,
      };

  @override
  Future<Map<String, dynamic>> getBatteryStatus() async =>
      batteryStatus ??
      {
        'execution': 'client',
        'target': 'client_device',
        'supported': true,
        'batteryPercent': 80,
        'powerSaveMode': false,
        'ignoringBatteryOptimizations': true,
        'plugged': {'ac': false, 'usb': false, 'wireless': false},
      };

  @override
  Future<Map<String, dynamic>> getPermissionStatus() async =>
      permissionStatus ??
      {
        'execution': 'client',
        'target': 'client_device',
        'notificationGranted': true,
        'supportsNativeBackgroundService': true,
        'supportsBatteryOptimizationExemption': true,
        'ignoringBatteryOptimizations': true,
      };

  @override
  Future<Map<String, dynamic>> openAppSettings() async => {
    'execution': 'client',
    'opened': true,
  };

  @override
  Future<Map<String, dynamic>> setClipboard(String text) async => {
    'execution': 'client',
    'updated': true,
    'textLength': text.length,
  };

  @override
  Future<Map<String, dynamic>> setAlarm({
    String? triggerAt,
    int? delaySeconds,
    int? delayMinutes,
    String? label,
    bool useSystemAlarm = true,
  }) async => {'execution': 'client', 'created': true};

  @override
  Future<Map<String, dynamic>> listAlarms() async => {
    'execution': 'client',
    'alarms': const [],
  };

  @override
  Future<Map<String, dynamic>> cancelAlarm(String alarmId) async => {
    'execution': 'client',
    'cancelled': true,
    'alarmId': alarmId,
  };

  @override
  Future<Map<String, dynamic>> queryLogs({
    String? level,
    String? contains,
    int limit = 50,
  }) async {
    lastQueryLevel = level;
    lastQueryContains = contains;
    lastQueryLimit = limit;
    return {
      'execution': 'client',
      'target': 'client_logs',
      'level': level ?? 'all',
      'contains': contains,
      'limit': limit,
      'matched': 1,
      'truncated': false,
      'entries': const [
        {'message': 'warning: ssh retry'},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> getLogCounts() async {
    getLogCountsCalled = true;
    return {
      'execution': 'client',
      'target': 'client_logs',
      'counts': {'all': 3, 'warning': 2, 'error': 1},
    };
  }

  @override
  Future<Map<String, dynamic>> deleteLogEntries(List<int> ids) async {
    deletedLogIds = List<int>.from(ids);
    return {
      'execution': 'client',
      'target': 'client_logs',
      'deleted': ids.length,
      'remaining': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> clearLogs() async {
    clearLogsCalled = true;
    return {
      'execution': 'client',
      'target': 'client_logs',
      'cleared': 3,
      'remaining': 0,
    };
  }

  @override
  Future<Map<String, dynamic>> saveBytesToFile({
    required String fileName,
    required List<int> bytes,
    String? dialogTitle,
  }) async {
    lastSavedFileName = fileName;
    lastSavedBytes = List<int>.from(bytes);
    lastSaveDialogTitle = dialogTitle;
    final cancelled = cancelNextSave;
    cancelNextSave = false;
    return {
      'execution': 'client',
      'target': 'client_device',
      'saved': !cancelled,
      'cancelled': cancelled,
      'localPath': cancelled ? null : 'C:/Downloads/$fileName',
      'fileName': fileName,
      'bytes': bytes.length,
      'note': cancelled
          ? 'The user cancelled the local save dialog.'
          : 'The file was saved on the client device running SSH Mobile.',
    };
  }

  @override
  Future<ClientPickedFile?> pickFile({
    List<String>? allowedExtensions,
    String? dialogTitle,
  }) async {
    final picked = nextPickedFile;
    nextPickedFile = null;
    return picked;
  }
}

class _FakeClientWebViewAdapter implements ClientWebViewAdapter {
  ClientWebViewStateSnapshot? state;
  ClientWebViewNavigationResult? navigationResult;
  String? lastStateChatId;
  String? lastNavigateChatId;
  String? lastNavigateAction;
  String? lastNavigateInput;

  @override
  Future<ClientWebViewSnapshot> readPlainText(
    String chatId, {
    int maxChars = ClientWebViewService.defaultMaxChars,
  }) async {
    return ClientWebViewSnapshot(
      chatId: chatId,
      supported: true,
      hasPage: true,
      text: 'example',
      textLength: 7,
      maxChars: maxChars,
      truncated: false,
    );
  }

  @override
  Future<ClientWebViewSearchResult> searchWeb(
    String chatId,
    String query, {
    int maxResults = 5,
    String? engine,
  }) async {
    return ClientWebViewSearchResult(
      chatId: chatId,
      supported: true,
      query: query,
      results: const [],
      engine: engine ?? 'baidu',
    );
  }

  @override
  Future<ClientWebViewStateSnapshot> getState(String chatId) async {
    lastStateChatId = chatId;
    return state ??
        ClientWebViewStateSnapshot(
          chatId: chatId,
          supported: true,
          hasPage: true,
          progress: 100,
          isLoading: false,
          isAiBrowsing: false,
          canGoBack: false,
          canGoForward: false,
          lastTextLength: 0,
          lastTextTruncated: false,
        );
  }

  @override
  Future<ClientWebViewNavigationResult> navigate(
    String chatId, {
    required String action,
    String? input,
  }) async {
    lastNavigateChatId = chatId;
    lastNavigateAction = action;
    lastNavigateInput = input;
    return navigationResult ??
        ClientWebViewNavigationResult(
          chatId: chatId,
          supported: true,
          action: action,
          input: input,
          navigated: true,
          blocked: false,
          state: await getState(chatId),
        );
  }

  @override
  void interruptAiBrowsing(String chatId) {}

  @override
  void clearSession(String chatId) {}
}

class _FakeSftpClient implements SftpClientAdapter {
  Uint8List downloadBytes = Uint8List.fromList([1, 2, 3, 4]);
  String readTextResult = 'text';
  String? lastDownloadConnectionId;
  String? lastDownloadPath;
  int? lastDownloadMaxBytes;
  String? lastWriteConnectionId;
  String? lastWritePath;
  String? lastWriteText;
  int? lastWriteMaxBytes;
  String? lastUploadConnectionId;
  String? lastUploadPath;
  Uint8List? lastUploadBytes;
  String? lastRenamePath;
  String? lastRenameNewPath;
  String? lastDeletePath;
  String? lastMkdirPath;

  @override
  String? get connectionId => null;

  @override
  String? get connectionName => null;

  @override
  String get currentPath => '.';

  @override
  SftpConnectionState get state => SftpConnectionState.disconnected;

  @override
  String? get errorMessage => null;

  @override
  int get entriesRevision => 0;

  @override
  List<SftpEntry> get entries => const [];

  @override
  bool get isConnected => false;

  @override
  bool get isBusy => false;

  @override
  bool isConnectionBusy(String connectionId) => false;

  @override
  bool isConnectionOpen(String connectionId) => false;

  @override
  Future<void> connect(String connectionId, {dynamic onUnknownHostKey}) async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> uploadBytes({
    required String filename,
    required Uint8List bytes,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<void> deleteEntry(
    SftpEntry entry, {
    required String confirmedName,
  }) async {
    throw UnimplementedError();
  }

  @override
  Future<List<SftpEntry>> listDirectoryForConnection(
    String connectionId,
    String path,
  ) async {
    return const [];
  }

  @override
  Future<String> readTextPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxTextPreviewBytes,
  }) async {
    return readTextResult;
  }

  @override
  Future<Uint8List> downloadPathForConnection({
    required String connectionId,
    required String path,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {
    lastDownloadConnectionId = connectionId;
    lastDownloadPath = path;
    lastDownloadMaxBytes = maxBytes;
    if (downloadBytes.length > maxBytes) {
      throw StateError('Download exceeds maxBytes');
    }
    return downloadBytes;
  }

  @override
  Future<SftpPathInfo> statPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    return SftpPathInfo(
      path: path,
      isDirectory: false,
      isLink: false,
      size: 4,
      sizeLabel: '4 B',
      modifiedAt: DateTime.utc(2025, 1, 1),
    );
  }

  @override
  Future<void> writeTextPathForConnection({
    required String connectionId,
    required String path,
    required String text,
    int maxBytes = SftpService.maxTextEditBytes,
  }) async {
    lastWriteConnectionId = connectionId;
    lastWritePath = path;
    lastWriteText = text;
    lastWriteMaxBytes = maxBytes;
    if (text.length > maxBytes) {
      throw StateError('Text exceeds maxBytes');
    }
  }

  @override
  Future<void> uploadBytesPathForConnection({
    required String connectionId,
    required String path,
    required Uint8List bytes,
    int maxBytes = SftpService.maxUploadBytes,
  }) async {
    lastUploadConnectionId = connectionId;
    lastUploadPath = path;
    lastUploadBytes = bytes;
  }

  @override
  Future<void> createDirectoryPathForConnection({
    required String connectionId,
    required String path,
  }) async {
    lastMkdirPath = path;
  }

  @override
  Future<void> renamePathForConnection({
    required String connectionId,
    required String path,
    required String newPath,
  }) async {
    lastRenamePath = path;
    lastRenameNewPath = newPath;
  }

  @override
  Future<void> deletePathForConnection({
    required String connectionId,
    required String path,
  }) async {
    lastDeletePath = path;
  }

  @override
  Future<void> openPath(String path) async {}

  @override
  Future<void> openParent() async {}

  @override
  Future<void> disconnect({bool notify = true}) async {}

  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) async {}

  @override
  Future<void> disconnectAll({bool notify = true}) async {}

  @override
  SftpTransferState? get activeTransfer => null;

  @override
  bool get hasActiveTransfer => false;

  @override
  void cancelActiveTransfer() {}

  @override
  Future<void> uploadFile({
    required String localPath,
    required String filename,
  }) async {}

  @override
  Future<void> downloadFile(
    SftpEntry entry, {
    required String localPath,
    int maxBytes = SftpService.maxDownloadBytes,
  }) async {}
}

class _FakeServerDiagnosticsService implements ServerDiagnosticsAdapter {
  String? lastStatusConnectionId;
  String? lastStatusMode;
  String? lastReportConnectionId;

  @override
  Future<Map<String, dynamic>> detectOs(String connectionId) async => {
    'os': 'linux',
    'method': 'saved_server_platform',
  };

  @override
  Future<Map<String, dynamic>> getStatus({
    required String connectionId,
    String? mode,
  }) async {
    lastStatusConnectionId = connectionId;
    lastStatusMode = mode;
    return {
      'connectionId': connectionId,
      'performance': {'memoryPercent': 32.0},
    };
  }

  @override
  Future<Map<String, dynamic>> generateOpsReport(String connectionId) async {
    lastReportConnectionId = connectionId;
    return {
      'connectionId': connectionId,
      'health': {'score': 92, 'level': 'healthy'},
    };
  }
}

class _GatedRemoteProvider implements AiToolProvider {
  static const toolName = 'gated_remote_write';

  final Completer<void> started = Completer<void>();
  final Completer<void> release = Completer<void>();
  int sideEffectCount = 0;

  @override
  Future<List<AiTool>> getTools(AiToolService service) async => [
    AiTool(
      name: toolName,
      description: 'Test a bound remote write.',
      properties: const {
        'connectionId': {'type': 'string'},
      },
      required: const ['connectionId'],
      requiresServerSelection: true,
      executionMode: AiToolExecutionMode.stateChanging,
      handler: (_) async => '{}',
    ),
  ];

  @override
  Future<String?> execute(
    AiToolService service,
    String name,
    Map<String, dynamic> arguments, {
    bool approvedWrite = false,
  }) async {
    if (name != toolName) return null;
    if (!started.isCompleted) started.complete();
    await release.future;
    await ai_tools.RemoteTargetScope.resolveIfBound(
      service.storageService,
      arguments['connectionId'] as String,
    );
    sideEffectCount += 1;
    return jsonEncode({'ok': true});
  }
}

class _FakeServerCatalogService implements ServerCatalogAdapter {
  String? lastDetailsConnectionId;
  Map<String, dynamic>? lastMetadataChanges;
  ConnectionConfig? lastApprovedCandidate;

  @override
  Future<Map<String, dynamic>> deleteServer(String connectionId) async => {
    'deleted': true,
    'connectionId': connectionId,
  };

  @override
  Map<String, dynamic>? getServerDetails(String connectionId) {
    lastDetailsConnectionId = connectionId;
    return {
      'server': {
        'id': connectionId,
        'name': 'Demo Server',
        'host': 'example.com',
      },
    };
  }

  @override
  List<Map<String, dynamic>> listServerSummaries() => const [
    {'id': 'server-1', 'name': 'Demo Server', 'host': 'example.com'},
  ];

  @override
  Future<Map<String, dynamic>> reorderServers(List<String> orderedIds) async =>
      {'reordered': true, 'orderedIds': orderedIds};

  @override
  Future<Map<String, dynamic>> updateServerMetadata({
    required String connectionId,
    required Map<String, dynamic> changes,
    ConnectionTargetBinding? approvedTarget,
    ConnectionConfig? approvedCurrent,
    ConnectionConfig? approvedCandidate,
  }) async {
    lastMetadataChanges = Map<String, dynamic>.from(changes);
    lastApprovedCandidate = approvedCandidate == null
        ? null
        : ConnectionConfig.fromJson(approvedCandidate.toJson());
    return {
      'updated': true,
      'server': approvedCandidate?.toJson() ?? {'id': connectionId, ...changes},
    };
  }
}

class _FakePerformanceMonitorToolService implements ai.AiMonitoringPort {
  bool getStateCalled = false;
  int startCalls = 0;
  List<String> selectedConnectionIds = [];

  @override
  Future<Map<String, dynamic>> query(app_core.MonitoringQuery request) async =>
      getState();

  @override
  Map<String, dynamic> clearSelection() {
    selectedConnectionIds = [];
    return getState();
  }

  @override
  Future<Map<String, dynamic>> getApplications(String connectionId) async => {
    'connectionId': connectionId,
    'applications': const [],
  };

  @override
  Map<String, dynamic> getAlerts({int limit = 50}) => {
    'alerts': const [],
    'limit': limit,
  };

  @override
  Map<String, dynamic> getHealth({List<String>? connectionIds}) => {
    'health': const {},
  };

  @override
  Future<Map<String, dynamic>> getPorts(String connectionId) async => {
    'connectionId': connectionId,
    'ports': const [],
  };

  @override
  Map<String, dynamic> getSamples(
    String connectionId, {
    bool visibleOnly = true,
    int limit = 100,
  }) => {
    'connectionId': connectionId,
    'visibleOnly': visibleOnly,
    'limit': limit,
    'samples': const [],
  };

  @override
  Map<String, dynamic> getState() {
    getStateCalled = true;
    return {
      'isRunning': false,
      'isSampling': false,
      'selectedConnectionIds': List<String>.of(selectedConnectionIds),
      'monitoringConnectionIds': const <String>[],
    };
  }

  @override
  Map<String, dynamic> setHistoryWindow(Duration window) => getState();

  @override
  Map<String, dynamic> setInterval(Duration interval) => getState();

  @override
  Map<String, dynamic> setSelectedServers(List<String> connectionIds) {
    selectedConnectionIds = List<String>.of(connectionIds);
    return getState();
  }

  @override
  Future<Map<String, dynamic>> start() async {
    startCalls += 1;
    return getState();
  }

  @override
  Future<Map<String, dynamic>> startWithTargets(
    Map<String, ssh_core.SshTargetBinding> targets,
  ) => start();

  @override
  Map<String, dynamic> stop() => getState();

  @override
  Map<String, dynamic> stopForConnection(String connectionId) => getState();
}
