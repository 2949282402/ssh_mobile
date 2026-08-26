import 'dart:async';
import 'dart:convert';
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

  test(
    '/api/lan/capabilities response includes protocolVersion == 2',
    () async {
      FlutterSecureStorage.setMockInitialValues(<String, String>{});
      final store = LanPeerTrustStore();
      final security = LanSecurityService(
        appOwnedX25519PrivateSeed: Uint8List(32),
        peerTrustStore: store,
      );
      final service = LanTransferService(
        currentDeviceId: 'device-a',
        securityService: security,
        storageService: LanStorageService(),
        networkIdentityPublicKeyProvider: () async => Uint8List(32),
        nativeTransferPortProvider: () => 43123,
      );
      addTearDown(() async {
        await service.close();
        await store.dispose();
      });

      final trust = LanPeerTrustRecord(
        deviceId: 'device-b',
        certificateFingerprint:
            '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
        inboundAccessToken: 'valid-inbound-token',
        outboundAccessToken: 'valid-outbound-token',
        x25519PublicKey: Uint8List(32),
        networkIdentityPublicKey: Uint8List(32),
        origin: PeerTrustOrigin.localPin,
        authorization: const PeerRouteAuthorization(
          localDirect: true,
          relay: false,
        ),
        createdAt: DateTime.utc(2026),
      );
      await store.save(trust);

      final request = _CapabilitiesRequest();
      service.handleHttpRequest(request);
      await request.response.closed.future.timeout(const Duration(seconds: 1));

      expect(request.response.statusCode, HttpStatus.ok);
      final decoded =
          jsonDecode(request.response.body.toString()) as Map<String, dynamic>;
      expect(decoded['protocolVersion'], LanControlProtocol.version);
      expect(decoded['protocolVersion'], 2);
      expect(decoded['quicFileTransfer'], isTrue);
      expect(decoded['quicPort'], 43123);
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

final class _CapabilitiesRequest extends Fake implements HttpRequest {
  final _Response _response = _Response();
  final _Headers _headers = _Headers();

  _CapabilitiesRequest() {
    _headers.set('x-device-id', 'device-b');
    _headers.set(HttpHeaders.authorizationHeader, 'Bearer valid-inbound-token');
  }

  @override
  String get method => 'GET';

  @override
  Uri get uri => Uri.parse('/api/lan/capabilities');

  @override
  HttpHeaders get headers => _headers;

  @override
  _Response get response => _response;
}

final class _Headers implements HttpHeaders {
  final Map<String, String> _values = {};

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
  String? value(String name) => _values[name.toLowerCase()];

  @override
  void add(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    _values[name.toLowerCase()] = value.toString();
  }

  @override
  void remove(String name, Object value) {
    _values.remove(name.toLowerCase());
  }

  @override
  void removeAll(String name) {
    _values.remove(name.toLowerCase());
  }

  @override
  void forEach(void Function(String name, List<String> values) action) {
    _values.forEach((k, v) => action(k, [v]));
  }

  @override
  void noFolding(String name) {}

  @override
  void clear() {
    _values.clear();
  }
}
