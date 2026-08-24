import 'package:flutter_test/flutter_test.dart';
import 'package:feature_webview/feature_webview.dart';

void main() {
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
