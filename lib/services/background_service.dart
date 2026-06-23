import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:permission_handler/permission_handler.dart';

import '../features/connection/models/connection.dart';
import '../core/services/ssh_client_factory.dart';
import '../core/services/ssh_host_key_policy.dart';

/// Android/iOS 前台服务管理。
///
/// 职责：
/// 1. 启动/停止前台服务（flutter_background_service）
/// 2. 通知渠道创建 + 权限请求
/// 3. WakeLock 获取/释放（通过 MethodChannel 'ssh_mobile/power'）
/// 4. 电池优化豁免引导
///
/// sshBackgroundServiceEntryPoint：后台 SSH 入口点函数，与 UI 进程隔离运行。
/// 完整实现 SSH 客户端、Shell 管理、心跳保活和重连逻辑。
class BackgroundServiceManager {
  static const String _channelId = 'ssh_mobile_foreground';
  static const int _notificationId = 1001;
  static const MethodChannel _powerChannel = MethodChannel('ssh_mobile/power');
  static bool _configured = false;
  static bool _notificationPermissionChecked = false;
  static Future<void>? _prewarmFuture;

  static bool get _supportsNativeBackgroundService {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
  }

  static Future<void> initialize() async {
    if (!_supportsNativeBackgroundService) return;
    await _requestNotificationPermission();
    await prewarm();
  }

  static Future<void> prewarm() async {
    if (!_supportsNativeBackgroundService) return;
    if (_configured) return;
    final existing = _prewarmFuture;
    if (existing != null) {
      await existing;
      return;
    }

    final future = _configureService();
    _prewarmFuture = future;
    try {
      await future;
    } finally {
      _prewarmFuture = null;
    }
  }

  static Future<void> _configureService() async {
    if (_configured) return;
    await _createNotificationChannel();

    final service = FlutterBackgroundService();
    await service.configure(
      androidConfiguration: AndroidConfiguration(
        onStart: sshBackgroundServiceEntryPoint,
        autoStart: false,
        autoStartOnBoot: false,
        isForegroundMode: true,
        notificationChannelId: _channelId,
        initialNotificationTitle: 'SSH Mobile',
        initialNotificationContent: 'SSH service is ready',
        foregroundServiceNotificationId: _notificationId,
        foregroundServiceTypes: const [AndroidForegroundType.dataSync],
      ),
      iosConfiguration: IosConfiguration(
        autoStart: false,
        onForeground: sshBackgroundServiceEntryPoint,
      ),
    );

    _configured = true;
  }

  static Future<void> start({
    String? connectionName,
    bool showConnectionName = false,
  }) async {
    if (!_supportsNativeBackgroundService) return;
    await initialize();
    var locksAcquired = false;
    try {
      await _acquirePowerLocks();
      locksAcquired = true;
      unawaited(_requestBatteryOptimizationExemption());

      final service = FlutterBackgroundService();
      if (!await service.isRunning()) {
        await service.startService();
      }

      service.invoke('update', {
        'title': 'SSH Mobile',
        'content': _notificationContent(
          connectionName,
          showConnectionName: showConnectionName,
        ),
      });
    } catch (_) {
      if (locksAcquired) {
        await _releasePowerLocks();
      }
      rethrow;
    }
  }

  static Future<void> stop() async {
    if (!_supportsNativeBackgroundService) return;
    final service = FlutterBackgroundService();
    if (await service.isRunning()) {
      service.invoke('stopService');
    }
    await _releasePowerLocks();
  }

  static Future<bool> isIgnoringBatteryOptimizations() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return true;
    try {
      return await _powerChannel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> requestBatteryOptimizationExemption() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _powerChannel.invokeMethod<bool>(
        'requestBatteryOptimizationExemption',
      );
    } catch (_) {}
  }

  static Future<void> openAppSettings() async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) return;
    try {
      await _powerChannel.invokeMethod<bool>('openAppSettings');
    } catch (_) {}
  }

  static void updateStatus(String content) {
    if (!_supportsNativeBackgroundService) return;
    FlutterBackgroundService().invoke('update', {
      'title': 'SSH Mobile',
      'content': content,
    });
  }

  static Future<void> _requestNotificationPermission() async {
    if (_notificationPermissionChecked) return;
    _notificationPermissionChecked = true;

    final status = await Permission.notification.status;
    if (status.isDenied || status.isRestricted || status.isLimited) {
      await Permission.notification.request();
    }
  }

  static Future<void> _createNotificationChannel() async {
    const channel = AndroidNotificationChannel(
      _channelId,
      'SSH connection',
      description: 'Keeps active SSH sessions alive in a foreground service.',
      importance: Importance.low,
      playSound: false,
      enableVibration: false,
      showBadge: false,
    );

    final plugin = FlutterLocalNotificationsPlugin();
    await plugin
        .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(channel);
  }

  static Future<void> _acquirePowerLocks() async {
    try {
      await _powerChannel.invokeMethod<bool>('acquireLocks');
    } catch (_) {}
  }

  static Future<void> _releasePowerLocks() async {
    try {
      await _powerChannel.invokeMethod<bool>('releaseLocks');
    } catch (_) {}
  }

  static Future<void> _requestBatteryOptimizationExemption() async {
    try {
      final ignoring = await _powerChannel
              .invokeMethod<bool>('isIgnoringBatteryOptimizations') ??
          true;
      if (!ignoring) {
        await _powerChannel.invokeMethod<bool>(
          'requestBatteryOptimizationExemption',
        );
      }
    } catch (_) {}
  }

  static String _notificationContent(
    String? connectionName, {
    required bool showConnectionName,
  }) {
    if (!showConnectionName ||
        connectionName == null ||
        connectionName.isEmpty) {
      return 'SSH service is running';
    }
    return 'Connected to $connectionName';
  }
}

Map<String, dynamic> sanitizeBackgroundReconnectData(
  Map<String, dynamic> data,
) {
  return Map<String, dynamic>.from(data)
    ..remove('password')
    ..remove('privateKey');
}

class BackgroundReconnectDecision {
  final bool reconnectInBackground;
  final bool requiresAppReconnect;
  final String message;

  const BackgroundReconnectDecision({
    required this.reconnectInBackground,
    required this.requiresAppReconnect,
    required this.message,
  });
}

BackgroundReconnectDecision decideBackgroundUnexpectedDisconnect({
  required String launchMode,
  required String reason,
}) {
  if (launchMode == 'tmux') {
    return BackgroundReconnectDecision(
      reconnectInBackground: false,
      requiresAppReconnect: true,
      message:
          'Connection lost: $reason. Reconnect from the app to restore this tmux session.',
    );
  }

  return BackgroundReconnectDecision(
    reconnectInBackground: false,
    requiresAppReconnect: false,
    message: 'Connection lost: $reason',
  );
}

@pragma('vm:entry-point')
void sshBackgroundServiceEntryPoint(ServiceInstance service) {
  final sessions = <String, _BackgroundSshSession>{};

  void emitLog(String level, String message, {String? details}) {
    service.invoke('sshLogReceived', {
      'level': level,
      'message': message,
      if (details != null && details.isNotEmpty) 'details': details,
      'timestamp': DateTime.now().toIso8601String(),
    });
  }

  void emitOverview() {
    final byConnection = <String, Map<String, dynamic>>{};
    for (final session in sessions.values) {
      final connId = session.connectionId;
      if (connId != null) {
        final current = byConnection.putIfAbsent(
            connId,
            () => {
                  'count': 0,
                  'latestState': 'connected',
                  'hasConnected': true,
                });
        current['count'] = (current['count'] as int) + 1;
      }
    }

    service.invoke('sshOverviewUpdated', {
      'overview': byConnection,
      'windowCount': sessions.length,
    });
  }

  void setNotification(String content) {
    if (service is AndroidServiceInstance) {
      service.setAsForegroundService();
      service.setForegroundNotificationInfo(
        title: 'SSH Mobile',
        content: content,
      );
    }
  }

  void emitState(
    String state, {
    required String sessionId,
    String? message,
    String? connectionId,
    String? connectionName,
  }) {
    emitLog(
      'service',
      'SSH state: $state',
      details:
          'sessionId=$sessionId connection=${connectionName ?? connectionId ?? ''}'
          '${message == null ? '' : ' message=$message'}',
    );
    service.invoke('sshStateChanged', {
      'sessionId': sessionId,
      'state': state,
      if (message != null) 'message': message,
      if (connectionId != null) 'connectionId': connectionId,
      if (connectionName != null) 'connectionName': connectionName,
    });
  }

  String notificationSummary() {
    final count = sessions.length;
    if (count == 0) return 'SSH service is running';
    if (count == 1) {
      final session = sessions.values.first;
      if (session.showServerNameInNotification) {
        return 'Connected to ${session.connectionName}';
      }
      return '1 SSH session running';
    }
    return '$count SSH sessions running';
  }

  Future<void> closeSsh(
    String sessionId, {
    bool notify = true,
    String? message,
    bool destroyTmux = false,
  }) async {
    final session = sessions.remove(sessionId);
    if (session == null) return;
    emitLog(
      'service',
      'Closing SSH session',
      details:
          'sessionId=$sessionId notify=$notify destroyTmux=$destroyTmux mode=${session.launchMode}',
    );
    if (destroyTmux) {
      await session.killTmuxSession();
    }
    session.close();
    if (notify) {
      emitState(
        'disconnected',
        sessionId: sessionId,
        message: message ?? 'Connection closed',
        connectionId: session.connectionId,
        connectionName: session.connectionName,
      );
      setNotification(notificationSummary());
    }
    emitOverview();
  }

  Future<void> closeAll({bool notify = true}) async {
    final ids = sessions.keys.toList();
    emitLog(
      'service',
      'Closing all SSH sessions',
      details: 'count=${ids.length} notify=$notify',
    );
    for (final sessionId in ids) {
      await closeSsh(sessionId, notify: notify, destroyTmux: true);
    }
    setNotification('SSH service is running');
  }

  late Future<void> Function(Map<String, dynamic> data) connectSsh;

  Future<void> handleUnexpectedDisconnect(
    _BackgroundSshSession runtime,
    String reason,
  ) async {
    if (!sessions.containsKey(runtime.sessionId)) {
      return;
    }

    final decision = decideBackgroundUnexpectedDisconnect(
      launchMode: runtime.launchMode,
      reason: reason,
    );
    if (decision.requiresAppReconnect) {
      emitLog(
        'warning',
        'Background tmux reconnect requires app credentials',
        details:
            'sessionId=${runtime.sessionId} tmux=${runtime.tmuxSessionName} reason=$reason',
      );
    }

    await closeSsh(
      runtime.sessionId,
      message: decision.message,
    );
  }

  String sanitizeTmuxSessionName(String name) {
    final sanitized = name
        .trim()
        // tmux treats "." as a target separator: session.window. Keep session
        // names to plain safe characters so domains like hejulian.cn do not
        // become an invalid tmux target.
        .replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_')
        .replaceAll(RegExp(r'_+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
    if (sanitized.isEmpty) return 'ssh_mobile';
    return sanitized.length > 80 ? sanitized.substring(0, 80) : sanitized;
  }

  String shellQuote(String value) {
    return "'${value.replaceAll("'", "'\"'\"'")}'";
  }

  String buildTmuxAttachCommand(String sessionName, int autoDeleteSeconds) {
    final safeName = sanitizeTmuxSessionName(sessionName);
    final quotedName = shellQuote(safeName);
    final seconds = autoDeleteSeconds.clamp(30, 86400);
    final idleWatcher = 'idle_start=0; interval=5; '
        'while tmux has-session -t $quotedName 2>/dev/null; do '
        'if tmux list-clients -t $quotedName 2>/dev/null | grep -q .; then '
        'idle_start=0; '
        'else now=\$(date +%s); '
        'if [ "\$idle_start" -eq 0 ]; then idle_start=\$now; fi; '
        'if [ \$((now - idle_start)) -ge $seconds ]; then '
        'tmux kill-session -t $quotedName 2>/dev/null; exit; fi; '
        'fi; sleep \$interval; done';
    return 'if command -v tmux >/dev/null 2>&1; then '
        'tmux has-session -t $quotedName 2>/dev/null || '
        'tmux new-session -d -s $quotedName; '
        'tmux set-option -t $quotedName -q @ssh_mobile_auto_delete_seconds $seconds; '
        'tmux set-option -t $quotedName -q status off; '
        'tmux run-shell -b ${shellQuote(idleWatcher)}; '
        'tmux attach-session -t $quotedName; '
        'else echo "tmux is not installed on this server"; exit 127; fi';
  }

  Future<void> ensureTmuxInstalled({
    required SSHClient client,
  }) async {
    late final SSHRunResult tmuxCheck;
    try {
      emitLog('service', 'Checking tmux installation');
      tmuxCheck = await client
          .runWithResult('command -v tmux >/dev/null 2>&1')
          .timeout(const Duration(seconds: 8));
    } catch (e) {
      emitLog('error', 'Unable to check tmux', details: e.toString());
      throw StateError(
        'Unable to check tmux on this server. Please install tmux manually '
        'on the server and try again. Detail: $e',
      );
    }
    if (tmuxCheck.exitCode == 0) return;

    emitLog('warning', 'tmux is not installed on server');
    throw StateError(
      'tmux is not installed on this server. Please install tmux manually '
      'on the server and try again.',
    );
  }

  connectSsh = (Map<String, dynamic> data) async {
    final sessionId = data['sessionId'] as String?;
    if (sessionId == null || sessionId.isEmpty) {
      emitLog('warning', 'Ignoring sshConnect without sessionId');
      return;
    }
    await closeSsh(sessionId, notify: false);
    final connectionId = data['id'] as String?;
    final name = data['name'] as String? ?? 'server';
    final showServerNameInNotification =
        data['showServerNameInNotification'] == true;
    emitState(
      'connecting',
      sessionId: sessionId,
      connectionId: connectionId,
      connectionName: name,
    );
    setNotification(
      showServerNameInNotification ? 'Connecting to $name...' : 'Connecting...',
    );
    emitLog(
      'service',
      'Connecting SSH socket',
      details: 'sessionId=$sessionId host=${data['host']}:${data['port']}',
    );

    try {
      final host = data['host'] as String;
      final port = (data['port'] as num?)?.toInt() ?? 22;
      final username = data['username'] as String;
      final authMethod = data['authMethod'] as String? ?? 'password';
      final password = data['password'] as String?;
      final privateKey = data['privateKey'] as String?;
      final width = (data['terminalWidth'] as num?)?.toInt() ?? 80;
      final height = (data['terminalHeight'] as num?)?.toInt() ?? 24;
      final keepAliveSeconds =
          (data['keepAliveInterval'] as num?)?.toInt() ?? 3;
      final launchMode = data['launchMode'] as String? ?? 'ssh';
      final tmuxSessionName =
          sanitizeTmuxSessionName(data['tmuxSessionName'] as String? ?? name);
      final tmuxAutoDeleteSeconds =
          ((data['tmuxAutoDeleteSeconds'] as num?)?.toInt() ?? 600)
              .clamp(30, 86400);
      final socket = await SSHSocket.connect(
        host,
        port,
        timeout: const Duration(seconds: 15),
      );
      emitLog(
        'service',
        'SSH socket connected',
        details: 'sessionId=$sessionId host=$host:$port',
      );

      final config = ConnectionConfig(
        id: connectionId ?? sessionId,
        name: name,
        host: host,
        port: port,
        username: username,
        authMethod: AuthMethod.fromName(authMethod),
        hostKeyFingerprint: data['hostKeyFingerprint'] as String?,
        hostKeyAlgorithm: data['hostKeyAlgorithm'] as String?,
        hostKeyTrustedAt: DateTime.tryParse(
          data['hostKeyTrustedAt'] as String? ?? '',
        ),
      );
      final credentials = SshCredentials(
        password: password,
        privateKey: privateKey,
      );
      final hostKeyPolicy = SshHostKeyPolicy();

      final identities =
          await SshClientFactory.identitiesFor(config, credentials);

      final authOptions = SshClientFactory.buildAuthOptions(
        config: config,
        credentials: credentials,
        identities: identities,
      );

      final client = SSHClient(
        socket,
        username: username,
        onVerifyHostKey: (algorithm, fingerprint) =>
            hostKeyPolicy.verifyHostKey(
          config: config,
          algorithm: algorithm,
          md5Fingerprint: fingerprint,
        ),
        identities: authOptions.identities,
        onPasswordRequest: authOptions.onPasswordRequest,
        onUserInfoRequest: authOptions.onUserInfoRequest,
      );

      await client.authenticated.timeout(const Duration(seconds: 15));

      if (launchMode == 'tmux') {
        try {
          await ensureTmuxInstalled(
            client: client,
          );
          emitLog(
            'service',
            'tmux available',
            details: 'sessionId=$sessionId tmux=$tmuxSessionName',
          );
        } catch (_) {
          client.close();
          rethrow;
        }
      }

      final shell = await client.shell(
        pty: SSHPtyConfig(
          width: width,
          height: height,
          type: 'xterm-256color',
        ),
      );
      emitLog(
        'service',
        'SSH shell opened',
        details: 'sessionId=$sessionId size=${width}x$height mode=$launchMode',
      );

      final runtime = _BackgroundSshSession(
        sessionId: sessionId,
        connectionId: connectionId,
        connectionName: name,
        tmuxSessionName: launchMode == 'tmux' ? tmuxSessionName : null,
        tmuxAutoDeleteSeconds: tmuxAutoDeleteSeconds,
        launchMode: launchMode,
        showServerNameInNotification: showServerNameInNotification,
        reconnectData: sanitizeBackgroundReconnectData(data),
        client: client,
        shell: shell,
      );
      sessions[sessionId] = runtime;

      runtime.stdoutSub = shell.stdout.listen(
        (bytes) {
          service.invoke('sshDataReceived', {
            'sessionId': sessionId,
            'data': utf8.decode(bytes, allowMalformed: true),
          });
        },
        onError: (Object error) {
          emitLog(
            'error',
            'SSH stdout stream error',
            details: 'sessionId=$sessionId error=$error',
          );
          unawaited(handleUnexpectedDisconnect(runtime, error.toString()));
        },
        onDone: () {
          emitLog('service', 'SSH stdout stream closed',
              details: 'sessionId=$sessionId');
          unawaited(handleUnexpectedDisconnect(runtime, 'stdout closed'));
        },
      );

      runtime.stderrSub = shell.stderr.listen(
        (bytes) {
          service.invoke('sshDataReceived', {
            'sessionId': sessionId,
            'data': utf8.decode(bytes, allowMalformed: true),
          });
        },
      );

      if (launchMode == 'tmux') {
        final command = buildTmuxAttachCommand(
          tmuxSessionName,
          tmuxAutoDeleteSeconds,
        );
        emitLog(
          'service',
          'Attaching tmux session',
          details:
              'sessionId=$sessionId tmux=$tmuxSessionName autoDelete=${tmuxAutoDeleteSeconds}s',
        );
        shell.stdin.add(utf8.encode('$command\r'));
      }

      runtime.keepAliveTimer = Timer.periodic(
        Duration(seconds: keepAliveSeconds.clamp(3, 30)),
        (_) async {
          if (runtime.pingInFlight) return;
          runtime.pingInFlight = true;
          try {
            await runtime.client.ping().timeout(const Duration(seconds: 10));
            runtime.keepAliveFailures = 0;
            service.invoke('sshKeepAlive', {
              'sessionId': sessionId,
              'ok': true,
              'timestamp': DateTime.now().toIso8601String(),
            });
          } catch (e) {
            emitLog(
              'warning',
              'SSH keep-alive failed',
              details:
                  'sessionId=${runtime.sessionId} failures=${runtime.keepAliveFailures + 1} error=$e',
            );
            service.invoke('sshKeepAlive', {
              'sessionId': sessionId,
              'ok': false,
              'error': e.toString(),
              'timestamp': DateTime.now().toIso8601String(),
            });
            runtime.keepAliveFailures++;
            await handleUnexpectedDisconnect(runtime, e.toString());
          } finally {
            runtime.pingInFlight = false;
          }
        },
      );

      emitState(
        'connected',
        sessionId: sessionId,
        connectionId: connectionId,
        connectionName: name,
      );
      emitOverview();
      setNotification(notificationSummary());
      emitLog(
        'service',
        'SSH session connected',
        details: 'sessionId=$sessionId connection=$name mode=$launchMode',
      );
    } catch (e) {
      await closeSsh(sessionId, notify: false);
      emitLog(
        'error',
        'SSH connection failed',
        details: 'sessionId=$sessionId connection=$name error=$e',
      );
      emitState(
        'error',
        sessionId: sessionId,
        message: 'Connection failed: $e',
        connectionId: connectionId,
        connectionName: name,
      );
      setNotification('SSH connection failed');
    }
  };

  setNotification('SSH service is running');
  emitLog('service', 'Background SSH service started');

  service.on('sshConnect').listen((event) {
    if (event != null) {
      emitLog(
        'service',
        'Received sshConnect request',
        details: 'sessionId=${event['sessionId']} connection=${event['name']}',
      );
      unawaited(connectSsh(event));
    }
  });

  service.on('sshInput').listen((event) {
    final sessionId = event?['sessionId'] as String?;
    final data = event?['data'] as String?;
    final session = sessionId == null ? null : sessions[sessionId];
    if (data != null && session != null) {
      session.shell.stdin.add(utf8.encode(data));
    } else if (sessionId != null) {
      emitLog(
        'warning',
        'Ignoring input for missing SSH session',
        details: 'sessionId=$sessionId',
      );
    }
  });

  service.on('sshResize').listen((event) {
    final sessionId = event?['sessionId'] as String?;
    final width = (event?['width'] as num?)?.toInt();
    final height = (event?['height'] as num?)?.toInt();
    final session = sessionId == null ? null : sessions[sessionId];
    if (width != null && height != null && session != null) {
      session.shell.resizeTerminal(width, height);
      emitLog(
        'service',
        'Resized SSH terminal',
        details: 'sessionId=$sessionId size=${width}x$height',
      );
    }
  });

  service.on('sshDisconnect').listen((event) {
    final sessionId = event?['sessionId'] as String?;
    if (sessionId != null) {
      emitLog('service', 'Received sshDisconnect request',
          details: 'sessionId=$sessionId');
      unawaited(closeSsh(sessionId, destroyTmux: true));
    }
  });

  service.on('sshDisconnectAll').listen((event) async {
    emitLog('service', 'Received sshDisconnectAll request');
    await closeAll();
  });

  service.on('update').listen((event) {
    setNotification(
      event?['content'] as String? ?? 'SSH service is running',
    );
  });

  service.on('stopService').listen((event) async {
    emitLog('service', 'Stopping background SSH service');
    await closeAll(notify: false);
    service.stopSelf();
  });
}

class _BackgroundSshSession {
  final String sessionId;
  final String? connectionId;
  final String connectionName;
  final String? tmuxSessionName;
  final int tmuxAutoDeleteSeconds;
  final String launchMode;
  final bool showServerNameInNotification;
  final Map<String, dynamic> reconnectData;
  final SSHClient client;
  final SSHSession shell;
  StreamSubscription<List<int>>? stdoutSub;
  StreamSubscription<List<int>>? stderrSub;
  Timer? keepAliveTimer;
  bool pingInFlight = false;
  int keepAliveFailures = 0;

  _BackgroundSshSession({
    required this.sessionId,
    required this.connectionId,
    required this.connectionName,
    required this.tmuxSessionName,
    required this.tmuxAutoDeleteSeconds,
    required this.launchMode,
    required this.showServerNameInNotification,
    required this.reconnectData,
    required this.client,
    required this.shell,
  });

  void close() {
    keepAliveTimer?.cancel();
    stdoutSub?.cancel();
    stderrSub?.cancel();
    shell.close();
    client.close();
    pingInFlight = false;
  }

  Future<void> killTmuxSession() async {
    final name = tmuxSessionName;
    if (launchMode != 'tmux' || name == null || name.isEmpty) return;
    try {
      final quotedName = "'${name.replaceAll("'", "'\"'\"'")}'";
      final command = 'tmux kill-session -t $quotedName 2>/dev/null || true';
      await client
          .runWithResult(command, stdout: false, stderr: false)
          .timeout(const Duration(seconds: 5));
    } catch (_) {}
  }
}
