// Deterministic WebShare request-boundary safety tests.
//
// The real HTTPS listener is exercised by the feature package's plain Dart
// worker, which CI runs in an ordinary OS process. This suite calls the same
// production request handler with in-memory HttpRequest/HttpResponse fakes.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:feature_lan_share/lan_web_share.dart';

class _Result {
  const _Result(this.statusCode, this.body, this.headers);

  final int statusCode;
  final String body;
  final _Headers headers;
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

final class _Response extends Fake implements HttpResponse {
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

final class _Request extends Fake implements HttpRequest {
  _Request({
    required this.requestMethod,
    required this.requestUri,
    required this.requestHeaders,
    required List<int> body,
    int? contentLength,
  }) : requestBody = Stream<Uint8List>.value(Uint8List.fromList(body)),
       requestContentLength = contentLength ?? body.length;

  final String requestMethod;
  final Uri requestUri;
  final _Headers requestHeaders;
  final Stream<Uint8List> requestBody;
  final int requestContentLength;
  final _Response _response = _Response();

  @override
  String get method => requestMethod;

  @override
  Uri get uri => requestUri;

  @override
  HttpHeaders get headers => requestHeaders;

  @override
  int get contentLength => requestContentLength;

  @override
  _Response get response => _response;

  @override
  StreamSubscription<Uint8List> listen(
    void Function(Uint8List)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) {
    return requestBody.listen(
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
  }) {
    return requestBody.timeout(timeLimit, onTimeout: onTimeout);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory sandbox;
  late LanStorageService storageService;
  late LanWebShareRequestHandler handler;
  var active = true;

  setUp(() async {
    sandbox = await Directory.systemTemp.createTemp('lan_web_share_boundary_');
    storageService = LanStorageService(
      sandboxDirectoryProvider: () async => sandbox,
      freeDiskSpaceMbProvider: () async => 1024,
    );
    active = true;
    handler = LanWebShareRequestHandler(
      currentDeviceId: 'local-device',
      webShareToken: 'boundary-token',
      decryptPayload: (encrypted) async => encrypted,
      hasSufficientSpace: storageService.hasSufficientSpace,
      createTargetFile: storageService.getSandboxTargetFile,
      deleteFile: (path) async {
        await storageService.deleteSandboxFile(path);
      },
      onIncomingMessage: (_) {},
      onMessageProgress: (_) {},
      isActive: () => active,
      buildHtml: () =>
          '<html>boundary-token &lt;script&gt;unsafe alias&lt;/script&gt;</html>',
    );
    _handlerForTest = handler;
  });

  tearDown(() async {
    await handler.close();
    if (await sandbox.exists()) await sandbox.delete(recursive: true);
  });

  test('routes and authenticates without a native listener', () async {
    final unauthorized = await _dispatch(
      method: 'GET',
      path: '/',
      authenticated: false,
    );
    expect(unauthorized.statusCode, HttpStatus.unauthorized);
    expect(
      unauthorized.headers.value(HttpHeaders.cacheControlHeader),
      'no-store',
    );

    final page = await _dispatch(
      method: 'GET',
      path: '/?access=boundary-token',
      authenticated: false,
    );
    expect(page.statusCode, HttpStatus.ok);
    expect(
      page.headers.value('content-security-policy'),
      contains("default-src 'none'"),
    );
    expect(page.body, contains('boundary-token'));
    expect(page.body, contains('&lt;script&gt;unsafe alias&lt;/script&gt;'));
    expect(page.body, isNot(contains('<script>unsafe alias</script>')));

    final notFound = await _dispatch(
      method: 'POST',
      path: '/api/lan/upload',
      body: const <int>[],
    );
    expect(notFound.statusCode, HttpStatus.notFound);

    active = false;
    final stopped = await _dispatch(
      method: 'GET',
      path: '/?access=boundary-token',
      authenticated: false,
    );
    expect(stopped.statusCode, HttpStatus.serviceUnavailable);
  });

  test(
    'enforces metadata body, identifier, filename, and file limits',
    () async {
      final oversized = await _dispatch(
        method: 'POST',
        path: '/api/web/meta',
        body: List<int>.filled(
          LanTransferProtocolGuard.maxControlBodyBytes + 1,
          0x20,
        ),
      );
      expect(oversized.statusCode, HttpStatus.requestEntityTooLarge);

      final unsafePath = await _dispatch(
        method: 'POST',
        path: '/api/web/meta',
        body: _metadata(
          id: 'unsafe-path',
          fileName: '../escape.txt',
          fileSize: 3,
        ),
      );
      expect(unsafePath.statusCode, HttpStatus.badRequest);
      expect(await sandbox.list().toList(), isEmpty);

      final invalidId = await _dispatch(
        method: 'POST',
        path: '/api/web/meta',
        body: _metadata(id: 'bad/id', fileName: 'safe.txt', fileSize: 3),
      );
      expect(invalidId.statusCode, HttpStatus.badRequest);

      final tooLarge = await _dispatch(
        method: 'POST',
        path: '/api/web/meta',
        body: _metadata(
          id: 'too-large',
          fileName: 'large.bin',
          fileSize: LanTransferProtocolGuard.maxAdvertisedFileBytes + 1,
        ),
      );
      expect(tooLarge.statusCode, HttpStatus.requestEntityTooLarge);
    },
  );

  test('keeps upload acceptance and sandbox cleanup in the boundary', () async {
    final meta = await _dispatch(
      method: 'POST',
      path: '/api/web/meta',
      body: _metadata(id: 'message-1', fileName: 'note.txt', fileSize: 3),
    );
    expect(meta.statusCode, HttpStatus.ok);

    final wrongName = await _dispatch(
      method: 'POST',
      path: '/api/web/upload',
      body: utf8.encode('abc'),
      headers: <String, String>{
        'x-message-id': 'message-1',
        'x-file-name': Uri.encodeComponent('other.txt'),
      },
    );
    expect(wrongName.statusCode, HttpStatus.badRequest);
    expect(await sandbox.list().toList(), isEmpty);

    final upload = await _dispatch(
      method: 'POST',
      path: '/api/web/upload',
      body: utf8.encode('abc'),
      headers: <String, String>{
        'x-message-id': 'message-1',
        'x-file-name': Uri.encodeComponent('note.txt'),
      },
    );
    expect(upload.statusCode, HttpStatus.ok);
    final files = (await sandbox.list().toList()).whereType<File>().toList();
    expect(files, hasLength(1));
    expect(await files.single.readAsString(), 'abc');

    final unknown = await _dispatch(
      method: 'POST',
      path: '/api/web/upload',
      body: const <int>[1, 2, 3],
      headers: <String, String>{
        'x-message-id': 'unknown-message',
        'x-file-name': Uri.encodeComponent('unknown.bin'),
      },
    );
    expect(unknown.statusCode, HttpStatus.conflict);
  });
}

Future<_Result> _dispatch({
  required String method,
  required String path,
  List<int> body = const <int>[],
  bool authenticated = true,
  Map<String, String> headers = const <String, String>{},
  int? contentLength,
}) async {
  final requestHeaders = _Headers();
  if (authenticated) {
    requestHeaders.set('x-web-share-token', 'boundary-token');
  }
  for (final entry in headers.entries) {
    requestHeaders.set(entry.key, entry.value);
  }
  final request = _Request(
    requestMethod: method,
    requestUri: Uri.parse(path),
    requestHeaders: requestHeaders,
    body: body,
    contentLength: contentLength,
  );
  await _activeHandler.handleRequest(request);
  return _Result(
    request.response.statusCode,
    request.response.body.toString(),
    request.response.responseHeaders,
  );
}

LanWebShareRequestHandler get _activeHandler => _handlerForTest;

late LanWebShareRequestHandler _handlerForTest;

List<int> _metadata({
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
