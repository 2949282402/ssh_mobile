// Client WebView controlled-network ports and redirect-aware loader.

import 'client_webview_security_policy.dart';

abstract interface class ClientWebViewDnsResolver {
  Future<List<String>> lookup(String host);
}

abstract interface class ClientWebViewPinnedTransport {
  Future<ClientWebViewTransportResponse> get(
    Uri uri, {
    required String address,
    required int maxBytes,
  });
}

abstract interface class ClientWebViewNetworkLoader {
  Future<ClientWebViewFetchedPage> load(Uri uri);
}

class ClientWebViewTransportResponse {
  final int statusCode;
  final String? redirectLocation;
  final String? contentType;
  final String body;

  const ClientWebViewTransportResponse({
    required this.statusCode,
    required this.body,
    this.redirectLocation,
    this.contentType,
  });
}

class ClientWebViewFetchedPage {
  final Uri requestedUri;
  final Uri finalUri;
  final String contentType;
  final String body;

  const ClientWebViewFetchedPage({
    required this.requestedUri,
    required this.finalUri,
    required this.contentType,
    required this.body,
  });
}

final class ClientWebViewNetworkException implements Exception {
  final String message;

  const ClientWebViewNetworkException(this.message);

  @override
  String toString() => message;
}

/// Resolves and validates every redirect hop before delegating the request to
/// a transport that must connect to the exact [address] it receives.
final class ClientWebViewSafeNetworkLoader
    implements ClientWebViewNetworkLoader {
  static const _redirectStatuses = {301, 302, 303, 307, 308};

  final ClientWebViewDnsResolver resolver;
  final ClientWebViewPinnedTransport transport;
  final int maxRedirects;
  final int maxResponseBytes;

  const ClientWebViewSafeNetworkLoader({
    required this.resolver,
    required this.transport,
    this.maxRedirects = 5,
    this.maxResponseBytes = 2 * 1024 * 1024,
  });

  @override
  Future<ClientWebViewFetchedPage> load(Uri uri) async {
    final requestedUri = uri;
    var current = uri.removeFragment();
    final visited = <String>{};
    for (var redirectCount = 0; ; redirectCount++) {
      final blockedReason = ClientWebViewSecurityPolicy.blockedUriReason(
        current,
      );
      if (blockedReason != null) {
        throw ClientWebViewNetworkException(blockedReason);
      }
      if (!visited.add(current.toString())) {
        throw const ClientWebViewNetworkException('Blocked redirect loop.');
      }

      final addresses = await _resolve(current.host);
      final response = await transport.get(
        current,
        address: addresses.first,
        maxBytes: maxResponseBytes,
      );
      if (_redirectStatuses.contains(response.statusCode)) {
        if (redirectCount >= maxRedirects) {
          throw const ClientWebViewNetworkException(
            'Blocked excessive redirects.',
          );
        }
        final location = response.redirectLocation?.trim();
        if (location == null || location.isEmpty) {
          throw const ClientWebViewNetworkException(
            'Blocked redirect without a location.',
          );
        }
        late final Uri next;
        try {
          next = current.resolve(location);
        } on FormatException {
          throw const ClientWebViewNetworkException(
            'Blocked invalid redirect location.',
          );
        }
        final redirectReason = ClientWebViewSecurityPolicy.blockedUriReason(
          next,
        );
        if (redirectReason != null) {
          throw ClientWebViewNetworkException(redirectReason);
        }
        current = next.removeFragment();
        continue;
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw ClientWebViewNetworkException(
          'Web request failed with HTTP ${response.statusCode}.',
        );
      }
      final contentType = response.contentType?.trim().toLowerCase();
      if (contentType == null ||
          !(contentType.startsWith('text/html') ||
              contentType.startsWith('application/xhtml+xml') ||
              contentType.startsWith('text/plain'))) {
        throw const ClientWebViewNetworkException(
          'Blocked non-text WebView response.',
        );
      }
      return ClientWebViewFetchedPage(
        requestedUri: requestedUri,
        finalUri: current,
        contentType: contentType,
        body: response.body,
      );
    }
  }

  Future<List<String>> _resolve(String host) async {
    final normalizedHost = host.toLowerCase();
    late final List<String> addresses;
    if (ClientWebViewSecurityPolicy.isIpLiteral(normalizedHost)) {
      addresses = <String>[normalizedHost];
    } else {
      try {
        addresses = await resolver.lookup(normalizedHost);
      } catch (_) {
        throw const ClientWebViewNetworkException('DNS resolution failed.');
      }
    }
    final uniqueAddresses = addresses
        .map((address) => address.trim().toLowerCase())
        .where((address) => address.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (uniqueAddresses.isEmpty) {
      throw const ClientWebViewNetworkException(
        'DNS returned no usable addresses.',
      );
    }
    for (final address in uniqueAddresses) {
      final blockedReason =
          ClientWebViewSecurityPolicy.blockedResolvedAddressReason(address);
      if (blockedReason != null) {
        throw ClientWebViewNetworkException(blockedReason);
      }
    }
    return uniqueAddresses;
  }
}
