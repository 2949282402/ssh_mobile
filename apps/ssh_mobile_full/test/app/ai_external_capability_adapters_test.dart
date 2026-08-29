// App AI external capability adapter 的确定性单元测试。

import 'dart:typed_data';

import 'package:connection_core/connection_core.dart';
import 'package:feature_ai/feature_ai.dart' as ai;
import 'package:feature_webview/feature_webview.dart' as webview;
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_core/ssh_core.dart' as ssh_core;
import 'package:ssh_mobile/app/ai_external_capability_adapters.dart';
import 'package:ssh_mobile/core/services/data_protection_service.dart';
import 'package:ssh_mobile/services/app_log_service.dart';
import 'package:ssh_mobile/services/client_system_tool_service.dart'
    as legacy_system;
import 'package:ssh_mobile/services/remote_target_scope.dart';
import 'package:ssh_mobile/services/sftp_service.dart';
import 'package:ssh_mobile/services/ssh_service.dart';

const Map<String, dynamic> _ok = <String, dynamic>{'ok': true};

const Map<String, dynamic> _permission = <String, dynamic>{
  'supported': true,
  'supportsNativeBackgroundService': true,
  'notificationGranted': true,
  'supportsBatteryOptimizationExemption': true,
  'ignoringBatteryOptimizations': true,
};

const Map<String, dynamic> _battery = <String, dynamic>{
  'supported': true,
  'batteryPercent': 80,
  'plugged': <String, dynamic>{'ac': true},
  'thermalStatus': 'cool',
};

const Map<String, dynamic> _healthyNetwork = <String, dynamic>{
  'supported': true,
  'connected': true,
  'validated': true,
};

const Map<String, dynamic> _meteredNetwork = <String, dynamic>{
  'supported': true,
  'connected': true,
  'validated': true,
  'metered': true,
};

const Map<String, dynamic> _blockedNetwork = <String, dynamic>{
  'supported': true,
  'connected': false,
};

const webview.ClientWebViewSnapshot _text = webview.ClientWebViewSnapshot(
  chatId: 'chat-1',
  supported: true,
  hasPage: true,
  text: 'hello',
  textLength: 5,
  maxChars: 100,
  truncated: false,
);

const webview.ClientWebViewSearchResult _search =
    webview.ClientWebViewSearchResult(
      chatId: 'chat-1',
      supported: true,
      query: 'query',
      results: <webview.ClientWebViewSearchItem>[
        webview.ClientWebViewSearchItem(
          title: 'Result',
          url: 'https://result.test/',
          snippet: 'snippet',
        ),
      ],
    );

const webview.ClientWebViewStateSnapshot _state =
    webview.ClientWebViewStateSnapshot(
      chatId: 'chat-1',
      supported: true,
      hasPage: true,
      progress: 42,
      isLoading: false,
      isAiBrowsing: true,
      canGoBack: true,
      canGoForward: false,
      lastTextLength: 5,
      lastTextTruncated: false,
    );

const String _procOutput =
    'cpu 100 0 0 0 0\nMemTotal: 8000000 kB\nMemAvailable: 6000000 kB\n';
const String _portsOutput =
    'LISTEN 0 128 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))\n';
const String _appsOutput = 'PID COMMAND RSS PMEM PCPU\n1 sshd 1024 1.0 0.5\n';

void main() {
  test('data protection adapter delegates encrypt and decrypt', () async {
    final adapter = AppAiDataProtectionAdapter(_FakeDataProtection());
    expect(await adapter.encrypt('plain'), 'enc');
    expect(await adapter.decrypt('stored'), 'dec');
  });

  test('client system adapter forwards every capability', () async {
    final delegate = _FakeClientSystemToolService();
    final adapter = AppAiClientSystemAdapter(delegate: delegate);

    expect(adapter.getClientTime(), _ok);
    expect(adapter.getClientDeviceInfo(), _ok);
    for (final call in <Future<Map<String, dynamic>> Function()>[
      adapter.getNetworkInfo,
      adapter.getBatteryStatus,
      adapter.getPermissionStatus,
      adapter.openAppSettings,
      adapter.listAlarms,
      adapter.getLogCounts,
      adapter.clearLogs,
    ]) {
      expect(await call(), _ok);
    }
    expect(await adapter.setClipboard('text'), _ok);
    expect(await adapter.setAlarm(label: 'label'), _ok);
    expect(await adapter.cancelAlarm('alarm-1'), _ok);
    expect(await adapter.queryLogs(limit: 10), _ok);
    expect(await adapter.deleteLogEntries(const <int>[1, 2]), _ok);
    expect(
      await adapter.saveBytesToFile(
        fileName: 'a.txt',
        bytes: const <int>[1, 2],
      ),
      _ok,
    );

    delegate.pickFileReturnsNull = true;
    expect(
      await adapter.pickFile(allowedExtensions: const <String>['txt']),
      isNull,
    );
    delegate.pickFileReturnsNull = false;
    final picked = (await adapter.pickFile(dialogTitle: 'Pick'))!;
    expect(picked.name, 'x.txt');
    expect(picked.localPath, '/tmp/x.txt');
  });

  test('client system adapter defaults to the shared service', () {
    final adapter = AppAiClientSystemAdapter();
    expect(adapter.getClientTime(), containsPair('target', 'client_device'));
  });

  test('health adapter maps every profile and status', () async {
    final healthy = AppAiHealthAdapter(_FakeAiClientSystemPort());
    expect((await healthy.check()).status, ai.AiRuntimeHealthStatus.ok);
    for (final profile in const <ai.AiHealthProfile>[
      ai.AiHealthProfile.agentExecution,
      ai.AiHealthProfile.background,
    ]) {
      expect(
        (await healthy.check(profile: profile)).status,
        ai.AiRuntimeHealthStatus.ok,
      );
    }

    final warning = await AppAiHealthAdapter(
      _FakeAiClientSystemPort(network: _meteredNetwork),
    ).check();
    expect(warning.status, ai.AiRuntimeHealthStatus.warning);
    expect(warning.issues.single.code, 'metered_network');

    final blocking = await AppAiHealthAdapter(
      _FakeAiClientSystemPort(network: _blockedNetwork),
    ).check();
    expect(blocking.status, ai.AiRuntimeHealthStatus.blocking);
    expect(blocking.issues.single.code, 'network_disconnected');
  });

  test('webview adapter mirrors snapshots and forwards controls', () async {
    final delegate = _FakeWebViewAdapter();
    final adapter = AppAiWebViewAdapter(delegate: delegate);
    expect((await adapter.readPlainText('chat-1')).text, 'hello');
    final search = await adapter.searchWeb(
      'chat-1',
      'query',
      maxResults: 3,
      engine: 'bing',
    );
    expect(search.results.single.title, 'Result');
    expect((await adapter.getState('chat-1')).isAiBrowsing, isTrue);
    final navigation = await adapter.navigate(
      'chat-1',
      action: 'back',
      input: 'input',
    );
    expect(navigation.state?.chatId, 'chat-1');
    adapter.interruptAiBrowsing('chat-1');
    adapter.clearSession('chat-1');
    expect(delegate.interrupted, <String>['chat-1']);
    expect(delegate.cleared, <String>['chat-1']);
  });

  test('webview navigation omits a missing state snapshot', () async {
    final result = await AppAiWebViewAdapter(
      delegate: _FakeWebViewAdapter(withState: false),
    ).navigate('chat-2', action: 'go', input: 'url');
    expect(result.state, isNull);
  });

  test('server catalog adapter lists, details, and builds candidates', () {
    final repo = _FakeConnectionRepository(<ConnectionConfig>[_config()]);
    final adapter = _catalogAdapter(repository: repo);
    expect(adapter.listServerSummaries().single['id'], 'server-a');
    expect(
      adapter.getServerDetails('server-a')!['server']['host'],
      'server-a.example.test',
    );
    expect(adapter.getServerDetails('missing'), isNull);
    expect(
      adapter.buildUpdateCandidate(_config(), const <String, dynamic>{
        'name': 'Renamed',
      }).name,
      'Renamed',
    );
  });

  test('catalog update rejects stale approval snapshots', () async {
    final repo = _FakeConnectionRepository(<ConnectionConfig>[_config()]);
    final adapter = _catalogAdapter(repository: repo);

    await expectLater(
      adapter.updateServerMetadata(
        connectionId: 'server-a',
        changes: const <String, dynamic>{'name': 'New'},
        approvedTarget: ssh_core.SshTargetBinding.fromConfig(
          _config().copyWith(host: 'changed.example.test'),
        ),
      ),
      throwsA(isA<RemoteTargetScopeException>()),
    );
    await expectLater(
      adapter.updateServerMetadata(
        connectionId: 'server-a',
        changes: const <String, dynamic>{'name': 'New'},
        approvedCurrent: _config().copyWith(name: 'Old'),
      ),
      throwsA(isA<RemoteTargetScopeException>()),
    );
  });

  test('catalog delete disconnects and removes credentials', () async {
    final repo = _FakeConnectionRepository(<ConnectionConfig>[_config()]);
    final ssh = _FakeSshService();
    final sftp = _FakeSftpService();
    final credentials = _FakeCredentialRepository();
    final adapter = AppAiServerCatalogAdapter(
      connectionRepository: repo,
      credentialRepository: credentials,
      hostKeyRepository: _FakeHostKeyRepository(),
      ssh: ssh,
      sftp: sftp,
    );

    expect((await adapter.deleteServer('server-a'))['deleted'], isTrue);
    expect(repo.connections, isEmpty);
    expect(ssh.disconnectCalls, 1);
    expect(sftp.disconnectCalls, 1);
    expect(credentials.deleteCalls, 1);
  });

  test('catalog reorder validates and persists the requested order', () async {
    final repo = _FakeConnectionRepository(<ConnectionConfig>[
      _config(id: 'a', name: 'A'),
      _config(id: 'b', name: 'B'),
    ]);
    final adapter = _catalogAdapter(repository: repo);

    await expectLater(adapter.reorderServers(<String>['a']), throwsStateError);
    expect(
      (await adapter.reorderServers(<String>['b', 'a']))['reordered'],
      isTrue,
    );
    expect(repo.reorders, <({int oldIndex, int newIndex})>[
      (oldIndex: 1, newIndex: 0),
    ]);
  });

  test('diagnostics adapter reports linux status and ops report', () async {
    final ssh = _FakeSshService();
    final adapter = AppAiServerDiagnosticsAdapter(
      connectionRepository: _FakeConnectionRepository(<ConnectionConfig>[
        _config(serverPlatform: ServerPlatform.linux),
      ]),
      ssh: ssh,
    );

    expect((await adapter.detectOs('server-a'))['os'], 'linux');
    expect(
      (await adapter.getStatus(
        connectionId: 'server-a',
        mode: 'performance',
      ))['connectionId'],
      'server-a',
    );
    expect(ssh.commands, isNotEmpty);
    expect(
      (await adapter.generateOpsReport('server-a'))['health'],
      contains('level'),
    );
  });

  test('diagnostics adapter handles windows status', () async {
    final adapter = AppAiServerDiagnosticsAdapter(
      connectionRepository: _FakeConnectionRepository(<ConnectionConfig>[
        _config(serverPlatform: ServerPlatform.windows),
      ]),
      ssh: _FakeSshService(),
    );

    final status = await adapter.getStatus(
      connectionId: 'server-a',
      mode: 'ports',
    );
    expect(status['os']['os'], 'windows');
    expect(status['windowsStatus'], isNotNull);
  });

  test('logger adapter forwards levels and details', () {
    final logger = _FakeAppLogService();
    final adapter = AppAiLoggerAdapter(logger);

    adapter.info('info', details: 'detail');
    adapter.warning('warning');
    adapter.error(
      'error',
      error: Exception('failed'),
      stackTrace: StackTrace.current,
      details: 'detail',
    );
    expect(logger.calls, <String>[
      'info:info:detail',
      'warning:warning',
      'error:error',
    ]);
  });
}

ConnectionConfig _config({
  String id = 'server-a',
  String name = 'Server A',
  ServerPlatform serverPlatform = ServerPlatform.linux,
}) => ConnectionConfig(
  id: id,
  name: name,
  host: 'server-a.example.test',
  username: 'root',
  serverPlatform: serverPlatform,
);

AppAiServerCatalogAdapter _catalogAdapter({
  required _FakeConnectionRepository repository,
}) => AppAiServerCatalogAdapter(
  connectionRepository: repository,
  credentialRepository: _FakeCredentialRepository(),
  hostKeyRepository: _FakeHostKeyRepository(),
  ssh: _FakeSshService(),
  sftp: _FakeSftpService(),
);

final class _FakeDataProtection extends Fake implements DataProtectionService {
  @override
  Future<String> encryptString(String value) async => 'enc';

  @override
  Future<String> decryptString(String value) async => 'dec';
}

final class _FakeClientSystemToolService extends Fake
    implements legacy_system.ClientSystemToolService {
  bool pickFileReturnsNull = false;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final name = invocation.memberName;
    if (name == #pickFile) {
      return Future<legacy_system.ClientPickedFile?>.value(
        pickFileReturnsNull
            ? null
            : legacy_system.ClientPickedFile(
                name: 'x.txt',
                bytes: Uint8List.fromList(<int>[3, 4]),
                localPath: '/tmp/x.txt',
              ),
      );
    }
    if (name == #getClientTime || name == #getClientDeviceInfo) return _ok;
    return Future<Map<String, dynamic>>.value(_ok);
  }
}

final class _FakeAiClientSystemPort extends Fake
    implements ai.AiClientSystemPort {
  _FakeAiClientSystemPort({Map<String, dynamic>? network})
    : network = network ?? _healthyNetwork;

  final Map<String, dynamic> permission = _permission;
  final Map<String, dynamic> network;
  final Map<String, dynamic> battery = _battery;

  @override
  Future<Map<String, dynamic>> getPermissionStatus() async => permission;

  @override
  Future<Map<String, dynamic>> getNetworkInfo() async => network;

  @override
  Future<Map<String, dynamic>> getBatteryStatus() async => battery;
}

final class _FakeWebViewAdapter extends Fake
    implements webview.ClientWebViewAdapter {
  _FakeWebViewAdapter({this.withState = true});

  final bool withState;
  final List<String> interrupted = <String>[];
  final List<String> cleared = <String>[];

  @override
  void interruptAiBrowsing(String chatId) => interrupted.add(chatId);

  @override
  void clearSession(String chatId) => cleared.add(chatId);

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      switch (invocation.memberName) {
        #readPlainText => Future<webview.ClientWebViewSnapshot>.value(_text),
        #searchWeb => Future<webview.ClientWebViewSearchResult>.value(_search),
        #getState => Future<webview.ClientWebViewStateSnapshot>.value(_state),
        #navigate => Future<webview.ClientWebViewNavigationResult>.value(
          webview.ClientWebViewNavigationResult(
            chatId: 'chat-1',
            supported: true,
            action: 'back',
            input: 'input',
            navigated: true,
            blocked: false,
            state: withState ? _state : null,
          ),
        ),
        _ => super.noSuchMethod(invocation),
      };
}

final class _FakeConnectionRepository extends Fake
    implements ConnectionRepository {
  _FakeConnectionRepository(this.connections);

  @override
  List<ConnectionConfig> connections;
  final List<({int oldIndex, int newIndex})> reorders =
      <({int oldIndex, int newIndex})>[];

  @override
  ConnectionConfig? getConnection(String id) {
    for (final config in connections) {
      if (config.id == id) return config;
    }
    return null;
  }

  @override
  Future<void> deleteConnection(String id) async =>
      connections.removeWhere((config) => config.id == id);

  @override
  Future<void> reorderConnections(int oldIndex, int newIndex) async {
    final config = connections.removeAt(oldIndex);
    connections.insert(newIndex, config);
    reorders.add((oldIndex: oldIndex, newIndex: newIndex));
  }
}

final class _FakeCredentialRepository extends Fake
    implements CredentialRepository {
  int deleteCalls = 0;

  @override
  Future<String?> getPassword(String connectionId) async => 'secret';

  @override
  Future<String?> getPrivateKey(String connectionId) async => null;

  @override
  Future<void> deleteCredentials(String connectionId) async {
    deleteCalls++;
  }
}

final class _FakeHostKeyRepository extends Fake implements HostKeyRepository {}

final class _FakeSshService extends Fake implements SshService {
  final List<String> commands = <String>[];
  int disconnectCalls = 0;

  @override
  Future<RemoteCommandResult> runOneShotCommand({
    required String connectionId,
    required String command,
    Duration timeout = const Duration(seconds: 15),
    ssh_core.SshHostKeyConfirmation? onUnknownHostKey,
  }) async {
    commands.add(command);
    return RemoteCommandResult(
      exitCode: 0,
      stderr: '',
      stdout: command.contains('__PROC__')
          ? _procOutput
          : command.contains('ss -H')
          ? _portsOutput
          : command.contains('ps -eo')
          ? _appsOutput
          : command.startsWith('powershell')
          ? '{}'
          : '',
    );
  }

  @override
  SshSession? latestSessionForConnection(String connectionId) => null;

  @override
  int sessionCountForConnection(String connectionId) => 0;

  @override
  bool hasConnectedSession(String connectionId) => false;

  @override
  Future<void> disconnectSessionsForConnection(String connectionId) async {
    disconnectCalls++;
  }
}

final class _FakeSftpService extends Fake implements SftpService {
  int disconnectCalls = 0;

  @override
  Future<void> disconnectConnection(
    String connectionId, {
    bool notify = true,
    bool forgetPath = false,
  }) async => disconnectCalls++;
}

final class _FakeAppLogService extends Fake implements AppLogService {
  final List<String> calls = <String>[];

  @override
  void info(String message, {String? details}) {
    calls.add('info:$message:$details');
  }

  @override
  void warning(String message, {String? details}) {
    calls.add('warning:$message');
  }

  @override
  void error(
    String message, {
    Object? error,
    StackTrace? stackTrace,
    String? details,
  }) {
    calls.add('error:$message');
  }
}
