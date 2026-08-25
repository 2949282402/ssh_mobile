import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:feature_lan_share/feature_lan_share.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    FlutterSecureStorage.setMockInitialValues(<String, String>{});
  });

  test('V2 pairing commits one complete trust record atomically', () async {
    const storage = FlutterSecureStorage();
    final store = LanPeerTrustStore(secureStorage: storage);
    final security = LanSecurityService(
      appOwnedX25519PrivateSeed: Uint8List(32),
      secureStorage: storage,
      peerTrustStore: store,
    );
    addTearDown(store.dispose);

    await expectLater(
      security.savePeerTrustRecord(
        deviceId: 'peer-a',
        certificateFingerprint: _fingerprint,
        inboundAccessToken: 'inbound-token',
        outboundAccessToken: 'outbound-token',
        x25519PublicKey: _key(0x11),
        networkIdentityPublicKey: Uint8List(31),
      ),
      throwsFormatException,
    );
    expect(await store.read('peer-a'), isNull);

    final firstChange = store.changes.first;
    await security.savePeerTrustRecord(
      deviceId: 'peer-a',
      certificateFingerprint: _fingerprint,
      inboundAccessToken: 'inbound-token',
      outboundAccessToken: 'outbound-token',
      x25519PublicKey: _key(0x11),
      networkIdentityPublicKey: _key(0x22),
    );

    final records = await firstChange;
    expect(records, hasLength(1));
    final restored = await store.read('peer-a');
    expect(restored?.authorization.localDirect, isTrue);
    expect(restored?.authorization.relay, isFalse);
    expect(restored?.x25519PublicKey, hasLength(32));
    expect(restored?.networkIdentityPublicKey, hasLength(32));

    final encoded =
        jsonDecode((await storage.read(key: 'lan_share_peer_trust_v2'))!)
            as Map<String, dynamic>;
    expect(encoded['schemaVersion'], LanPeerTrustStore.schemaVersion);
    expect(encoded['records'], hasLength(1));
  });

  test('V2 transfer service has no legacy binary upload endpoint', () async {
    final service = LanTransferService(
      currentDeviceId: 'local-device',
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
  });
}

const String _fingerprint =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';

Uint8List _key(int value) => Uint8List.fromList(List<int>.filled(32, value));

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
  final Completer<void> closed = Completer<void>();

  @override
  int statusCode = HttpStatus.ok;

  @override
  HttpHeaders get headers => _headers;

  @override
  void write(Object? object) {}

  @override
  Future<HttpResponse> close([Object? data]) async {
    if (!closed.isCompleted) closed.complete();
    return this;
  }
}

final class _Headers implements HttpHeaders {
  @override
  ContentType? contentType;

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
