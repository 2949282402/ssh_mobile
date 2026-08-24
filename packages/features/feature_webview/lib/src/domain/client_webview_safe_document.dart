// Safe local-document rendering and one-shot internal navigation leases.

import 'dart:convert';
import 'dart:math';

import 'client_webview_network.dart';
import 'client_webview_security_policy.dart';

/// Converts a fetched remote page into an inert local document.
///
/// Remote markup is never returned verbatim: scripts, styles, forms, media,
/// and subresources are discarded. Only escaped visible text and validated
/// absolute HTTP(S) links are included in the generated document.
final class ClientWebViewSafeDocumentRenderer {
  static const int maxTextChars = 200000;
  static const int maxLinks = 100;

  const ClientWebViewSafeDocumentRenderer();

  String render(ClientWebViewFetchedPage page) {
    final isHtml =
        page.contentType.startsWith('text/html') ||
        page.contentType.startsWith('application/xhtml+xml');
    final title = isHtml
        ? _extractHtmlTitle(page.body) ?? page.finalUri.host
        : page.finalUri.host;
    final text = isHtml ? _htmlToPlainText(page.body) : page.body;
    final links = isHtml
        ? _extractSafeLinks(page.body, page.finalUri)
        : const <_SafeWebViewLink>[];
    final elementEscape = const HtmlEscape(HtmlEscapeMode.element);
    final attributeEscape = const HtmlEscape(HtmlEscapeMode.attribute);
    final safeTitle = elementEscape.convert(title);
    final safeText = elementEscape.convert(
      text.length > maxTextChars ? text.substring(0, maxTextChars) : text,
    );
    final linkHtml = links
        .map(
          (link) =>
              '<article class="result"><h3><a rel="noreferrer noopener" '
              'href="${attributeEscape.convert(link.uri.toString())}">'
              '${elementEscape.convert(link.title)}</a></h3></article>',
        )
        .join();
    return '''<!doctype html>
<html><head><meta charset="utf-8">
<meta http-equiv="Content-Security-Policy" content="default-src 'none'; connect-src 'none'; frame-src 'none'; img-src 'none'; media-src 'none'; object-src 'none'; script-src 'none'; style-src 'unsafe-inline'; form-action 'none'; base-uri 'none'">
<meta name="referrer" content="no-referrer"><title>$safeTitle</title>
<style>body{font-family:system-ui,sans-serif;margin:24px;line-height:1.5}pre{white-space:pre-wrap;word-break:break-word}a{color:#1769aa}.result{margin:12px 0}</style>
</head><body><main><pre>$safeText</pre></main><section>$linkHtml</section></body></html>''';
  }

  String? _extractHtmlTitle(String html) {
    final match = RegExp(
      r'<title\b[^>]*>([\s\S]*?)</title\s*>',
      caseSensitive: false,
    ).firstMatch(html);
    if (match == null) return null;
    final value = _htmlToPlainText(match.group(1) ?? '').trim();
    return value.isEmpty ? null : value;
  }

  String _htmlToPlainText(String html) {
    var value = html
        .replaceAll(
          RegExp(
            r'<(?:script|style|noscript|template)\b[^>]*>[\s\S]*?</(?:script|style|noscript|template)\s*>',
            caseSensitive: false,
          ),
          ' ',
        )
        .replaceAll(RegExp(r'<!--[\s\S]*?-->'), ' ')
        .replaceAll(RegExp(r'<[^>]*>'), ' ');
    value = _decodeHtmlEntities(value);
    return value.replaceAll(RegExp(r'\s+'), ' ').trim();
  }

  List<_SafeWebViewLink> _extractSafeLinks(String html, Uri baseUri) {
    final matches = RegExp(
      r'''<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)')[^>]*>([\s\S]*?)</a\s*>''',
      caseSensitive: false,
    ).allMatches(html);
    final links = <_SafeWebViewLink>[];
    final seen = <String>{};
    for (final match in matches) {
      final rawHref = _decodeHtmlEntities(
        (match.group(1) ?? match.group(2) ?? '').trim(),
      );
      if (rawHref.isEmpty) continue;
      late final Uri uri;
      try {
        uri = baseUri.resolve(rawHref);
      } on FormatException {
        continue;
      }
      if (ClientWebViewSecurityPolicy.blockedUriReason(uri) != null) continue;
      final title = _htmlToPlainText(match.group(3) ?? '').trim();
      if (title.isEmpty || !seen.add(uri.toString())) continue;
      links.add(_SafeWebViewLink(uri, title));
      if (links.length >= maxLinks) break;
    }
    return links;
  }

  String _decodeHtmlEntities(String value) {
    return value
        .replaceAll('&nbsp;', ' ')
        .replaceAll('&#160;', ' ')
        .replaceAll('&amp;', '&')
        .replaceAll('&#38;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&#60;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&#62;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#34;', '"')
        .replaceAll('&#39;', "'");
  }
}

/// One generated document load authorized for exactly one session-local URL.
final class ClientWebViewInternalDocumentTicket {
  final int generation;
  final Uri uri;
  final DateTime issuedAt;

  const ClientWebViewInternalDocumentTicket({
    required this.generation,
    required this.uri,
    required this.issuedAt,
  });
}

/// Authorizes only the next generated-document navigation for one session.
///
/// A new ticket invalidates an older pending generation. Consuming a ticket is
/// one-shot; arbitrary `about:` and `data:` URLs never match it.
final class ClientWebViewInternalDocumentLease {
  static const _internalHost = 'ssh-mobile-webview.invalid';

  final Duration ttl;
  final DateTime Function() _clock;
  final Random _random;
  int _generation = 0;
  ClientWebViewInternalDocumentTicket? _pending;
  ClientWebViewInternalDocumentTicket? _current;

  ClientWebViewInternalDocumentLease({
    this.ttl = const Duration(seconds: 30),
    DateTime Function()? clock,
    Random? random,
  }) : _clock = clock ?? DateTime.now,
       _random = random ?? Random.secure();

  ClientWebViewInternalDocumentTicket issue() {
    final now = _clock();
    final generation = ++_generation;
    final nonce = List.generate(
      6,
      (_) => _random.nextInt(0x1000000).toRadixString(16).padLeft(6, '0'),
      growable: false,
    ).join();
    final ticket = ClientWebViewInternalDocumentTicket(
      generation: generation,
      uri: Uri.https(_internalHost, '/document/$generation-$nonce'),
      issuedAt: now,
    );
    _pending = ticket;
    return ticket;
  }

  bool consume(Uri uri) {
    final ticket = _pending;
    if (ticket == null) return false;
    if (_isExpired(ticket)) {
      _pending = null;
      return false;
    }
    if (uri != ticket.uri) return false;
    _pending = null;
    _current = ticket;
    return true;
  }

  bool isIssuedDocument(Uri uri) {
    final pending = _pending;
    if (pending != null && _isExpired(pending)) _pending = null;
    return _pending?.uri == uri || _current?.uri == uri;
  }

  void cancel(ClientWebViewInternalDocumentTicket ticket) {
    if (identical(_pending, ticket)) _pending = null;
  }

  void clear() {
    _pending = null;
    _current = null;
  }

  bool _isExpired(ClientWebViewInternalDocumentTicket ticket) {
    return !_clock().isBefore(ticket.issuedAt.add(ttl));
  }
}

const String clientWebViewPageTextScript = r'''
(() => {
  const title = document.title || '';
  const url = window.location ? window.location.href : '';
  const body = document.body;
  const sensitiveSelector = [
    'input[type="password"]',
    'input[name*="token" i]',
    'input[name*="secret" i]',
    'input[name*="api" i]',
    'input[name*="key" i]',
    'textarea[name*="secret" i]',
    'textarea[name*="token" i]'
  ].join(',');
  const sensitiveFormDetected = !!document.querySelector(sensitiveSelector);
  const text = body ? (body.innerText || '') : '';
  return JSON.stringify({ title, url, text, sensitiveFormDetected });
})()
''';

const String clientWebViewSearchResultsScript = r'''
(() => {
  const clean = (value) => (value || '').replace(/\s+/g, ' ').trim();
  const notHidden = (el) => {
    if (!el) return false;
    const style = window.getComputedStyle(el);
    return style.display !== 'none' && style.visibility !== 'hidden';
  };
  const unwrapUrl = (href) => {
    try {
      const parsed = new URL(href, window.location.href);
      const host = parsed.hostname.replace(/^www\./, '').toLowerCase();
      const duckTarget = parsed.searchParams.get('uddg');
      if (host.endsWith('duckduckgo.com') && duckTarget) {
        try {
          return decodeURIComponent(duckTarget);
        } catch (_) {
          return duckTarget;
        }
      }
      if (parsed.hostname.includes('bing.com') && parsed.pathname.includes('/ck/')) {
        const encoded = parsed.searchParams.get('u');
        if (encoded) {
          let value = encoded;
          if (value.startsWith('a1')) value = value.substring(2);
          try {
            const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
            return atob(normalized);
          } catch (_) {
            return decodeURIComponent(encoded);
          }
        }
      }
      return parsed.href;
    } catch (_) {
      return '';
    }
  };
  const useful = (url, title) => {
    if (!url || !title || title.length < 3) return false;
    let parsed;
    try {
      parsed = new URL(url);
    } catch (_) {
      return false;
    }
    if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
    const lowerTitle = title.toLowerCase();
    const junk = [
      'images', 'videos', 'maps', 'news', 'shopping', 'settings', 'sign in',
      'privacy', 'privacy policy', 'terms', 'terms of service', 'next',
      'previous', 'feedback', 'help', 'advertise', 'safe search',
      'all regions', 'any time', 'past day', 'past week', 'past month',
      'past year', 'more results'
    ];
    if (junk.includes(lowerTitle)) return false;
    const loweredUrl = url.toLowerCase();
    if (
      loweredUrl.includes('/y.js?') ||
      loweredUrl.includes('ad_domain=') ||
      loweredUrl.includes('/aclick?') ||
      loweredUrl.includes('doubleclick.net')
    ) {
      return false;
    }
    const host = parsed.hostname.replace(/^www\./, '').toLowerCase();
    const path = parsed.pathname.toLowerCase();
    if (host.endsWith('duckduckgo.com')) {
      if (
        path === '/' ||
        path.includes('/html') ||
        path.includes('/l/') ||
        path.includes('/settings') ||
        path.includes('/feedback') ||
        path.includes('/duckduckgo-help-pages')
      ) {
        return false;
      }
    }
    const currentHost = window.location.hostname.replace(/^www\./, '').toLowerCase();
    if (host === currentHost) {
      if (
        path === '/' ||
        path.includes('/search') ||
        path.includes('/images') ||
        path === '/s'
      ) {
        return false;
      }
    }
    return true;
  };
  const results = [];
  const seen = new Set();
  const addResult = (anchor, container) => {
    if (!anchor || !notHidden(anchor)) return;
    if (container && (
      container.classList.contains('result--ad') ||
      container.querySelector('.badge--ad, [class*="badge--ad"], [class*="ad_domain"]')
    )) {
      return;
    }
    const url = unwrapUrl(anchor.href);
    const title = clean(anchor.innerText || anchor.textContent);
    if (!useful(url, title) || seen.has(url)) return;
    seen.add(url);
    const snippetNode = container ? container.querySelector(
      '.result__snippet, .result__body, .result__extras, .b_caption p, .b_snippet, p, [class*="snippet"], [class*="content"]'
    ) : null;
    let snippet = clean(snippetNode && notHidden(snippetNode) ? snippetNode.innerText : '');
    if (!snippet && container) {
      snippet = clean(container.innerText).replace(title, '').trim();
    }
    if (snippet.length > 500) snippet = snippet.substring(0, 500);
    results.push({ title, url, snippet });
  };
  const containers = Array.from(document.querySelectorAll([
    '.result.results_links',
    '.results_links',
    '.web-result',
    '.result',
    'li.b_algo',
    'ol#b_results > li',
    '[data-testid="result"]',
    'article',
    '.g'
  ].join(',')));
  for (const container of containers) {
    const anchor = container.querySelector(
      '.result__a[href], a.result__a[href], h2 a[href], h3 a[href], a[href]'
    );
    addResult(anchor, container);
    if (results.length >= 12) break;
  }
  if (results.length < 3) {
    for (const anchor of Array.from(document.querySelectorAll('a[href]'))) {
      addResult(anchor, anchor.closest('li, article, div') || anchor.parentElement);
      if (results.length >= 12) break;
    }
  }
  return JSON.stringify({
    title: document.title || '',
    url: window.location ? window.location.href : '',
    results
  });
})()
''';

final class _SafeWebViewLink {
  final Uri uri;
  final String title;

  const _SafeWebViewLink(this.uri, this.title);
}
