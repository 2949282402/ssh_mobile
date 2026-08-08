import 'package:flutter_test/flutter_test.dart';
import 'package:feature_webview/feature_webview.dart';

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
  });

  test('allows normal https pages and search-like input', () {
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('https://example.com'),
      isNull,
    );
    expect(
      ClientWebViewSecurityPolicy.blockedInputReason('flutter webview docs'),
      isNull,
    );
  });

  test('snapshot JSON reports blocked sensitive forms', () {
    final payload = const ClientWebViewSnapshot(
      chatId: 'chat-1',
      supported: true,
      hasPage: true,
      url: 'https://example.com/login',
      text: '',
      textLength: 0,
      maxChars: 40000,
      truncated: false,
      blocked: true,
      sensitiveFormDetected: true,
      error: 'Sensitive form detected.',
    ).toJson();

    expect(payload['blocked'], isTrue);
    expect(payload['sensitiveFormDetected'], isTrue);
    expect(payload['text'], '');
  });
}
