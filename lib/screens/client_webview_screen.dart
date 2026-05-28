import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../services/app_settings.dart';
import '../services/client_webview_service.dart';

class ClientWebViewScreen extends StatefulWidget {
  final String chatId;

  const ClientWebViewScreen({
    super.key,
    required this.chatId,
  });

  @override
  State<ClientWebViewScreen> createState() => _ClientWebViewScreenState();
}

class _ClientWebViewScreenState extends State<ClientWebViewScreen> {
  final ClientWebViewService _service = ClientWebViewService.instance;
  late final ClientWebViewSession _session;
  late final TextEditingController _urlController;
  late final FocusNode _urlFocusNode;

  @override
  void initState() {
    super.initState();
    _session = _service.sessionFor(widget.chatId);
    _urlController = TextEditingController(
      text: _session.url ?? ClientWebViewService.defaultUrl,
    );
    _urlFocusNode = FocusNode();
    _service.addListener(_syncUrlText);
  }

  @override
  void dispose() {
    _service.removeListener(_syncUrlText);
    _urlController.dispose();
    _urlFocusNode.dispose();
    super.dispose();
  }

  void _syncUrlText() {
    if (_session.isAiBrowsing && _urlFocusNode.hasFocus) {
      _urlFocusNode.unfocus();
    }
    if (_urlFocusNode.hasFocus) return;
    final url = _session.url ?? '';
    if (url.isNotEmpty && _urlController.text != url) {
      _urlController.text = url;
    }
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = _WebViewStrings(language);

    return Scaffold(
      appBar: AppBar(
        title: AnimatedBuilder(
          animation: _service,
          builder: (context, _) {
            return Text(
              _session.title?.trim().isNotEmpty == true
                  ? _session.title!
                  : strings.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          },
        ),
      ),
      body: !_session.supported || _session.controller == null
          ? _UnsupportedWebView(strings: strings)
          : Column(
              children: [
                AnimatedBuilder(
                  animation: _service,
                  builder: (context, _) {
                    return _WebAddressBar(
                      controller: _urlController,
                      focusNode: _urlFocusNode,
                      strings: strings,
                      enabled: !_session.isAiBrowsing,
                      onSubmitted: (value) =>
                          _service.load(widget.chatId, value),
                      onBack: _goBack,
                      onForward: _goForward,
                      onRefresh: _refresh,
                    );
                  },
                ),
                AnimatedBuilder(
                  animation: _service,
                  builder: (context, _) {
                    final progress = _session.progress;
                    if (!_session.isLoading || progress >= 100) {
                      return const SizedBox.shrink();
                    }
                    return LinearProgressIndicator(
                      minHeight: 2,
                      value: progress <= 0 ? null : progress / 100,
                    );
                  },
                ),
                Expanded(
                  child: Stack(
                    children: [
                      AnimatedBuilder(
                        animation: _service,
                        child: WebViewWidget(controller: _session.controller!),
                        builder: (context, child) {
                          return AbsorbPointer(
                            absorbing: _session.isAiBrowsing,
                            child: child,
                          );
                        },
                      ),
                      AnimatedBuilder(
                        animation: _service,
                        builder: (context, _) {
                          if (!_session.isAiBrowsing) {
                            return const SizedBox.shrink();
                          }
                          return const Positioned.fill(
                            child: ModalBarrier(
                              dismissible: false,
                              color: Colors.transparent,
                            ),
                          );
                        },
                      ),
                      AnimatedBuilder(
                        animation: _service,
                        builder: (context, _) {
                          if (!_session.isAiBrowsing) {
                            return const SizedBox.shrink();
                          }
                          return _AiBrowsingBanner(
                            strings: strings,
                            label: _session.aiBrowsingLabel,
                            onInterrupt: () =>
                                _service.interruptAiBrowsing(widget.chatId),
                          );
                        },
                      ),
                      AnimatedBuilder(
                        animation: _service,
                        builder: (context, _) {
                          final error = _session.lastError;
                          if (error == null || error.trim().isEmpty) {
                            return const SizedBox.shrink();
                          }
                          return Align(
                            alignment: Alignment.bottomCenter,
                            child: SafeArea(
                              top: false,
                              child: Container(
                                width: double.infinity,
                                margin: const EdgeInsets.all(12),
                                padding: const EdgeInsets.all(10),
                                decoration: BoxDecoration(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .errorContainer,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  error,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onErrorContainer,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Future<void> _goBack() async {
    if (_session.isAiBrowsing) return;
    final controller = _session.controller;
    if (controller == null) return;
    if (await controller.canGoBack()) {
      await controller.goBack();
    }
  }

  Future<void> _goForward() async {
    if (_session.isAiBrowsing) return;
    final controller = _session.controller;
    if (controller == null) return;
    if (await controller.canGoForward()) {
      await controller.goForward();
    }
  }

  Future<void> _refresh() async {
    if (_session.isAiBrowsing) return;
    final controller = _session.controller;
    if (controller == null) return;
    await controller.reload();
  }
}

class _WebAddressBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final _WebViewStrings strings;
  final bool enabled;
  final ValueChanged<String> onSubmitted;
  final VoidCallback onBack;
  final VoidCallback onForward;
  final VoidCallback onRefresh;

  const _WebAddressBar({
    required this.controller,
    required this.focusNode,
    required this.strings,
    required this.enabled,
    required this.onSubmitted,
    required this.onBack,
    required this.onForward,
    required this.onRefresh,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.surfaceContainer,
      child: SafeArea(
        top: false,
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
          child: Row(
            children: [
              IconButton(
                tooltip: strings.back,
                icon: const Icon(Icons.arrow_back_rounded),
                onPressed: enabled ? onBack : null,
              ),
              IconButton(
                tooltip: strings.forward,
                icon: const Icon(Icons.arrow_forward_rounded),
                onPressed: enabled ? onForward : null,
              ),
              Expanded(
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: enabled,
                  textInputAction: TextInputAction.go,
                  keyboardType: TextInputType.url,
                  autocorrect: false,
                  enableSuggestions: false,
                  minLines: 1,
                  maxLines: 1,
                  decoration: InputDecoration(
                    hintText: strings.addressHint,
                    isDense: true,
                    prefixIcon: const Icon(Icons.language_rounded, size: 18),
                    suffixIcon: IconButton(
                      tooltip: strings.go,
                      icon: const Icon(Icons.north_east_rounded, size: 18),
                      onPressed:
                          enabled ? () => onSubmitted(controller.text) : null,
                    ),
                  ),
                  onSubmitted: enabled ? onSubmitted : null,
                ),
              ),
              IconButton(
                tooltip: strings.refresh,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: enabled ? onRefresh : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiBrowsingBanner extends StatelessWidget {
  final _WebViewStrings strings;
  final String? label;
  final VoidCallback onInterrupt;

  const _AiBrowsingBanner({
    required this.strings,
    required this.label,
    required this.onInterrupt,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveLabel = label?.trim();
    return Align(
      alignment: Alignment.topCenter,
      child: SafeArea(
        bottom: false,
        child: Container(
          width: double.infinity,
          margin: const EdgeInsets.all(12),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: colorScheme.outlineVariant.withValues(alpha: 0.72),
            ),
          ),
          child: Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colorScheme.primary,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  effectiveLabel == null || effectiveLabel.isEmpty
                      ? strings.aiBrowsing
                      : '${strings.aiBrowsing}: $effectiveLabel',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colorScheme.onSurfaceVariant,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: onInterrupt,
                icon: const Icon(Icons.stop_circle_rounded, size: 18),
                label: Text(strings.interruptAiBrowsing),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _UnsupportedWebView extends StatelessWidget {
  final _WebViewStrings strings;

  const _UnsupportedWebView({required this.strings});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.language_rounded,
              size: 42,
              color: colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 12),
            Text(
              strings.unsupported,
              textAlign: TextAlign.center,
              style: TextStyle(color: colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 8),
            Text(
              defaultTargetPlatform.name,
              style: TextStyle(
                color: colorScheme.onSurfaceVariant.withValues(alpha: 0.7),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _WebViewStrings {
  final AppLanguage language;

  const _WebViewStrings(this.language);

  bool get _en => language == AppLanguage.en;

  String get title => _en ? 'WebView' : '网页';
  String get addressHint => _en ? 'URL or search keywords' : '网址或搜索关键词';
  String get go => _en ? 'Go' : '打开';
  String get back => _en ? 'Back' : '后退';
  String get forward => _en ? 'Forward' : '前进';
  String get refresh => _en ? 'Refresh' : '刷新';
  String get aiBrowsing =>
      _en ? 'AI is browsing' : 'AI \u6b63\u5728\u6d4f\u89c8';
  String get interruptAiBrowsing => _en ? 'Interrupt' : '\u6253\u65ad';
  String get unsupported => _en
      ? 'Client WebView is currently available on Android and iOS.'
      : '客户端 WebView 当前支持 Android 和 iOS。';
}
