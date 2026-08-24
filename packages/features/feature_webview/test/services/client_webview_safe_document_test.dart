import 'dart:math';

import 'package:feature_webview/feature_webview.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const renderer = ClientWebViewSafeDocumentRenderer();

  test('renderer emits only escaped text and validated absolute links', () {
    final page = ClientWebViewFetchedPage(
      requestedUri: Uri.parse('https://public.example.com/start'),
      finalUri: Uri.parse('https://public.example.com/base/'),
      contentType: 'text/html; charset=utf-8',
      body: '''
        <html><head><title>Safe &amp; useful</title>
        <style>body { background: url(https://tracking.example.com/pixel) }</style>
        <script>fetch('http://127.0.0.1/private')</script></head>
        <body><form action="https://tracking.example.com/post">
        <p>Hello &lt;admin&gt;</p>
        <img src="https://tracking.example.com/image.png">
        <a href="/next">Public result</a>
        <a href="http://127.0.0.1/private">Private result</a>
        <a href="data:text/html,owned">Data result</a>
        </form></body></html>
      ''',
    );

    final html = renderer.render(page);

    expect(html, contains("default-src 'none'"));
    expect(html, contains('Safe &amp; useful'));
    expect(html, contains('Hello &lt;admin&gt;'));
    expect(html, contains('https://public.example.com/next'));
    expect(html, isNot(contains('<form')));
    expect(html, isNot(contains('<img')));
    expect(html, isNot(contains('<script')));
    expect(html, isNot(contains('127.0.0.1')));
    expect(html, isNot(contains('data:text/html')));
    expect(html, isNot(contains('tracking.example.com')));
  });

  test('renderer bounds and escapes plain-text responses', () {
    final body =
        '<unsafe>&${List.filled(ClientWebViewSafeDocumentRenderer.maxTextChars, 'x').join()}';
    final page = ClientWebViewFetchedPage(
      requestedUri: Uri.parse('https://public.example.com/'),
      finalUri: Uri.parse('https://public.example.com/'),
      contentType: 'text/plain',
      body: body,
    );

    final html = renderer.render(page);

    expect(html, contains('&lt;unsafe&gt;&amp;'));
    expect(html, isNot(contains('<unsafe>')));
    expect(html.length, lessThan(body.length + 1000));
  });

  test('renderer skips malformed links without dropping safe content', () {
    final page = ClientWebViewFetchedPage(
      requestedUri: Uri.parse('https://public.example.com/'),
      finalUri: Uri.parse('https://public.example.com/base/'),
      contentType: 'text/html',
      body: '''
        <p>Visible content</p>
        <a href="https://[invalid">Broken result</a>
        <a href="/safe">Safe result</a>
      ''',
    );

    final html = renderer.render(page);

    expect(html, contains('Visible content'));
    expect(html, isNot(contains('Broken result</a>')));
    expect(html, contains('https://public.example.com/safe'));
  });

  test('internal document lease rejects forged data URLs and is one-shot', () {
    final lease = ClientWebViewInternalDocumentLease(random: Random(1));
    final ticket = lease.issue();

    expect(ClientWebViewSecurityPolicy.blockedUriReason(ticket.uri), isNotNull);
    expect(
      lease.consume(Uri.parse('data:text/html,<script>owned</script>')),
      isFalse,
    );
    expect(lease.consume(Uri.parse('about:blank')), isFalse);
    expect(lease.isIssuedDocument(ticket.uri), isTrue);
    expect(lease.consume(ticket.uri), isTrue);
    expect(lease.consume(ticket.uri), isFalse);
    expect(lease.isIssuedDocument(ticket.uri), isTrue);
  });

  test('new lease generation invalidates the previous pending document', () {
    final lease = ClientWebViewInternalDocumentLease(random: Random(2));
    final first = lease.issue();
    final second = lease.issue();

    expect(second.generation, first.generation + 1);
    expect(lease.consume(first.uri), isFalse);
    expect(lease.consume(second.uri), isTrue);
  });

  test('expired and cancelled document leases fail closed', () {
    var now = DateTime.utc(2026, 8, 24);
    final lease = ClientWebViewInternalDocumentLease(
      ttl: const Duration(seconds: 1),
      clock: () => now,
      random: Random(3),
    );
    final expired = lease.issue();
    now = now.add(const Duration(seconds: 1));
    expect(lease.isIssuedDocument(expired.uri), isFalse);
    expect(lease.consume(expired.uri), isFalse);

    final cancelled = lease.issue();
    lease.cancel(cancelled);
    expect(lease.consume(cancelled.uri), isFalse);

    final cleared = lease.issue();
    lease.clear();
    expect(lease.isIssuedDocument(cleared.uri), isFalse);
    expect(lease.consume(cleared.uri), isFalse);
  });
}
