// WebView Feature 的 App Shell 适配器。
//
// Feature 只依赖 WebView Port；本文件把 AppSettings 的语言通知转换为可监听
// Port，并提供受 Feature 安全编排约束的 DNS 与 IP-pinned HTTP 适配器。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:feature_webview/feature_webview.dart' as webview;
import 'package:flutter/foundation.dart';

import '../services/app_settings.dart';

/// 使用系统 DNS 返回全部地址；Feature 会在发起连接前逐个验证其可路由性。
final class AppWebViewDnsResolver implements webview.ClientWebViewDnsResolver {
  const AppWebViewDnsResolver();

  @override
  Future<List<String>> lookup(String host) async {
    final addresses = await InternetAddress.lookup(
      host,
    ).timeout(const Duration(seconds: 5));
    return addresses.map((address) => address.address).toSet().toList();
  }
}

/// 每次请求创建短生命周期 HttpClient，并把连接固定到 Feature 已验证的 IP。
/// HTTPS 仍使用原始 URI host 完成 SNI 与证书校验，且不跟随重定向。
final class AppWebViewPinnedTransport
    implements webview.ClientWebViewPinnedTransport {
  const AppWebViewPinnedTransport();

  @override
  Future<webview.ClientWebViewTransportResponse> get(
    Uri uri, {
    required String address,
    required int maxBytes,
  }) async {
    final pinnedAddress = InternetAddress.tryParse(address);
    if (pinnedAddress == null) {
      throw const webview.ClientWebViewNetworkException(
        'DNS returned an invalid IP address.',
      );
    }
    final client = HttpClient()
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 8)
      ..idleTimeout = const Duration(seconds: 5)
      ..findProxy = ((_) => 'DIRECT')
      ..connectionFactory = (requestUri, proxyHost, proxyPort) async {
        final requestedScheme = requestUri.scheme.toLowerCase();
        final expectedScheme = uri.scheme.toLowerCase();
        final requestedPort = requestUri.hasPort
            ? requestUri.port
            : requestedScheme == 'https'
            ? 443
            : 80;
        final expectedPort = uri.hasPort
            ? uri.port
            : expectedScheme == 'https'
            ? 443
            : 80;
        if (proxyHost != null ||
            proxyPort != null ||
            requestUri.host.toLowerCase() != uri.host.toLowerCase() ||
            requestedScheme != expectedScheme ||
            requestedPort != expectedPort) {
          throw const webview.ClientWebViewNetworkException(
            'Blocked unpinned WebView connection.',
          );
        }
        // HttpClient owns the TLS upgrade, SNI and certificate verification.
        // The factory only pins the underlying TCP connection to the validated
        // address, while the original request URI retains the authority.
        return Socket.startConnect(pinnedAddress, requestedPort);
      };
    try {
      final request = await client
          .getUrl(uri)
          .timeout(const Duration(seconds: 10));
      request
        ..followRedirects = false
        ..maxRedirects = 0;
      request.headers
        ..set(HttpHeaders.acceptHeader, 'text/html,text/plain;q=0.9')
        ..set(HttpHeaders.acceptEncodingHeader, 'identity')
        ..set(HttpHeaders.connectionHeader, 'close')
        ..set(HttpHeaders.userAgentHeader, 'SSH-Mobile-Safe-WebView/1.0');
      final response = await request.close().timeout(
        const Duration(seconds: 12),
      );
      final location = response.headers.value(HttpHeaders.locationHeader);
      final contentType = response.headers.value(HttpHeaders.contentTypeHeader);
      if ({301, 302, 303, 307, 308}.contains(response.statusCode)) {
        return webview.ClientWebViewTransportResponse(
          statusCode: response.statusCode,
          redirectLocation: location,
          contentType: contentType,
          body: '',
        );
      }
      if (response.contentLength > maxBytes) {
        throw const webview.ClientWebViewNetworkException(
          'Blocked oversized WebView response.',
        );
      }
      final bytes = <int>[];
      await (() async {
        await for (final chunk in response) {
          if (bytes.length + chunk.length > maxBytes) {
            throw const webview.ClientWebViewNetworkException(
              'Blocked oversized WebView response.',
            );
          }
          bytes.addAll(chunk);
        }
      })().timeout(const Duration(seconds: 12));
      return webview.ClientWebViewTransportResponse(
        statusCode: response.statusCode,
        contentType: contentType,
        body: utf8.decode(bytes, allowMalformed: true),
      );
    } finally {
      client.close(force: true);
    }
  }
}

/// 将 AppSettings 暴露为 WebView 页面所需的最小设置 Port。
final class AppWebViewSettingsAdapter extends ChangeNotifier
    implements webview.WebViewSettingsPort {
  /// 创建不拥有 [settings] 的适配器。
  AppWebViewSettingsAdapter(this._settings) {
    _settings.addListener(_forwardSettingsChange);
  }

  final AppSettings _settings;

  @override
  AppLanguage get language => _settings.language;

  void _forwardSettingsChange() => notifyListeners();

  /// 解除对 AppSettings 的监听并释放 Route 可观察资源。
  @override
  void dispose() {
    _settings.removeListener(_forwardSettingsChange);
    super.dispose();
  }
}
