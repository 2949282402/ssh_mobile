import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:feature_lan_share/feature_lan_share.dart';

void main() {
  test('the legacy native HTTP upload route is not exposed in V2', () async {
    // Keep this contract test independent of the Flutter test runner's HTTP
    // interception and of a second TLS/native runtime. A live loopback test
    // cannot distinguish a missing route from a runner-owned HTTP override.
    final sourceFile = _sourceFile();
    expect(sourceFile.existsSync(), isTrue, reason: sourceFile.path);
    final source = await sourceFile.readAsString();

    expect(
      source,
      isNot(matches(RegExp(r'''path\s*==\s*['"]\/api\/lan\/upload['"]'''))),
    );
    for (final removedSymbol in <String>[
      '_handleUploadRequest',
      'LanPendingUpload',
      '_pendingUploads',
      '_activeUploads',
    ]) {
      expect(source, isNot(contains(removedSymbol)), reason: removedSymbol);
    }
  });

  test(
    'the in-process route dispatcher returns 404 for legacy upload',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final service = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: LanSecurityService(
          appOwnedX25519PrivateSeed: Uint8List(32),
        ),
        storageService: LanStorageService(),
      );
      addTearDown(service.close);

      final request = _Request();
      service.handleHttpRequest(request);
      await request.response.closed.future.timeout(const Duration(seconds: 1));

      expect(request.response.statusCode, HttpStatus.notFound);
    },
  );
}

File _sourceFile() {
  const relativePath = 'lib/src/services/lan_share/lan_transfer_service.dart';
  final fromCurrentDirectory = File(relativePath);
  if (fromCurrentDirectory.existsSync()) return fromCurrentDirectory;

  final fromRepositoryRoot = File(
    'packages/features/feature_lan_share/$relativePath',
  );
  if (fromRepositoryRoot.existsSync()) return fromRepositoryRoot;

  // Aggregate test commands may execute from the repository root rather than
  // this package. Platform.script is a final fallback for runners that use a
  // package-local working directory without the package-relative path.
  final testFile = File.fromUri(Platform.script);
  final packageRoot = testFile.parent.parent.parent;
  return File.fromUri(packageRoot.uri.resolve(relativePath));
}

final class _Request extends Fake implements HttpRequest {
  final _Response _response = _Response();
  final _Headers _headers = _Headers();

  @override
  String get method => 'POST';

  @override
  Uri get uri => Uri.parse('/api/lan/upload');

  @override
  HttpHeaders get headers => _headers;

  @override
  _Response get response => _response;
}

final class _Response extends Fake implements HttpResponse {
  final _Headers _headers = _Headers();
  final StringBuffer body = StringBuffer();
  final closed = Completer<void>();

  @override
  int statusCode = HttpStatus.ok;

  @override
  HttpHeaders get headers => _headers;

  @override
  void write(Object? object) => body.write(object);

  @override
  Future<HttpResponse> close([Object? data]) async {
    if (data != null) body.write(data);
    if (!closed.isCompleted) closed.complete();
    return this;
  }
}

final class _Headers implements HttpHeaders {
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

  @override
  List<String>? operator [](String name) => null;

  @override
  String? value(String name) => null;

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {}

  @override
  void remove(String name, Object value) {}

  @override
  void removeAll(String name) {}

  @override
  void forEach(void Function(String name, List<String> values) action) {}

  @override
  void noFolding(String name) {}

  @override
  void clear() {}
}
