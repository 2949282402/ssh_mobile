import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:ssh_mobile/features/client_webview/viewmodels/client_webview_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/widgets/overflow_scroll_text.dart';

class ClientWebViewScreen extends StatefulWidget {
  final String chatId;

  const ClientWebViewScreen({super.key, required this.chatId});

  @override
  State<ClientWebViewScreen> createState() => _ClientWebViewScreenState();
}

class _ClientWebViewScreenState extends State<ClientWebViewScreen> {
  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<ClientWebViewViewModel>(
      create: (context) =>
          ClientWebViewViewModel(appSettings: context.read<AppSettings>())
            ..init(widget.chatId),
      child: Consumer<ClientWebViewViewModel>(
        builder: (context, viewModel, child) {
          final strings = _WebViewStrings(viewModel.language);

          return Scaffold(
            appBar: AppBar(
              title: OverflowScrollText(
                viewModel.title?.trim().isNotEmpty == true
                    ? viewModel.title!
                    : strings.title,
                selectable: false,
                maxLines: 1,
              ),
            ),
            body: !viewModel.supported || !viewModel.hasController
                ? _UnsupportedWebView(strings: strings)
                : Column(
                    children: [
                      _WebAddressBar(
                        controller: viewModel.urlController,
                        focusNode: viewModel.urlFocusNode,
                        strings: strings,
                        enabled: !viewModel.isAiBrowsing,
                        onSubmitted: (value) => viewModel.load(value),
                        onBack: viewModel.goBack,
                        onForward: viewModel.goForward,
                        onRefresh: viewModel.refresh,
                        searchEngine: viewModel.searchEngine,
                        onSearchEngineChanged: viewModel.updateSearchEngine,
                      ),
                      if (viewModel.isLoading && viewModel.progress < 100)
                        LinearProgressIndicator(
                          minHeight: 2,
                          value: viewModel.progress <= 0
                              ? null
                              : viewModel.progress / 100,
                        ),
                      Expanded(
                        child: Stack(
                          children: [
                            AbsorbPointer(
                              absorbing: viewModel.isAiBrowsing,
                              child: WebViewWidget(
                                controller: viewModel.session.controller!,
                              ),
                            ),
                            if (viewModel.isAiBrowsing) ...[
                              const Positioned.fill(
                                child: ModalBarrier(
                                  dismissible: false,
                                  color: Colors.transparent,
                                ),
                              ),
                              _AiBrowsingBanner(
                                strings: strings,
                                label: viewModel.aiBrowsingLabel,
                                onInterrupt: viewModel.interruptAiBrowsing,
                              ),
                            ],
                            if (viewModel.lastError != null &&
                                viewModel.lastError!.trim().isNotEmpty)
                              Align(
                                alignment: Alignment.bottomCenter,
                                child: SafeArea(
                                  top: false,
                                  child: Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.all(12),
                                    padding: const EdgeInsets.all(10),
                                    decoration: BoxDecoration(
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.errorContainer,
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    child: OverflowScrollText(
                                      viewModel.lastError!,
                                      selectable: true,
                                      maxLines: 2,
                                      style: TextStyle(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.onErrorContainer,
                                        fontSize: 12,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
          );
        },
      ),
    );
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
  final String searchEngine;
  final ValueChanged<String> onSearchEngineChanged;

  const _WebAddressBar({
    required this.controller,
    required this.focusNode,
    required this.strings,
    required this.enabled,
    required this.onSubmitted,
    required this.onBack,
    required this.onForward,
    required this.onRefresh,
    required this.searchEngine,
    required this.onSearchEngineChanged,
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
                      onPressed: enabled
                          ? () => onSubmitted(controller.text)
                          : null,
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
              PopupMenuButton<String>(
                tooltip: strings.searchEngine,
                initialValue: searchEngine,
                enabled: enabled,
                onSelected: onSearchEngineChanged,
                icon: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.search_rounded),
                    Icon(
                      Icons.arrow_drop_down_rounded,
                      size: 14,
                      color: colorScheme.onSurfaceVariant.withValues(
                        alpha: 0.6,
                      ),
                    ),
                  ],
                ),
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'baidu',
                    child: Text('百度 (Baidu)'),
                  ),
                  const PopupMenuItem(
                    value: 'google',
                    child: Text('谷歌 (Google)'),
                  ),
                  const PopupMenuItem(value: 'bing', child: Text('必应 (Bing)')),
                  const PopupMenuItem(
                    value: 'duckduckgo',
                    child: Text('DuckDuckGo'),
                  ),
                ],
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
                child: OverflowScrollText(
                  effectiveLabel == null || effectiveLabel.isEmpty
                      ? strings.aiBrowsing
                      : '${strings.aiBrowsing}: $effectiveLabel',
                  selectable: false,
                  maxLines: 1,
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
  String get searchEngine => _en ? 'Search Engine' : '搜索引擎';
  String get aiBrowsing => _en ? 'AI is browsing' : 'AI 正在浏览';
  String get interruptAiBrowsing => _en ? 'Interrupt' : '打断';
  String get unsupported => _en
      ? 'Client WebView is currently available on Android and iOS.'
      : '客户端 WebView 当前支持 Android 和 iOS。';
}
