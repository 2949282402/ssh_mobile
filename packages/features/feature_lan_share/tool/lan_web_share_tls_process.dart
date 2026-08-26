// Real WebShare TLS/route acceptance worker.
//
// This file is intentionally run with `dart run`, never with `flutter test`.
// It binds a real SecureServerSocket in an ordinary Dart VM process and routes
// requests through the production LanWebShareRequestHandler.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:basic_utils/basic_utils.dart' hide Mac;
import 'package:feature_lan_share/lan_web_share.dart';

final class _Response {
  const _Response(this.statusCode, this.body, this.headers);

  final int statusCode;
  final String body;
  final Map<String, String> headers;
}

final class _WorkerFixture {
  _WorkerFixture();

  final String deviceId = 'local-device';
  final String token = _randomToken();
  final List<LanWebShareMessage> messages = <LanWebShareMessage>[];
  final Completer<File> activeTargetCreated = Completer<File>();
  late final Directory sandbox;
  late final LanWebShareRequestHandler handler;
  late final HttpServer server;
  late final HttpClient client;
  bool active = true;
  var requestSequence = 0;

  Uri get endpoint => Uri(
    scheme: 'https',
    host: InternetAddress.loopbackIPv4.host,
    port: server.port,
  );

  Future<void> start() async {
    sandbox = await Directory.systemTemp.createTemp('lan_web_share_tls_');
    handler = LanWebShareRequestHandler(
      currentDeviceId: deviceId,
      webShareToken: token,
      decryptPayload: (encrypted) async => encrypted,
      hasSufficientSpace: (_) async => true,
      createTargetFile: _createTargetFile,
      deleteFile: _deleteSandboxFile,
      onIncomingMessage: messages.add,
      onMessageProgress: messages.add,
      isActive: () => active,
      buildHtml: () =>
          '<html><body>安全加密 (HTTPS) &lt;script&gt;unsafe alias&lt;/script&gt; '
          '${htmlEscape.convert(token)}</body></html>',
    );

    final certificate = _createCertificate();
    final context = SecurityContext(withTrustedRoots: false)
      ..useCertificateChainBytes(utf8.encode(certificate['cert']!))
      ..usePrivateKeyBytes(utf8.encode(certificate['key']!));
    // This is the intentionally unmocked native TLS bind.  Do not move it to
    // a Flutter test or add retries around it: a bind stall is a test failure.
    server = await HttpServer.bindSecure(
      InternetAddress.loopbackIPv4,
      0,
      context,
      requestClientCertificate: false,
    );
    server.listen((request) {
      unawaited(handler.handleRequest(request));
    });

    client = HttpClient()
      ..badCertificateCallback =
          (X509Certificate certificate, String host, int port) => true;
  }

  Future<File> _createTargetFile(String fileName) async {
    for (var index = 0; index < 100; index++) {
      final suffix = index == 0 ? '' : '-$index';
      final target = File(
        '${sandbox.path}${Platform.pathSeparator}$fileName$suffix',
      );
      try {
        final file = await target.create(exclusive: true);
        if (!activeTargetCreated.isCompleted && fileName == 'active.bin') {
          activeTargetCreated.complete(file);
        }
        return file;
      } on FileSystemException {
        if (!await target.exists()) rethrow;
      }
    }
    throw StateError('Could not reserve a test sandbox file.');
  }

  Future<void> _deleteSandboxFile(String path) async {
    final prefix = '${sandbox.path}${Platform.pathSeparator}';
    if (!path.startsWith(prefix)) {
      throw StateError('WebShare attempted to delete outside its sandbox.');
    }
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  Future<_Response> request(
    String method,
    String path, {
    List<int> body = const <int>[],
    Map<String, String> headers = const <String, String>{},
    bool authenticated = true,
    bool declareLength = true,
  }) async {
    final request = await client.openUrl(method, endpoint.resolve(path));
    request.persistentConnection = false;
    if (authenticated) request.headers.set('x-web-share-token', token);
    for (final entry in headers.entries) {
      request.headers.set(entry.key, entry.value);
    }
    if (declareLength) {
      request.contentLength = body.length;
    } else {
      request.contentLength = -1;
      request.headers.chunkedTransferEncoding = true;
    }
    if (body.isNotEmpty) request.add(body);
    final sequence = ++requestSequence;
    late final HttpClientResponse response;
    try {
      response = await request.close().timeout(const Duration(seconds: 5));
    } on HttpException {
      throw StateError(
        'WebShare request $sequence $method $path closed early.',
      );
    }
    late final List<int> responseBody;
    try {
      responseBody = await response
          .fold<List<int>>(<int>[], (buffer, chunk) => buffer..addAll(chunk))
          .timeout(const Duration(seconds: 5));
    } on HttpException {
      throw StateError(
        'WebShare response $sequence $method $path closed early.',
      );
    }
    return _Response(
      response.statusCode,
      utf8.decode(responseBody),
      <String, String>{
        'content-security-policy':
            response.headers.value('content-security-policy') ?? '',
        'cache-control': response.headers.value('cache-control') ?? '',
      },
    );
  }

  Future<_Response> metadata(
    String id,
    String fileName,
    int fileSize, {
    bool encrypted = false,
    bool authenticated = true,
  }) {
    return request(
      'POST',
      '/api/web/meta',
      body: utf8.encode(
        jsonEncode({
          'id': id,
          'senderId': 'web-browser',
          'senderAlias': 'Browser',
          'receiverId': deviceId,
          'payloadType': 'file',
          'fileName': fileName,
          'fileSize': fileSize,
        }),
      ),
      authenticated: authenticated,
      headers: <String, String>{
        HttpHeaders.contentTypeHeader: ContentType.json.mimeType,
        if (encrypted) 'x-e2e-pubkey': '1',
      },
    );
  }

  Future<void> stop() async {
    active = false;
    client.close(force: true);
    await server.close(force: true);
    await handler.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  }
}

Future<void> main() async {
  final fixture = _WorkerFixture();
  try {
    await fixture.start();
    await _runAssertions(fixture);
  } finally {
    await fixture.stop();
  }
}

Future<void> _runAssertions(_WorkerFixture fixture) async {
  _expect(fixture.endpoint.scheme == 'https', 'worker must use HTTPS');
  _expect(
    fixture.endpoint.port > 0,
    'TLS listener must bind an ephemeral port',
  );

  final withoutToken = await fixture.request('GET', '/');
  _expect(
    withoutToken.statusCode == HttpStatus.unauthorized,
    'page without token must be unauthorized',
  );
  final page = await fixture.request(
    'GET',
    '/?access=${Uri.encodeQueryComponent(fixture.token)}',
    authenticated: false,
  );
  _expect(page.statusCode == HttpStatus.ok, 'authenticated page must succeed');
  _expect(
    page.headers['content-security-policy']!.contains("default-src 'none'") &&
        page.body.contains('安全加密'),
    'page must retain production security policy and HTTPS copy',
  );
  _expect(
    page.body.contains('&lt;script&gt;unsafe alias&lt;/script&gt;') &&
        !page.body.contains('<script>unsafe alias</script>'),
    'page must escape untrusted alias content',
  );
  final unauthorizedMeta = await fixture.metadata(
    'unauthorized',
    'note.txt',
    3,
    authenticated: false,
  );
  _expect(
    unauthorizedMeta.statusCode == HttpStatus.unauthorized,
    'metadata without token must be unauthorized',
  );
  final removedV1 = await fixture.request('POST', '/api/lan/upload');
  _expect(
    removedV1.statusCode == HttpStatus.notFound,
    'removed HTTP binary endpoint must be absent',
  );

  final oversizedMetadata = await fixture.request(
    'POST',
    '/api/web/meta',
    body: List<int>.filled(LanWebShareLimits.maxControlBodyBytes + 1, 0x20),
  );
  _expect(
    oversizedMetadata.statusCode == HttpStatus.requestEntityTooLarge,
    'metadata body must be bounded',
  );
  final unsafePath = await fixture.metadata('unsafe-path', '../escape.txt', 3);
  _expect(
    unsafePath.statusCode == HttpStatus.badRequest,
    'path traversal filename must be rejected',
  );
  _expect(
    await fixture.sandbox.list().toList().then((files) => files.isEmpty),
    'rejected metadata must not create a file',
  );
  final invalidId = await fixture.metadata('bad/id', 'safe.txt', 3);
  _expect(
    invalidId.statusCode == HttpStatus.badRequest,
    'invalid message id must be rejected',
  );
  final tooLarge = await fixture.metadata(
    'too-large',
    'large.bin',
    LanWebShareLimits.maxAdvertisedFileBytes + 1,
  );
  _expect(
    tooLarge.statusCode == HttpStatus.requestEntityTooLarge,
    'advertised file size must be bounded',
  );
  final encryptedTooLarge = await fixture.metadata(
    'encrypted-too-large',
    'large.bin',
    LanWebShareLimits.maxEncryptedUploadBytes + 1,
    encrypted: true,
  );
  _expect(
    encryptedTooLarge.statusCode == HttpStatus.requestEntityTooLarge,
    'encrypted in-memory upload size must be bounded',
  );

  final meta = await fixture.metadata('message-1', 'note.txt', 3);
  _expect(meta.statusCode == HttpStatus.ok, 'valid metadata must be accepted');
  final wrongName = await fixture.request(
    'POST',
    '/api/web/upload',
    headers: <String, String>{
      'x-message-id': 'message-1',
      'x-file-name': Uri.encodeComponent('other.txt'),
    },
  );
  _expect(
    wrongName.statusCode == HttpStatus.badRequest,
    'upload filename must match accepted metadata',
  );
  _expect(
    await fixture.sandbox.list().toList().then((files) => files.isEmpty),
    'mismatched upload must not create a file',
  );
  final upload = await fixture.request(
    'POST',
    '/api/web/upload',
    body: utf8.encode('abc'),
    headers: <String, String>{
      'x-message-id': 'message-1',
      'x-file-name': Uri.encodeComponent('note.txt'),
    },
  );
  _expect(upload.statusCode == HttpStatus.ok, 'valid upload must succeed');
  final uploadedFiles = (await fixture.sandbox.list().toList())
      .whereType<File>()
      .toList();
  _expect(uploadedFiles.length == 1, 'valid upload must create one file');
  _expect(
    await uploadedFiles.single.readAsString() == 'abc',
    'valid upload bytes must be written to sandbox',
  );

  final oversizedMeta = await fixture.metadata('message-2', 'bounded.bin', 3);
  _expect(
    oversizedMeta.statusCode == HttpStatus.ok,
    'second metadata accepted',
  );
  final oversizedUpload = await fixture.request(
    'POST',
    '/api/web/upload',
    body: <int>[1, 2, 3, 4],
    headers: <String, String>{
      'x-message-id': 'message-2',
      'x-file-name': Uri.encodeComponent('bounded.bin'),
    },
  );
  _expect(
    oversizedUpload.statusCode == HttpStatus.requestEntityTooLarge,
    'declared oversized upload must be rejected before reservation',
  );
  final retry = await fixture.request(
    'POST',
    '/api/web/upload',
    body: <int>[1, 2, 3],
    headers: <String, String>{
      'x-message-id': 'message-2',
      'x-file-name': Uri.encodeComponent('bounded.bin'),
    },
  );
  _expect(
    retry.statusCode == HttpStatus.ok,
    'rejected upload must be retryable',
  );

  final chunkedMeta = await fixture.metadata('chunked', 'partial.bin', 3);
  _expect(chunkedMeta.statusCode == HttpStatus.ok, 'chunked metadata accepted');
  final chunkedUpload = await fixture.request(
    'POST',
    '/api/web/upload',
    body: <int>[1, 2, 3, 4],
    declareLength: false,
    headers: <String, String>{
      'x-message-id': 'chunked',
      'x-file-name': Uri.encodeComponent('partial.bin'),
    },
  );
  _expect(
    chunkedUpload.statusCode == HttpStatus.requestEntityTooLarge,
    'chunked overrun must be rejected',
  );
  await _waitFor(
    () => fixture.messages.any(
      (message) =>
          message.id == 'chunked' &&
          message.status == LanWebShareMessageStatus.failed,
    ),
  );
  final chunkedMessages = fixture.messages
      .where((message) => message.id == 'chunked')
      .toList(growable: false);
  _expect(
    chunkedMessages.any(
      (message) =>
          message.status == LanWebShareMessageStatus.failed &&
          message.bytesTransferred > 3 &&
          message.localPath == null,
    ),
    'chunked overrun must report failed progress with no path: '
    '${chunkedMessages.map((message) => '${message.status.name}:${message.bytesTransferred}:${message.localPath != null}').join(',')}',
  );
  _expect(
    await fixture.sandbox.list().toList().then(
      (files) => files.whereType<File>().every((file) {
        return !file.path.endsWith('partial.bin');
      }),
    ),
    'chunked overrun must delete its partial sandbox file',
  );

  final unknown = await fixture.request(
    'POST',
    '/api/web/upload',
    headers: <String, String>{
      'x-message-id': 'unknown-message',
      'x-file-name': Uri.encodeComponent('unknown.bin'),
    },
  );
  _expect(
    unknown.statusCode == HttpStatus.conflict,
    'upload without accepted metadata must be rejected',
  );

  final activeMeta = await fixture.metadata('active', 'active.bin', 3);
  _expect(activeMeta.statusCode == HttpStatus.ok, 'active metadata accepted');
  final activeRequest = await fixture.client.postUrl(
    fixture.endpoint.resolve('/api/web/upload'),
  );
  activeRequest.headers.set('x-web-share-token', fixture.token);
  activeRequest.headers.set('x-message-id', 'active');
  activeRequest.headers.set('x-file-name', Uri.encodeComponent('active.bin'));
  activeRequest.contentLength = 3;
  activeRequest.add(<int>[1]);
  await activeRequest.flush();
  await fixture.activeTargetCreated.future.timeout(const Duration(seconds: 2));

  final replay = await fixture.metadata('active', 'active.bin', 3);
  _expect(
    replay.statusCode == HttpStatus.conflict,
    'active metadata replay rejected',
  );
  for (
    var index = 1;
    index < LanWebShareRequestHandler.maxPendingUploads;
    index++
  ) {
    final pending = await fixture.metadata(
      'pending-$index',
      'pending-$index.bin',
      1,
    );
    _expect(pending.statusCode == HttpStatus.ok, 'pending-$index accepted');
  }
  final overflow = await fixture.metadata('overflow', 'overflow.bin', 1);
  _expect(
    overflow.statusCode == HttpStatus.tooManyRequests,
    'active and pending uploads must share one capacity budget',
  );
  activeRequest.add(<int>[2, 3]);
  final activeResponse = await activeRequest.close().timeout(
    const Duration(seconds: 5),
  );
  await activeResponse.drain<void>();

  fixture.active = false;
  final stopped = await fixture.request(
    'GET',
    '/?access=${Uri.encodeQueryComponent(fixture.token)}',
    authenticated: false,
  );
  _expect(
    stopped.statusCode == HttpStatus.serviceUnavailable,
    'stopped WebShare must reject late requests',
  );
}

Map<String, String> _createCertificate() {
  final pair = CryptoUtils.generateEcKeyPair();
  final privateKey = pair.privateKey as ECPrivateKey;
  final publicKey = pair.publicKey as ECPublicKey;
  final csr = X509Utils.generateEccCsrPem(
    {'CN': 'lan-web-share-worker'},
    privateKey,
    publicKey,
  );
  return <String, String>{
    'cert': X509Utils.generateSelfSignedCertificate(privateKey, csr, 3650),
    'key': CryptoUtils.encodeEcPrivateKeyToPem(privateKey),
  };
}

String _randomToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(32, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

void _expect(bool condition, String message) {
  if (!condition) throw StateError(message);
}

Future<void> _waitFor(FutureOr<bool> Function() predicate) async {
  for (var attempt = 0; attempt < 200; attempt++) {
    if (await predicate()) return;
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  throw StateError('Timed out waiting for WebShare progress.');
}
