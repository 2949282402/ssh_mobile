import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/lan_web_share.dart';
import 'package:test/test.dart';

abstract base class _Fake {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected fake invocation: $invocation');
}

final class _Headers implements HttpHeaders {
  final Map<String, List<String>> _values = <String, List<String>>{};

  @override
  DateTime? date;
  @override
  DateTime? expires;
  @override
  DateTime? ifModifiedSince;
  @override
  String? host;
  @override
  int? port;
  @override
  ContentType? contentType;
  @override
  int contentLength = -1;
  @override
  bool persistentConnection = true;
  @override
  bool chunkedTransferEncoding = false;

  String _key(String name) => name.toLowerCase();

  @override
  List<String>? operator [](String name) => _values[_key(name)];

  @override
  String? value(String name) => _values[_key(name)]?.firstOrNull;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values.putIfAbsent(_key(name), () => <String>[]).add('$value');
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[_key(name)] = <String>['$value'];
  }

  @override
  void remove(String name, Object value) {
    _values[_key(name)]?.remove('$value');
  }

  @override
  void removeAll(String name) => _values.remove(_key(name));

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach(action);
  }

  @override
  void noFolding(String name) {}

  @override
  void clear() => _values.clear();
}

final class _Response extends _Fake implements HttpResponse {
  final _Headers responseHeaders = _Headers();
  final StringBuffer body = StringBuffer();
  final Completer<void> closed = Completer<void>();

  @override
  int statusCode = HttpStatus.ok;
  @override
  bool persistentConnection = true;

  @override
  HttpHeaders get headers => responseHeaders;

  @override
  void write(Object? object) => body.write(object);

  @override
  Future<HttpResponse> close([Object? data]) async {
    if (data != null) body.write(data);
    if (!closed.isCompleted) closed.complete();
    return this;
  }
}

final class _Request extends _Fake implements HttpRequest {
  _Request({
    required this._method,
    required this._uri,
    required this._headers,
    List<int> body = const <int>[],
    Stream<Uint8List>? bodyStream,
    int? contentLength,
  }) : _body = bodyStream ?? Stream<Uint8List>.value(Uint8List.fromList(body)),
       _contentLength = contentLength ?? body.length;

  final String _method;
  final Uri _uri;
  final _Headers _headers;
  final Stream<Uint8List> _body;
  final int _contentLength;
  final _Response _response = _Response();

  @override
  String get method => _method;
  @override
  Uri get uri => _uri;
  @override
  HttpHeaders get headers => _headers;
  @override
  int get contentLength => _contentLength;
  @override
  _Response get response => _response;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return _body.listen(
      onData,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  @override
  Stream<Uint8List> timeout(
    Duration timeLimit, {
    void Function(EventSink<Uint8List> sink)? onTimeout,
  }) => _body.timeout(timeLimit, onTimeout: onTimeout);
}

final class _Fixture {
  _Fixture();

  final List<LanWebShareMessage> messages = <LanWebShareMessage>[];
  final String deviceId = 'local-device';
  final String token = 'test-token';
  late Directory sandbox;
  late LanWebShareRequestHandler handler;
  bool active = true;
  bool spaceAvailable = true;
  bool decryptUploadEnvelope = false;
  bool throwOnIncomingMessage = false;

  Future<void> setUp() async {
    sandbox = await Directory.systemTemp.createTemp('lan_web_share_handler_');
    handler = LanWebShareRequestHandler(
      currentDeviceId: deviceId,
      webShareToken: token,
      decryptPayload: (payload) async {
        if (decryptUploadEnvelope && payload.length == 63) {
          return Uint8List.fromList(payload.sublist(60));
        }
        return payload;
      },
      hasSufficientSpace: (_) async => spaceAvailable,
      createTargetFile: (fileName) async {
        final file = File('${sandbox.path}${Platform.pathSeparator}$fileName');
        return file..createSync(exclusive: true);
      },
      deleteFile: (path) async {
        final file = File(path);
        if (await file.exists()) await file.delete();
      },
      onIncomingMessage: (message) {
        if (throwOnIncomingMessage) {
          throw StateError('test callback failure');
        }
        messages.add(message);
      },
      onMessageProgress: messages.add,
      isActive: () => active,
      buildHtml: () => '<html>safe page</html>',
    );
  }

  Future<void> tearDown() async {
    active = false;
    await handler.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  }

  Future<_Response> dispatch({
    String method = 'POST',
    String path = '/api/web/meta',
    List<int> body = const <int>[],
    Stream<Uint8List>? bodyStream,
    int? contentLength,
    bool authenticated = true,
    Map<String, String> headers = const <String, String>{},
  }) async {
    final requestHeaders = _Headers();
    if (authenticated) {
      requestHeaders.set('x-web-share-token', token);
    }
    for (final entry in headers.entries) {
      requestHeaders.set(entry.key, entry.value);
    }
    final request = _Request(
      method: method,
      uri: Uri.parse(path),
      headers: requestHeaders,
      body: body,
      bodyStream: bodyStream,
      contentLength: contentLength,
    );
    await handler.handleRequest(request);
    return request.response;
  }

  Future<_Response> metadata(
    String id,
    String fileName,
    int fileSize, {
    bool authenticated = true,
    Map<String, String> headers = const <String, String>{},
  }) {
    return dispatch(
      authenticated: authenticated,
      headers: headers,
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
    );
  }
}

void main() {
  late _Fixture fixture;

  setUp(() async {
    fixture = _Fixture();
    await fixture.setUp();
  });

  tearDown(() => fixture.tearDown());

  test('public helpers reject malformed values without leaking payloads', () {
    final exception = const LanWebShareHttpException(
      HttpStatus.badRequest,
      'invalid',
    );
    expect(exception.toString(), 'LanWebShareHttpException(400, invalid)');
    expect(fixture.handler.validateMessageId('valid-id_1'), 'valid-id_1');
    expect(
      () => fixture.handler.validateMessageId('bad/id'),
      throwsA(isA<LanWebShareHttpException>()),
    );
    expect(fixture.handler.validateFileName('safe.txt'), 'safe.txt');
    expect(
      () => fixture.handler.validateFileName('../escape.txt'),
      throwsA(isA<LanWebShareHttpException>()),
    );
    expect(
      fixture.handler.decodeFileNameHeader(Uri.encodeComponent('safe.txt')),
      'safe.txt',
    );
    expect(
      () => fixture.handler.decodeFileNameHeader('%'),
      throwsA(isA<LanWebShareHttpException>()),
    );
    expect(fixture.handler.decodeJson(utf8.encode('{"ok":true}')), {
      'ok': true,
    });
    expect(
      () => fixture.handler.decodeJson(utf8.encode('[]')),
      throwsA(isA<LanWebShareHttpException>()),
    );
  });

  test(
    'token, page, route absence, and early header failures are bounded',
    () async {
      final unauthorized = await fixture.dispatch(
        method: 'GET',
        path: '/',
        authenticated: false,
      );
      expect(unauthorized.statusCode, HttpStatus.unauthorized);

      final unauthorizedWithLargeBody = await fixture.dispatch(
        authenticated: false,
        body: List<int>.filled(
          LanWebShareLimits.maxRejectedBodyDrainBytes + 1,
          0x20,
        ),
        contentLength: LanWebShareLimits.maxRejectedBodyDrainBytes + 1,
      );
      expect(unauthorizedWithLargeBody.statusCode, HttpStatus.unauthorized);
      expect(unauthorizedWithLargeBody.persistentConnection, isFalse);
      expect(
        unauthorizedWithLargeBody.responseHeaders.value(
          HttpHeaders.connectionHeader,
        ),
        'close',
      );

      final page = await fixture.dispatch(
        method: 'GET',
        path: '/?access=${fixture.token}',
        authenticated: false,
      );
      expect(page.statusCode, HttpStatus.ok);
      expect(
        page.responseHeaders.value('content-security-policy'),
        contains("default-src 'none'"),
      );

      final notFound = await fixture.dispatch(
        method: 'POST',
        path: '/api/lan/upload',
        body: <int>[1, 2, 3],
      );
      expect(notFound.statusCode, HttpStatus.notFound);

      final oversized = await fixture.dispatch(
        body: List<int>.filled(LanWebShareLimits.maxControlBodyBytes + 1, 0x20),
        contentLength: LanWebShareLimits.maxControlBodyBytes + 1,
      );
      expect(oversized.statusCode, HttpStatus.requestEntityTooLarge);
      expect(oversized.persistentConnection, isFalse);
      expect(
        oversized.responseHeaders.value(HttpHeaders.connectionHeader),
        'close',
      );

      final chunkedOverrun = await fixture.dispatch(
        body: List<int>.filled(LanWebShareLimits.maxControlBodyBytes + 1, 0x20),
        contentLength: -1,
      );
      expect(chunkedOverrun.statusCode, HttpStatus.requestEntityTooLarge);
      expect(chunkedOverrun.persistentConnection, isFalse);
      expect(
        chunkedOverrun.responseHeaders.value(HttpHeaders.connectionHeader),
        'close',
      );

      final badEncryption = await fixture.metadata(
        'bad-encryption',
        'safe.txt',
        1,
        headers: <String, String>{'x-e2e-pubkey': 'invalid'},
      );
      expect(badEncryption.statusCode, HttpStatus.badRequest);
      expect(badEncryption.persistentConnection, isTrue);

      final pendingBody = StreamController<Uint8List>();
      final drainStopwatch = Stopwatch()..start();
      final rejectedWithoutLength = fixture.dispatch(
        authenticated: false,
        bodyStream: pendingBody.stream,
        contentLength: -1,
      );
      final rejectedResponse = await rejectedWithoutLength;
      drainStopwatch.stop();
      await pendingBody.close();
      expect(rejectedResponse.statusCode, HttpStatus.unauthorized);
      expect(rejectedResponse.persistentConnection, isFalse);
      expect(drainStopwatch.elapsed, lessThan(const Duration(seconds: 3)));
    },
  );

  test(
    'metadata bounds, encrypted size, storage, and duplicate leases fail closed',
    () async {
      final unsafe = await fixture.metadata('unsafe', '../escape.txt', 3);
      expect(unsafe.statusCode, HttpStatus.badRequest);
      expect(await fixture.sandbox.list().toList(), isEmpty);

      final encryptedTooLarge = await fixture.metadata(
        'encrypted-large',
        'large.bin',
        LanWebShareLimits.maxEncryptedUploadBytes + 1,
        headers: <String, String>{'x-e2e-pubkey': '1'},
      );
      expect(encryptedTooLarge.statusCode, HttpStatus.requestEntityTooLarge);

      fixture.spaceAvailable = false;
      final noSpace = await fixture.metadata('no-space', 'no-space.bin', 3);
      expect(noSpace.statusCode, HttpStatus.insufficientStorage);
      fixture.spaceAvailable = true;

      final accepted = await fixture.metadata('duplicate', 'file.txt', 3);
      expect(accepted.statusCode, HttpStatus.ok);
      final replay = await fixture.metadata('duplicate', 'file.txt', 3);
      expect(replay.statusCode, HttpStatus.conflict);
    },
  );

  test(
    'upload mismatch, declared overrun, chunked overrun, and cleanup are bounded',
    () async {
      expect(
        (await fixture.metadata('upload', 'file.txt', 3)).statusCode,
        HttpStatus.ok,
      );
      final mismatch = await fixture.dispatch(
        path: '/api/web/upload',
        body: utf8.encode('abc'),
        headers: <String, String>{
          'x-message-id': 'upload',
          'x-file-name': Uri.encodeComponent('other.txt'),
        },
      );
      expect(mismatch.statusCode, HttpStatus.badRequest);
      expect(mismatch.persistentConnection, isTrue);

      final drainedBody = StreamController<Uint8List>();
      final mismatchWithDrainedBody = fixture.dispatch(
        path: '/api/web/upload',
        bodyStream: drainedBody.stream,
        contentLength: 4,
        headers: <String, String>{
          'x-message-id': 'upload',
          'x-file-name': Uri.encodeComponent('other.txt'),
        },
      );
      drainedBody
        ..add(Uint8List.fromList(<int>[1, 2, 3, 4]))
        ..close();
      final drainedResponse = await mismatchWithDrainedBody;
      expect(drainedResponse.statusCode, HttpStatus.badRequest);
      expect(drainedResponse.persistentConnection, isTrue);

      final declaredOverrun = await fixture.dispatch(
        path: '/api/web/upload',
        body: <int>[1, 2, 3, 4],
        headers: <String, String>{
          'x-message-id': 'upload',
          'x-file-name': Uri.encodeComponent('file.txt'),
        },
      );
      expect(declaredOverrun.statusCode, HttpStatus.requestEntityTooLarge);

      expect(
        (await fixture.metadata('chunked', 'chunked.bin', 3)).statusCode,
        HttpStatus.ok,
      );
      final chunked = await fixture.dispatch(
        path: '/api/web/upload',
        body: <int>[1, 2, 3, 4],
        contentLength: -1,
        headers: <String, String>{
          'x-message-id': 'chunked',
          'x-file-name': Uri.encodeComponent('chunked.bin'),
        },
      );
      expect(chunked.statusCode, HttpStatus.requestEntityTooLarge);
      expect(chunked.persistentConnection, isFalse);
      expect(
        chunked.responseHeaders.value(HttpHeaders.connectionHeader),
        'close',
      );
      expect(
        fixture.messages.any(
          (message) =>
              message.id == 'chunked' &&
              message.status == LanWebShareMessageStatus.failed &&
              message.bytesTransferred > 3 &&
              message.localPath == null,
        ),
        isTrue,
      );
      expect(await fixture.sandbox.list().toList(), isEmpty);
    },
  );

  test(
    'accepted upload writes bytes and unknown upload never creates a file',
    () async {
      expect(
        (await fixture.metadata('valid', 'note.txt', 3)).statusCode,
        HttpStatus.ok,
      );
      final upload = await fixture.dispatch(
        path: '/api/web/upload',
        body: utf8.encode('abc'),
        headers: <String, String>{
          'x-message-id': 'valid',
          'x-file-name': Uri.encodeComponent('note.txt'),
        },
      );
      expect(upload.statusCode, HttpStatus.ok);
      final files = (await fixture.sandbox.list().toList())
          .whereType<File>()
          .toList();
      expect(files, hasLength(1));
      expect(await files.single.readAsString(), 'abc');

      final unknown = await fixture.dispatch(
        path: '/api/web/upload',
        body: <int>[1, 2, 3],
        headers: <String, String>{
          'x-message-id': 'unknown',
          'x-file-name': Uri.encodeComponent('unknown.bin'),
        },
      );
      expect(unknown.statusCode, HttpStatus.conflict);
      expect(
        (await fixture.sandbox.list().toList()).whereType<File>(),
        hasLength(1),
      );
    },
  );

  test('encrypted upload decrypts within the bounded route', () async {
    fixture.decryptUploadEnvelope = true;
    expect(
      (await fixture.metadata(
        'encrypted',
        'encrypted.txt',
        3,
        headers: <String, String>{'x-e2e-pubkey': '1'},
      )).statusCode,
      HttpStatus.ok,
    );
    final encryptedBody = <int>[
      ...List<int>.filled(60, 0x01),
      ...utf8.encode('abc'),
    ];
    final upload = await fixture.dispatch(
      path: '/api/web/upload',
      body: encryptedBody,
      headers: <String, String>{
        'x-message-id': 'encrypted',
        'x-file-name': Uri.encodeComponent('encrypted.txt'),
        'x-e2e-pubkey': '1',
      },
    );
    expect(upload.statusCode, HttpStatus.ok);
    expect(
      await File(
        '${fixture.sandbox.path}${Platform.pathSeparator}encrypted.txt',
      ).readAsString(),
      'abc',
    );
  });

  test(
    'adapter failures return bounded internal errors after body consumption',
    () async {
      fixture.throwOnIncomingMessage = true;
      final response = await fixture.metadata('callback-failure', 'x.txt', 1);
      expect(response.statusCode, HttpStatus.internalServerError);
      expect(response.persistentConnection, isTrue);
    },
  );

  test(
    'close during an active upload invalidates the lease and removes partial data',
    () async {
      expect(
        (await fixture.metadata('active', 'active.bin', 3)).statusCode,
        HttpStatus.ok,
      );
      final body = StreamController<Uint8List>();
      final requestHeaders = _Headers()
        ..set('x-web-share-token', fixture.token)
        ..set('x-message-id', 'active')
        ..set('x-file-name', Uri.encodeComponent('active.bin'));
      final request = _Request(
        method: 'POST',
        uri: Uri.parse('/api/web/upload'),
        headers: requestHeaders,
        bodyStream: body.stream,
        contentLength: 3,
      );
      final operation = fixture.handler.handleRequest(request);
      await Future<void>.delayed(Duration.zero);
      fixture.active = false;
      await fixture.handler.close();
      body
        ..add(Uint8List.fromList(<int>[1, 2, 3]))
        ..close();
      await operation;
      expect(request.response.statusCode, HttpStatus.serviceUnavailable);
      expect(await fixture.sandbox.list().toList(), isEmpty);
    },
  );
}
