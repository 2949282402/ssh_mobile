// v1 LAN 配对和规范化 HTTP 错误响应测试。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:network_sdk/network_sdk.dart';
import 'package:ssh_mobile/services/lan_share/lan_discovery_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_pairing_crypto.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_share_models.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';

class FakeHttpResponse extends Fake implements HttpResponse {
  int _statusCode = HttpStatus.ok;
  final Map<String, dynamic> _headers = {};
  final StringBuffer _body = StringBuffer();
  final Completer<void> _closed = Completer<void>();

  Future<void> get closed => _closed.future;

  @override
  int get statusCode => _statusCode;

  @override
  set statusCode(int value) {
    _statusCode = value;
  }

  @override
  HttpHeaders get headers => FakeHttpHeaders(_headers);

  @override
  void write(Object? obj) {
    _body.write(obj);
  }

  @override
  Future<void> close() async {
    if (!_closed.isCompleted) _closed.complete();
  }
}

class FakeHttpHeaders extends Fake implements HttpHeaders {
  final Map<String, dynamic> _headers;
  FakeHttpHeaders(this._headers);

  @override
  ContentType? contentType;

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _headers[name] = value;
  }

  @override
  String? value(String name) {
    final value = _headers[name] ?? _headers[name.toLowerCase()];
    return value?.toString();
  }
}

class FakeHttpRequest extends Stream<Uint8List> implements HttpRequest {
  @override
  final Uri uri;
  @override
  Uri get requestedUri => uri;
  @override
  final String method;
  final String body;
  final FakeHttpHeaders requestHeaders = FakeHttpHeaders({});
  @override
  final FakeHttpResponse response = FakeHttpResponse();
  @override
  final FakeHttpConnectionInfo connectionInfo = FakeHttpConnectionInfo();

  FakeHttpRequest({
    required this.uri,
    required this.method,
    required this.body,
  });

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List event)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    final controller = StreamController<Uint8List>();
    controller.add(Uint8List.fromList(utf8.encode(body)));
    controller.close();
    return controller.stream.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  HttpHeaders get headers => requestHeaders;

  @override
  X509Certificate? get certificate => null;

  @override
  int get contentLength => utf8.encode(body).length;

  @override
  List<Cookie> get cookies => [];

  @override
  bool get persistentConnection => false;

  @override
  String get protocolVersion => '1.1';

  @override
  HttpSession get session => throw UnimplementedError();
}

class _ServerHandshakeExchange {
  final FakeHttpRequest beginRequest;
  final FakeHttpRequest? confirmRequest;

  const _ServerHandshakeExchange({
    required this.beginRequest,
    required this.confirmRequest,
  });
}

Future<_ServerHandshakeExchange> _performServerHandshake({
  required LanTransferService transferService,
  required String pin,
  required String deviceId,
  required bool isInitiator,
}) async {
  const targetDeviceId = 'local_device_123';
  final nonce = LanPairingCrypto.randomToken();
  late final List<LanPairingEphemeralKeyPair> clientKeys;
  final clientFingerprint = '1' * 64;
  final clientContext = LanPairingCrypto.clientContext(
    senderDeviceId: deviceId,
    targetDeviceId: targetDeviceId,
    nonce: nonce,
    alias: 'Scanner Device',
    os: 'android',
    port: 53317,
    isInitiator: isInitiator,
    senderCertFingerprint: clientFingerprint,
  );
  clientKeys = List<LanPairingEphemeralKeyPair>.generate(
    LanPairingCrypto.maxServerOffers,
    (slot) => LanPairingCrypto.generateClientKeyPair(
      pin: pin,
      clientContext: clientContext,
      slot: slot,
    ),
    growable: false,
  );
  final encodedClientPublicValues = clientKeys
      .map((keys) => base64.encode(keys.publicValue))
      .toList(growable: false);
  final beginRequest = FakeHttpRequest(
    uri: Uri.parse('/api/lan/handshake'),
    method: 'POST',
    body: jsonEncode({
      'protocolVersion': LanPairingCrypto.protocolVersion,
      'phase': 'begin',
      'deviceId': deviceId,
      'targetDeviceId': targetDeviceId,
      'alias': 'Scanner Device',
      'os': 'android',
      'port': 53317,
      'isInitiator': isInitiator,
      'nonce': nonce,
      'certFingerprint': clientFingerprint,
      'clientPublicValues': encodedClientPublicValues,
    }),
  );
  transferService.handleHttpRequest(beginRequest);
  await beginRequest.response.closed.timeout(const Duration(seconds: 15));
  if (beginRequest.response.statusCode != HttpStatus.ok) {
    return _ServerHandshakeExchange(
      beginRequest: beginRequest,
      confirmRequest: null,
    );
  }
  final beginBody =
      jsonDecode(beginRequest.response._body.toString())
          as Map<String, dynamic>;
  final serverFingerprint = beginBody['certFingerprint'] as String;
  final offers = beginBody['offers'] as List<dynamic>;
  Map<String, dynamic>? acceptedOffer;
  LanPairingSessionSecrets? acceptedSessionSecrets;
  Uint8List? acceptedSessionKey;
  String? acceptedSessionTranscript;
  for (final rawOffer in offers) {
    final offer = rawOffer as Map<String, dynamic>;
    try {
      final handshakeId = offer['handshakeId'] as String;
      final slot = offer['slot'] as int;
      final keys = clientKeys[slot];
      final salt = base64.decode(offer['salt'] as String);
      final serverPublicValue = base64.decode(
        offer['serverPublicValue'] as String,
      );
      final associatedData = LanPairingCrypto.sessionAssociatedData(
        clientContext: clientContext,
        handshakeId: handshakeId,
        slot: slot,
        salt: salt,
        clientPublicValue: keys.publicValue,
        serverPublicValue: serverPublicValue,
        serverCertFingerprint: serverFingerprint,
      );
      final sessionSecrets = LanPairingCrypto.deriveSessionSecrets(
        localKeyPair: keys,
        remotePublicValue: serverPublicValue,
        associatedData: associatedData,
      );
      if (!LanPairingCrypto.verifyServerProof(
        sessionSecrets,
        offer['serverProof'] as String,
      )) {
        continue;
      }
      acceptedOffer = offer;
      acceptedSessionSecrets = sessionSecrets;
      acceptedSessionKey = sessionSecrets.sessionKey;
      acceptedSessionTranscript = associatedData;
      break;
    } catch (_) {}
  }
  if (acceptedOffer == null ||
      acceptedSessionKey == null ||
      acceptedSessionTranscript == null) {
    return _ServerHandshakeExchange(
      beginRequest: beginRequest,
      confirmRequest: null,
    );
  }
  final confirmRequest = FakeHttpRequest(
    uri: Uri.parse('/api/lan/handshake'),
    method: 'POST',
    body: jsonEncode({
      'protocolVersion': LanPairingCrypto.protocolVersion,
      'phase': 'confirm',
      'handshakeId': acceptedOffer['handshakeId'],
      'deviceId': deviceId,
      'targetDeviceId': targetDeviceId,
      'nonce': nonce,
      'clientProof': LanPairingCrypto.createClientProof(
        acceptedSessionSecrets!,
      ),
    }),
  );
  transferService.handleHttpRequest(confirmRequest);
  await confirmRequest.response.closed.timeout(const Duration(seconds: 15));
  return _ServerHandshakeExchange(
    beginRequest: beginRequest,
    confirmRequest: confirmRequest,
  );
}

class FakeHttpConnectionInfo implements HttpConnectionInfo {
  @override
  int get localPort => 53317;

  @override
  InternetAddress get remoteAddress => InternetAddress.loopbackIPv4;

  @override
  int get remotePort => 50000;
}

/// 执行 v1 LAN 配对和规范化 HTTP 契约测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LanSecurityService securityService;
  late LanStorageService storageService;
  late LanTransferService transferService;

  setUp(() async {
    final certData = generateSelfSignedCertForTest('device-local_device_123');
    FlutterSecureStorage.setMockInitialValues({
      'lan_share_cert_local_device_123': certData['cert']!,
      'lan_share_key_local_device_123': certData['key']!,
    });
    securityService = LanSecurityService();
    storageService = LanStorageService();
    transferService = LanTransferService(
      currentDeviceId: 'local_device_123',
      securityService: securityService,
      storageService: storageService,
    );
  });

  tearDown(() {
    transferService.dispose();
  });

  group('LanTransferService Announcement and Pairing Handshake Tests', () {
    test('POST /api/lan/announce triggers announcedDeviceStream', () async {
      final announcePayload = jsonEncode({
        'id': 'remote_scanner_abc',
        'alias': 'Scanner Device',
        'os': 'android',
        'port': 53317,
        'ip': '192.168.1.50',
      });

      final request = FakeHttpRequest(
        uri: Uri.parse('/api/lan/announce'),
        method: 'POST',
        body: announcePayload,
      );

      final deviceFuture = transferService.announcedDeviceStream.first;

      transferService.handleHttpRequest(request);

      final device = await deviceFuture.timeout(const Duration(seconds: 15));

      expect(device.id, equals('remote_scanner_abc'));
      expect(device.alias, equals('Scanner Device'));
      expect(device.osName, equals('android'));
      expect(device.ip, equals('127.0.0.1'));
      expect(device.port, equals(53317));
      expect(request.response.statusCode, equals(HttpStatus.ok));
      final responseBody =
          jsonDecode(request.response._body.toString()) as Map<String, dynamic>;
      expect(responseBody['deviceId'], 'local_device_123');
      expect(responseBody['port'], transferService.activePort);
    });

    test('POST /api/lan/pairing_invite emits a short-lived request', () async {
      final request = FakeHttpRequest(
        uri: Uri.parse('/api/lan/pairing_invite'),
        method: 'POST',
        body: jsonEncode({
          'deviceId': 'remote_inviter',
          'alias': 'Inviter',
          'os': 'android',
          'port': 53320,
          'sessionId': 'session-123',
          'validForMs': const Duration(minutes: 1).inMilliseconds,
        }),
      );
      final inviteFuture = transferService.pairingInviteStream.first;

      transferService.handleHttpRequest(request);

      final invite = await inviteFuture.timeout(const Duration(seconds: 15));
      expect(invite.sessionId, 'session-123');
      expect(invite.isIncoming, isTrue);
      expect(invite.isExpired, isFalse);
      expect(invite.device.id, 'remote_inviter');
      expect(invite.device.port, 53320);
      expect(request.response.statusCode, HttpStatus.ok);
      final responseBody =
          jsonDecode(request.response._body.toString()) as Map<String, dynamic>;
      expect(responseBody['deviceId'], 'local_device_123');
    });
    test(
      'responder handshake with correct PIN pairs device and emits success',
      () async {
        final pin = securityService.generate6DigitPin();
        await securityService.storeOutboundAccessToken(
          'remote_scanner_abc',
          'remote-token',
        );
        await securityService.storePeerCertificateFingerprint(
          'remote_scanner_abc',
          '1' * 64,
        );
        final localFingerprint = await securityService
            .getLocalCertificateFingerprint('local_device_123');
        securityService.markFreshOutboundPairProof(
          deviceId: 'remote_scanner_abc',
          peerFingerprint: '1' * 64,
          localFingerprint: localFingerprint,
          accessToken: 'remote-token',
        );

        final successFuture = transferService.handshakeSuccessStream.first;
        final exchange = await _performServerHandshake(
          transferService: transferService,
          pin: pin,
          deviceId: 'remote_scanner_abc',
          isInitiator: false,
        );
        final request = exchange.confirmRequest!;

        final device = await successFuture.timeout(const Duration(seconds: 15));

        expect(device.id, equals('remote_scanner_abc'));
        expect(device.alias, equals('Scanner Device'));
        expect(device.isTrusted, isTrue);

        final isPaired = await securityService.isDevicePaired(
          'remote_scanner_abc',
        );
        expect(isPaired, isTrue);

        expect(request.response.statusCode, equals(HttpStatus.ok));
        final responseBody =
            jsonDecode(request.response._body.toString())
                as Map<String, dynamic>;
        expect(responseBody['status'], 'paired');
      },
    );

    test('initiator handshake waits for reciprocal verification', () async {
      final pin = securityService.generate6DigitPin();
      final pendingFuture = transferService.handshakePendingStream.first;
      final exchange = await _performServerHandshake(
        transferService: transferService,
        pin: pin,
        deviceId: 'remote_initiator',
        isInitiator: true,
      );
      final request = exchange.confirmRequest!;

      final device = await pendingFuture.timeout(const Duration(seconds: 15));
      expect(device.id, 'remote_initiator');
      expect(await securityService.isDevicePaired('remote_initiator'), isFalse);
      final responseBody =
          jsonDecode(request.response._body.toString()) as Map<String, dynamic>;
      expect(responseBody['status'], 'pending_remote');
    });
    test(
      'stale complete credential without a fresh PIN proof stays pending',
      () async {
        const remoteId = 'remote_stale_credential';
        final pin = securityService.generate6DigitPin();
        await securityService.storeOutboundAccessToken(remoteId, 'old-token');
        await securityService.storePeerCertificateFingerprint(
          remoteId,
          '1' * 64,
        );
        expect(
          await securityService.hasCompleteOutboundPairCredential(remoteId),
          isTrue,
        );
        final localFingerprint = await securityService
            .getLocalCertificateFingerprint('local_device_123');
        expect(
          securityService.hasFreshOutboundPairProof(
            deviceId: remoteId,
            peerFingerprint: '1' * 64,
            localFingerprint: localFingerprint,
            accessToken: 'old-token',
          ),
          isFalse,
        );

        final pendingFuture = transferService.handshakePendingStream.first;
        final exchange = await _performServerHandshake(
          transferService: transferService,
          pin: pin,
          deviceId: remoteId,
          isInitiator: false,
        );
        final request = exchange.confirmRequest!;

        expect(
          (await pendingFuture.timeout(const Duration(seconds: 15))).id,
          remoteId,
        );
        final responseBody =
            jsonDecode(request.response._body.toString())
                as Map<String, dynamic>;
        expect(responseBody['status'], 'pending_remote');
        expect(await securityService.isDevicePaired(remoteId), isFalse);
      },
    );
    test(
      'initiator handshake completes when responder verified first',
      () async {
        final pin = securityService.generate6DigitPin();
        await securityService.storeOutboundAccessToken(
          'remote_responder_first',
          'remote-token',
        );
        await securityService.storePeerCertificateFingerprint(
          'remote_responder_first',
          '1' * 64,
        );
        final localFingerprint = await securityService
            .getLocalCertificateFingerprint('local_device_123');
        securityService.markFreshOutboundPairProof(
          deviceId: 'remote_responder_first',
          peerFingerprint: '1' * 64,
          localFingerprint: localFingerprint,
          accessToken: 'remote-token',
        );
        final successFuture = transferService.handshakeSuccessStream.first;
        final exchange = await _performServerHandshake(
          transferService: transferService,
          pin: pin,
          deviceId: 'remote_responder_first',
          isInitiator: true,
        );
        final request = exchange.confirmRequest!;

        final device = await successFuture.timeout(const Duration(seconds: 15));
        expect(device.id, 'remote_responder_first');
        expect(
          await securityService.isDevicePaired('remote_responder_first'),
          isTrue,
        );
        final responseBody =
            jsonDecode(request.response._body.toString())
                as Map<String, dynamic>;
        expect(responseBody['status'], 'paired');
      },
    );
    test(
      'incorrect PIN cannot validate a server offer or create pairing state',
      () async {
        securityService.generate6DigitPin();
        final exchange = await _performServerHandshake(
          transferService: transferService,
          pin: '999999',
          deviceId: 'remote_scanner_abc',
          isInitiator: false,
        );

        final isPaired = await securityService.isDevicePaired(
          'remote_scanner_abc',
        );
        expect(isPaired, isFalse);
        expect(exchange.confirmRequest, isNull);
        expect(exchange.beginRequest.response.statusCode, HttpStatus.ok);
        final responseBody =
            jsonDecode(exchange.beginRequest.response._body.toString())
                as Map<String, dynamic>;
        expect(responseBody['status'], 'challenge');
      },
    );

    test(
      'legacy one-step PIN handshake is rejected without downgrade',
      () async {
        final request = FakeHttpRequest(
          uri: Uri.parse('/api/lan/handshake'),
          method: 'POST',
          body: jsonEncode({
            'deviceId': 'legacy-device',
            'nonce': 'legacy-nonce-with-enough-bytes',
            'pinProof': 'offline-verifier-must-not-be-accepted',
          }),
        );

        transferService.handleHttpRequest(request);
        await request.response.closed.timeout(const Duration(seconds: 2));

        expect(request.response.statusCode, 426);
        expect(await securityService.isDevicePaired('legacy-device'), isFalse);
      },
    );

    test('getOrGenerate6DigitPin reuses active PIN within 1 minute', () {
      final pin1 = securityService.getOrGenerate6DigitPin();
      final pin2 = securityService.getOrGenerate6DigitPin();
      expect(pin1, equals(pin2));
      expect(securityService.pinSecondsRemaining, greaterThan(0));
    });

    test(
      'isDevicePaired removes pairing and returns false after 1 minute',
      () async {
        await securityService.issueInboundAccessToken('remote_scanner_abc');
        await securityService.storeOutboundAccessToken(
          'remote_scanner_abc',
          'remote-token',
        );
        await securityService.storePeerCertificateFingerprint(
          'remote_scanner_abc',
          '0' * 64,
        );
        await securityService.pairDevice('remote_scanner_abc');

        // Initially paired
        expect(
          await securityService.isDevicePaired('remote_scanner_abc'),
          isTrue,
        );

        // Mutate storage data directly to simulate 2 minutes ago
        await securityService.isDevicePaired(
          'remote_scanner_abc',
        ); // Trigger secure storage write
        final storageKey = 'lan_share_paired_device_ids';
        final storage = const FlutterSecureStorage();
        final rawMapStr = await storage.read(key: storageKey);
        expect(rawMapStr, isNotNull);
        final Map<String, dynamic> map = jsonDecode(rawMapStr!);
        map['remote_scanner_abc'] =
            DateTime.now().millisecondsSinceEpoch - 120000; // 2 minutes ago
        await storage.write(key: storageKey, value: jsonEncode(map));

        // Invalidate the in-memory cache so the updated storage is re-read
        securityService.invalidatePairedCache();

        // Now it should have expired and returned false
        expect(
          await securityService.isDevicePaired('remote_scanner_abc'),
          isFalse,
        );
      },
    );

    test('GET /api/lan/check_pair handles paired status check', () async {
      final token = await securityService.issueInboundAccessToken(
        'remote_scanner_abc',
      );
      await securityService.storeOutboundAccessToken(
        'remote_scanner_abc',
        'remote-token',
      );
      await securityService.storePeerCertificateFingerprint(
        'remote_scanner_abc',
        '0' * 64,
      );
      await securityService.pairDevice('remote_scanner_abc');

      final request = FakeHttpRequest(
        uri: Uri.parse('/api/lan/check_pair?deviceId=remote_scanner_abc'),
        method: 'GET',
        body: '',
      );
      request.requestHeaders.set('x-device-id', 'remote_scanner_abc');
      request.requestHeaders.set('authorization', 'Bearer $token');

      transferService.handleHttpRequest(request);

      await Future.delayed(const Duration(milliseconds: 100));

      expect(request.response.statusCode, equals(HttpStatus.ok));
      final responseBody =
          jsonDecode(request.response._body.toString()) as Map<String, dynamic>;
      expect(responseBody['paired'], isTrue);
    });

    test('post-pair APIs reject requests without credentials', () async {
      final endpoints = <({String method, String path, String body})>[
        (method: 'GET', path: '/api/lan/capabilities', body: ''),
        (method: 'GET', path: '/api/lan/check_pair', body: ''),
        (method: 'POST', path: '/api/lan/meta', body: '{}'),
        (method: 'POST', path: '/api/lan/upload', body: ''),
        (method: 'POST', path: '/api/lan/recall', body: '{}'),
      ];

      for (final endpoint in endpoints) {
        final request = FakeHttpRequest(
          uri: Uri.parse(endpoint.path),
          method: endpoint.method,
          body: endpoint.body,
        );

        transferService.handleHttpRequest(request);
        await request.response.closed.timeout(const Duration(seconds: 2));

        expect(
          request.response.statusCode,
          HttpStatus.unauthorized,
          reason: endpoint.path,
        );
      }
    });

    test(
      'valid inbound bearer cannot authorize metadata before reciprocal pairing',
      () async {
        const remoteId = 'remote_pending_pair';
        final inboundToken = await securityService.issueInboundAccessToken(
          remoteId,
        );
        final request = FakeHttpRequest(
          uri: Uri.parse('/api/lan/meta'),
          method: 'POST',
          body: jsonEncode(
            LanMessage(
              id: 'pending-pair-message',
              senderId: remoteId,
              senderAlias: 'Pending Remote',
              receiverId: 'local_device_123',
              payloadType: LanPayloadType.text,
              textContent: 'must remain blocked',
              status: LanTransferStatus.transferring,
              createdAt: DateTime.now(),
              isIncoming: false,
            ).toJson(),
          ),
        );
        request.requestHeaders.set('x-device-id', remoteId);
        request.requestHeaders.set(
          HttpHeaders.authorizationHeader,
          'Bearer $inboundToken',
        );

        expect(await securityService.isDevicePaired(remoteId), isFalse);
        expect(
          await securityService.verifyInboundAccessToken(
            remoteId,
            inboundToken,
          ),
          isTrue,
        );

        transferService.handleHttpRequest(request);
        await request.response.closed.timeout(const Duration(seconds: 2));

        expect(request.response.statusCode, HttpStatus.forbidden);
      },
    );

    test('legacy arbitrary-path download endpoint is unavailable', () async {
      final request = FakeHttpRequest(
        uri: Uri.parse('/api/lan/download?path=C:%5CUsers%5Csecret.txt'),
        method: 'GET',
        body: '',
      );

      transferService.handleHttpRequest(request);
      await request.response.closed.timeout(const Duration(seconds: 2));

      expect(request.response.statusCode, HttpStatus.notFound);
    });

    test(
      'authenticated metadata ignores sender-provided local paths',
      () async {
        const remoteId = 'remote_metadata_sender';
        final inboundToken = await securityService.issueInboundAccessToken(
          remoteId,
        );
        await securityService.storeOutboundAccessToken(
          remoteId,
          'remote-token',
        );
        await securityService.storePeerCertificateFingerprint(
          remoteId,
          '0' * 64,
        );
        await securityService.confirmDevicePairing(remoteId);
        final request = FakeHttpRequest(
          uri: Uri.parse('/api/lan/meta'),
          method: 'POST',
          body: jsonEncode(
            LanMessage(
              id: 'message-123',
              senderId: remoteId,
              senderAlias: 'Remote',
              receiverId: 'local_device_123',
              payloadType: LanPayloadType.text,
              textContent: 'hello',
              localPath: r'C:\Users\secret.txt',
              status: LanTransferStatus.transferring,
              createdAt: DateTime.now(),
              isIncoming: false,
            ).toJson(),
          ),
        );
        request.requestHeaders.set('x-device-id', remoteId);
        request.requestHeaders.set(
          HttpHeaders.authorizationHeader,
          'Bearer $inboundToken',
        );
        final incomingFuture = transferService.incomingMessageStream.first;

        transferService.handleHttpRequest(request);

        final message = await incomingFuture.timeout(
          const Duration(seconds: 2),
        );
        await request.response.closed.timeout(const Duration(seconds: 2));
        expect(request.response.statusCode, HttpStatus.ok);
        expect(message.senderId, remoteId);
        expect(message.localPath, isNull);
        expect(message.status, LanTransferStatus.completed);
      },
    );

    test(
      'LanDiscoveryService removeDevice immediately removes and broadcasts updated list',
      () {
        final discovery = LanDiscoveryService(
          currentDeviceId: 'local_device_123',
          currentDeviceAlias: 'Local Device',
        );
        final device = LanDevice(
          id: 'test_dev_123',
          alias: 'Test Dev',
          ip: '192.168.1.50',
          port: 53317,
          deviceType: LanDeviceType.mobile,
          osName: 'Android',
          lastSeen: DateTime.now(),
        );

        discovery.registerManualDevice(device);
        expect(
          discovery.currentDiscoveredDevices.any((d) => d.id == 'test_dev_123'),
          isTrue,
        );

        discovery.removeDevice('test_dev_123');
        expect(
          discovery.currentDiscoveredDevices.any((d) => d.id == 'test_dev_123'),
          isFalse,
        );
        discovery.dispose();
      },
    );

    test(
      'connectWebSocket returns false and does not crash when server is unreachable',
      () async {
        await HttpOverrides.runWithHttpOverrides(() async {
          final device = LanDevice(
            id: 'unreachable_device',
            alias: 'Offline Device',
            ip: '127.0.0.1',
            port: 9999,
            deviceType: LanDeviceType.mobile,
            osName: 'Android',
            lastSeen: DateTime.now(),
          );

          final result = await transferService.connectWebSocket(device);
          expect(result, isA<NetworkFailure<void>>());
          expect(
            transferService.isWebSocketConnected('unreachable_device'),
            isFalse,
          );
        }, TestHttpOverrides());
      },
    );
  });
}

class MockHttpClient extends Fake implements HttpClient {
  @override
  Future<HttpClientRequest> getUrl(Uri url) {
    throw const SocketException('Connection refused');
  }
}

class TestHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    return MockHttpClient();
  }
}
