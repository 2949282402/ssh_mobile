import 'package:feature_webview/feature_webview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('blocks local, private, metadata, and unsafe URL inputs', () {
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('http://localhost:8080'),
      contains('Blocked'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('https://127.0.0.1'),
      contains('Blocked'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('http://10.0.0.5'),
      contains('Blocked'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('http://172.16.1.1'),
      contains('Blocked'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('http://192.168.1.1'),
      contains('Blocked'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason(
        'http://169.254.169.254/latest/meta-data',
      ),
      contains('Blocked'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason(
        'http://metadata.google.internal',
      ),
      contains('Blocked'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('file:///etc/passwd'),
      contains('scheme'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('javascript:alert(1)'),
      contains('scheme'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason(
        'data:text/html,<script>owned</script>',
      ),
      contains('scheme'),
    );
  });

  test('allows normal https pages and search-like input', () {
    expect(ClientWebViewSecurityPolicy.blockedInputReason(''), isNull);
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('https://example.com'),
      isNull,
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('flutter webview docs'),
      isNull,
    );
  });

  test('rejects non-global and non-standard IPv4 literals', () {
    for (final value in [
      '0.1.2.3',
      '100.64.0.1',
      '127.0.0.1',
      '169.254.1.1',
      '172.31.255.255',
      '192.0.2.1',
      '192.168.1.1',
      '198.18.0.1',
      '198.51.100.1',
      '203.0.113.1',
      '224.0.0.1',
      '240.0.0.1',
      '2130706433',
      '0x7f000001',
      '127.1',
      '0177.0.0.1',
      '127.0.0.1.',
    ]) {
      expect(
        ClientWebViewSecurityPolicy.blockedInputReason('http://$value/'),
        isNotNull,
        reason: value,
      );
    }
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('https://8.8.8.8/'),
      isNull,
    );
  });

  test('rejects non-global IPv6 while allowing global unicast', () {
    for (final value in [
      '::',
      '::1',
      '::ffff:127.0.0.1',
      'fc00::1',
      'fd00::1',
      'fe80::1',
      'fec0::1',
      'ff02::1',
      '2001:1::1',
      '2001:20::1',
      '2001:db8::1',
      '2002:7f00:1::',
      '3fff::1',
    ]) {
      expect(
        ClientWebViewSecurityPolicy.blockedInputReason('http://[$value]/'),
        isNotNull,
        reason: value,
      );
    }
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason(
        'https://[2001:4860:4860::8888]/',
      ),
      isNull,
    );
  });

  test('rejects local DNS names and URL credentials', () {
    for (final value in [
      'http://printer.local',
      'http://service.internal',
      'http://singlelabel',
      'https://user:password@example.com',
    ]) {
      expect(
        ClientWebViewSecurityPolicy.blockedInputReason(value),
        isNotNull,
        reason: value,
      );
    }
  });

  test('resolved-address checks reject invalid or non-global answers', () {
    expect(
      ClientWebViewSecurityPolicy.blockedResolvedAddressReason('8.8.8.8'),
      isNull,
    );
    expect(
      ClientWebViewSecurityPolicy.blockedResolvedAddressReason(
        '2001:4860:4860::8888',
      ),
      isNull,
    );
    expect(
      ClientWebViewSecurityPolicy.blockedResolvedAddressReason('10.0.0.1'),
      contains('non-global IPv4'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedResolvedAddressReason('fe80::1'),
      contains('non-global IPv6'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedResolvedAddressReason('not-an-ip'),
      contains('invalid IP'),
    );
  });

  test('URI validation rejects unsupported schemes and malformed hosts', () {
    expect(
      ClientWebViewSecurityPolicy.blockedUriReason(
        Uri.parse('ftp://public.example.com/file'),
      ),
      contains('Unsupported'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('https://bad_host.tested'),
      isNotNull,
    );
    expect(
      ClientWebViewSecurityPolicy.blockedUriReason(
        Uri.parse('https://public.example.com:0/'),
      ),
      contains('invalid URL port'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedUriReason(Uri.parse('https:path')),
      contains('without a host'),
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('public.example.com.'),
      isNull,
    );
    expect(ClientWebViewSecurityPolicy.isIpLiteral('8.8.8.8'), isTrue);
    expect(
      ClientWebViewSecurityPolicy.isIpLiteral('2001:4860:4860::8888'),
      isTrue,
    );
    expect(ClientWebViewSecurityPolicy.isIpLiteral('example.com'), isFalse);
  });
}
