// v1 WebShare 请求大小、路径和规范化错误安全测试。

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/lan_share/lan_discovery_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_security_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_share_models.dart';
import 'package:ssh_mobile/services/lan_share/lan_storage_service.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_protocol.dart';
import 'package:ssh_mobile/services/lan_share/lan_transfer_service.dart';
import 'package:ssh_mobile/services/network/network_models.dart';

class _HttpResult {
  final int statusCode;
  final String body;
  final String? cacheControl;
  final String? corsOrigin;
  final String? contentSecurityPolicy;

  const _HttpResult({
    required this.statusCode,
    required this.body,
    this.cacheControl,
    this.corsOrigin,
    this.contentSecurityPolicy,
  });
}

class _LoopbackHttpOverrides extends HttpOverrides {}

class _WebShareFixture {
  late final Directory sandbox;
  late final LanSecurityService securityService;
  late final LanStorageService storageService;
  late final LanTransferService transferService;
  late final LanDiscoveryService discoveryService;
  late final HttpClient client;
  late final Uri webUrl;
  late final String token;

  Future<void> start() async {
    FlutterSecureStorage.setMockInitialValues({});
    sandbox = await Directory.systemTemp.createTemp('lan_web_share_test_');
    securityService = LanSecurityService();
    storageService = LanStorageService(
      sandboxDirectoryProvider: () async => sandbox,
      freeDiskSpaceMbProvider: () async => 1024,
    );
    transferService = LanTransferService(
      currentDeviceId: 'local-device',
      securityService: securityService,
      storageService: storageService,
    );
    discoveryService = LanDiscoveryService(
      currentDeviceId: 'local-device',
      currentDeviceAlias: '<script>unsafe alias</script>',
    )..setCustomIp('127.0.0.1');
    final startResult = await discoveryService.startWebShareServer(
      port: 0,
      securityService: securityService,
      storageService: storageService,
      transferService: transferService,
    );
    expect(startResult, isA<NetworkSuccess<String>>());
    webUrl = Uri.parse((startResult as NetworkSuccess<String>).data);
    token = webUrl.queryParameters['access']!;
    client = _LoopbackHttpOverrides().createHttpClient(null);
  }

  Uri endpoint(String path) => Uri(
    scheme: webUrl.scheme,
    host: webUrl.host,
    port: webUrl.port,
    path: path,
  );

  Future<_HttpResult> get(Uri uri) async {
    final request = await client.getUrl(uri);
    final response = await request.close();
    final body = await utf8.decoder.bind(response).join();
    return _HttpResult(
      statusCode: response.statusCode,
      body: body,
      cacheControl: response.headers.value(HttpHeaders.cacheControlHeader),
      corsOrigin: response.headers.value('access-control-allow-origin'),
      contentSecurityPolicy: response.headers.value('content-security-policy'),
    );
  }

  Future<_HttpResult> post(
    String path,
    List<int> body, {
    bool authenticated = true,
    bool declareLength = true,
    Map<String, String> headers = const {},
  }) async {
    final request = await client.postUrl(endpoint(path));
    if (authenticated) {
      request.headers.set('x-web-share-token', token);
    }
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (declareLength) request.contentLength = body.length;
    request.add(body);
    final response = await request.close();
    final responseBody = await utf8.decoder.bind(response).join();
    return _HttpResult(
      statusCode: response.statusCode,
      body: responseBody,
      cacheControl: response.headers.value(HttpHeaders.cacheControlHeader),
      corsOrigin: response.headers.value('access-control-allow-origin'),
    );
  }

  List<int> metadata({
    required String id,
    required String fileName,
    required int fileSize,
  }) {
    return utf8.encode(
      jsonEncode({
        'id': id,
        'senderId': 'web-browser',
        'senderAlias': 'Browser',
        'receiverId': 'local-device',
        'payloadType': 'file',
        'fileName': fileName,
        'fileSize': fileSize,
      }),
    );
  }

  Future<_HttpResult> postMetadata({
    required String id,
    required String fileName,
    required int fileSize,
    bool authenticated = true,
  }) {
    return post(
      '/api/web/meta',
      metadata(id: id, fileName: fileName, fileSize: fileSize),
      authenticated: authenticated,
      headers: {HttpHeaders.contentTypeHeader: ContentType.json.mimeType},
    );
  }

  Future<void> close() async {
    client.close(force: true);
    await discoveryService.stopWebShareServer();
    transferService.dispose();
    discoveryService.dispose();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  }
}

/// 执行 WebShare 有界请求体和安全响应测试。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _WebShareFixture fixture;

  setUp(() async {
    fixture = _WebShareFixture();
    await fixture.start();
  });

  tearDown(() async {
    await fixture.close();
  });

  test(
    'Web page and control APIs require the ephemeral capability token',
    () async {
      expect(fixture.webUrl.port, greaterThan(0));
      expect(fixture.token, hasLength(43));
      expect(
        fixture.webUrl.queryParameters['certFingerprint'],
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );

      final withoutToken = await fixture.get(fixture.endpoint('/'));
      expect(withoutToken.statusCode, HttpStatus.unauthorized);

      final page = await fixture.get(fixture.webUrl);
      expect(page.statusCode, HttpStatus.ok);
      expect(page.cacheControl, contains('no-store'));
      expect(page.corsOrigin, isNull);
      expect(page.contentSecurityPolicy, contains("default-src 'none'"));
      expect(page.body, contains(jsonEncode(fixture.token)));
      expect(page.body, contains('&lt;script&gt;unsafe alias&lt;/script&gt;'));
      expect(page.body, isNot(contains('<script>unsafe alias</script>')));

      final unauthorizedMeta = await fixture.postMetadata(
        id: 'unauthorized',
        fileName: 'note.txt',
        fileSize: 3,
        authenticated: false,
      );
      expect(unauthorizedMeta.statusCode, HttpStatus.unauthorized);
    },
  );

  test('metadata is bounded and rejects unsafe paths', () async {
    final oversized = await fixture.post(
      '/api/web/meta',
      List<int>.filled(LanTransferProtocolGuard.maxControlBodyBytes + 1, 0x20),
    );
    expect(oversized.statusCode, HttpStatus.requestEntityTooLarge);

    final unsafePath = await fixture.postMetadata(
      id: 'unsafe-path',
      fileName: '../escape.txt',
      fileSize: 3,
    );
    expect(unsafePath.statusCode, HttpStatus.badRequest);
    expect(await fixture.sandbox.list().toList(), isEmpty);
  });

  test('encrypted metadata enforces the in-memory file limit', () async {
    final publicKey = await fixture.securityService
        .getStaticX25519PublicKeyBytes();
    final encrypted = await fixture.securityService.encryptE2EFor(
      Uint8List.fromList(
        fixture.metadata(
          id: 'encrypted-too-large',
          fileName: 'large.bin',
          fileSize: LanTransferProtocolGuard.maxEncryptedUploadBytes + 1,
        ),
      ),
      publicKey,
    );
    final response = await fixture.post(
      '/api/web/meta',
      encrypted,
      headers: {'x-e2e-pubkey': '1'},
    );

    expect(response.statusCode, HttpStatus.requestEntityTooLarge);
    expect(await fixture.sandbox.list().toList(), isEmpty);
  });

  test(
    'upload must match accepted metadata and streams into sandbox',
    () async {
      final meta = await fixture.postMetadata(
        id: 'message-1',
        fileName: 'note.txt',
        fileSize: 3,
      );
      expect(meta.statusCode, HttpStatus.ok);

      final wrongName = await fixture.post(
        '/api/web/upload',
        utf8.encode('abc'),
        headers: {
          'x-message-id': 'message-1',
          'x-file-name': Uri.encodeComponent('other.txt'),
        },
      );
      expect(wrongName.statusCode, HttpStatus.badRequest);
      expect(await fixture.sandbox.list().toList(), isEmpty);

      final upload = await fixture.post(
        '/api/web/upload',
        utf8.encode('abc'),
        headers: {
          'x-message-id': 'message-1',
          'x-file-name': Uri.encodeComponent('note.txt'),
        },
      );
      expect(upload.statusCode, HttpStatus.ok);
      expect(upload.body, isNot(contains('path')));

      final entities = await fixture.sandbox.list().toList();
      final files = entities.whereType<File>().toList();
      expect(files, hasLength(1));
      expect(await files.single.readAsString(), 'abc');
    },
  );

  test('oversized upload is rejected before a file is reserved', () async {
    final meta = await fixture.postMetadata(
      id: 'message-2',
      fileName: 'bounded.bin',
      fileSize: 3,
    );
    expect(meta.statusCode, HttpStatus.ok);

    final oversized = await fixture.post(
      '/api/web/upload',
      [1, 2, 3, 4],
      headers: {
        'x-message-id': 'message-2',
        'x-file-name': Uri.encodeComponent('bounded.bin'),
      },
    );
    expect(oversized.statusCode, HttpStatus.requestEntityTooLarge);
    expect(await fixture.sandbox.list().toList(), isEmpty);

    final retry = await fixture.post(
      '/api/web/upload',
      [1, 2, 3],
      headers: {
        'x-message-id': 'message-2',
        'x-file-name': Uri.encodeComponent('bounded.bin'),
      },
    );
    expect(retry.statusCode, HttpStatus.ok);
  });

  test('chunked overrun deletes the partially written sandbox file', () async {
    final meta = await fixture.postMetadata(
      id: 'message-chunked',
      fileName: 'partial.bin',
      fileSize: 3,
    );
    expect(meta.statusCode, HttpStatus.ok);

    final failedProgress = fixture.transferService.messageProgressStream
        .firstWhere(
          (message) =>
              message.id == 'message-chunked' &&
              message.status == LanTransferStatus.failed,
        )
        .timeout(const Duration(seconds: 2));

    _HttpResult? oversized;
    Object? connectionError;
    try {
      oversized = await fixture.post(
        '/api/web/upload',
        [1, 2, 3, 4],
        declareLength: false,
        headers: {
          'x-message-id': 'message-chunked',
          'x-file-name': Uri.encodeComponent('partial.bin'),
        },
      );
    } on HttpException catch (error) {
      // The server may abort a chunked request as soon as it crosses the
      // accepted length instead of draining attacker-controlled extra bytes.
      connectionError = error;
    }

    expect(
      oversized?.statusCode == HttpStatus.requestEntityTooLarge ||
          connectionError is HttpException,
      isTrue,
    );
    final failedMessage = await failedProgress;
    expect(failedMessage.isIncoming, isTrue);
    expect(failedMessage.bytesTransferred, greaterThan(3));
    expect(failedMessage.localPath, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await fixture.sandbox.list().toList(), isEmpty);
  });

  test('upload without accepted metadata cannot create a file', () async {
    final response = await fixture.post(
      '/api/web/upload',
      [1, 2, 3],
      headers: {
        'x-message-id': 'unknown-message',
        'x-file-name': Uri.encodeComponent('unknown.bin'),
      },
    );

    expect(response.statusCode, HttpStatus.conflict);
    expect(await fixture.sandbox.list().toList(), isEmpty);
  });
}
