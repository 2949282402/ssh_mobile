import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:gpt_markdown/gpt_markdown.dart';
import 'package:printing/printing.dart';
import 'package:provider/provider.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:ssh_mobile/features/sftp/viewmodels/sftp_viewmodel.dart';
import 'package:ssh_mobile/services/app_settings.dart';
import 'package:ssh_mobile/services/sftp_service.dart';

enum _PreviewKind {
  image,
  pdf,
  markdown,
  html,
  text,
  unsupported,
}

class SftpFileViewerScreen extends StatefulWidget {
  final SftpEntry entry;

  const SftpFileViewerScreen({
    super.key,
    required this.entry,
  });

  @override
  State<SftpFileViewerScreen> createState() => _SftpFileViewerScreenState();
}

class _SftpFileViewerScreenState extends State<SftpFileViewerScreen> {
  late final _PreviewKind _kind;
  Future<Uint8List>? _bytesFuture;
  Future<String>? _textFuture;
  bool _showSource = false;

  bool get _isTextPreview {
    return _kind == _PreviewKind.markdown ||
        _kind == _PreviewKind.html ||
        _kind == _PreviewKind.text;
  }

  @override
  void initState() {
    super.initState();
    _kind = _previewKind(widget.entry.name);
    if (_kind != _PreviewKind.unsupported) {
      final settings = context.read<AppSettings>();
      final limit = _previewLimitFor(_kind, settings);
      final download = context.read<SftpViewModel>().downloadBytes(
            widget.entry,
            maxBytes: limit,
          );
      if (_isTextPreview) {
        _textFuture = _decodeTextAsync(download);
      } else {
        _bytesFuture = download;
      }
    }
  }

  static String _parseUtf8(Uint8List bytes) {
    return utf8.decode(bytes, allowMalformed: true);
  }

  Future<String> _decodeTextAsync(Future<Uint8List> futureBytes) async {
    final bytes = await futureBytes;
    return compute(_parseUtf8, bytes);
  }

  @override
  Widget build(BuildContext context) {
    final language = context.select<AppSettings, AppLanguage>(
      (settings) => settings.language,
    );
    final strings = AppStrings(language);
    final canToggleSource =
        _kind == _PreviewKind.markdown || _kind == _PreviewKind.html;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Hero(
              tag: 'sftp_file_${widget.entry.path}',
              child: Material(
                type: MaterialType.transparency,
                child: Text(
                  widget.entry.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 15),
                ),
              ),
            ),
            Text(
              widget.entry.path,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: Theme.of(context)
                    .colorScheme
                    .onSurface
                    .withValues(alpha: 0.62),
                fontSize: 11,
              ),
            ),
          ],
        ),
        actions: [
          if (canToggleSource)
            IconButton(
              tooltip: _showSource ? strings.preview : strings.source,
              icon: Icon(
                  _showSource ? Icons.visibility_rounded : Icons.code_rounded),
              onPressed: () => setState(() => _showSource = !_showSource),
            ),
        ],
      ),
      body: !_isTextPreview
          ? (_bytesFuture == null
              ? _UnsupportedPreview(strings: strings)
              : FutureBuilder<Uint8List>(
                  future: _bytesFuture,
                  builder: (context, snapshot) {
                    if (snapshot.connectionState != ConnectionState.done) {
                      return const Center(
                        child: SizedBox(
                          width: 28,
                          height: 28,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      );
                    }
                    if (snapshot.hasError) {
                      return Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(strings.previewFailed(snapshot.error!)),
                        ),
                      );
                    }

                    final bytes = snapshot.data!;
                    switch (_kind) {
                      case _PreviewKind.image:
                        return _ImagePreview(bytes: bytes);
                      case _PreviewKind.pdf:
                        return PdfPreview(
                          build: (_) async => bytes,
                          allowPrinting: false,
                          allowSharing: false,
                          canChangeOrientation: false,
                          canChangePageFormat: false,
                          canDebug: false,
                        );
                      default:
                        return _UnsupportedPreview(strings: strings);
                    }
                  },
                ))
          : FutureBuilder<String>(
              future: _textFuture,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Center(
                    child: SizedBox(
                      width: 28,
                      height: 28,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  );
                }
                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(strings.previewFailed(snapshot.error!)),
                    ),
                  );
                }

                final text = snapshot.data!;
                if (_showSource && canToggleSource) {
                  return _TextPreview(text: text);
                }

                switch (_kind) {
                  case _PreviewKind.markdown:
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(16),
                      child: GptMarkdown(text),
                    );
                  case _PreviewKind.html:
                    return _HtmlPreview(
                      html: text,
                      fallbackLabel: strings.source,
                    );
                  case _PreviewKind.text:
                    return _TextPreview(text: text);
                  default:
                    return _UnsupportedPreview(strings: strings);
                }
              },
            ),
    );
  }

  _PreviewKind _previewKind(String filename) {
    final lower = filename.toLowerCase();
    if (lower.endsWith('.png') ||
        lower.endsWith('.jpg') ||
        lower.endsWith('.jpeg') ||
        lower.endsWith('.gif') ||
        lower.endsWith('.webp') ||
        lower.endsWith('.bmp')) {
      return _PreviewKind.image;
    }
    if (lower.endsWith('.pdf')) return _PreviewKind.pdf;
    if (lower.endsWith('.md') || lower.endsWith('.markdown')) {
      return _PreviewKind.markdown;
    }
    if (lower.endsWith('.html') || lower.endsWith('.htm')) {
      return _PreviewKind.html;
    }
    if (lower.endsWith('.txt') ||
        lower.endsWith('.log') ||
        lower.endsWith('.json') ||
        lower.endsWith('.yaml') ||
        lower.endsWith('.yml') ||
        lower.endsWith('.xml') ||
        lower.endsWith('.csv') ||
        lower.endsWith('.ini') ||
        lower.endsWith('.conf') ||
        lower.endsWith('.sh') ||
        lower.endsWith('.bash') ||
        lower.endsWith('.zsh') ||
        lower.endsWith('.py') ||
        lower.endsWith('.js') ||
        lower.endsWith('.ts') ||
        lower.endsWith('.css') ||
        lower.endsWith('.dart')) {
      return _PreviewKind.text;
    }
    return _PreviewKind.unsupported;
  }

  int _previewLimitFor(_PreviewKind kind, AppSettings settings) {
    switch (kind) {
      case _PreviewKind.text:
      case _PreviewKind.markdown:
      case _PreviewKind.html:
        return settings.sftpTextPreviewLimitBytes;
      case _PreviewKind.image:
      case _PreviewKind.pdf:
        return settings.sftpRichPreviewLimitBytes;
      case _PreviewKind.unsupported:
        return 0;
    }
  }
}

class _UnsupportedPreview extends StatelessWidget {
  final AppStrings strings;

  const _UnsupportedPreview({required this.strings});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Text(
          strings.unsupportedPreview,
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class _ImagePreview extends StatelessWidget {
  final Uint8List bytes;

  const _ImagePreview({required this.bytes});

  @override
  Widget build(BuildContext context) {
    return InteractiveViewer(
      minScale: 0.5,
      maxScale: 5,
      child: Center(
        child: Image.memory(bytes),
      ),
    );
  }
}

class _HtmlPreview extends StatefulWidget {
  final String html;
  final String fallbackLabel;

  const _HtmlPreview({
    required this.html,
    required this.fallbackLabel,
  });

  @override
  State<_HtmlPreview> createState() => _HtmlPreviewState();
}

class _HtmlPreviewState extends State<_HtmlPreview> {
  WebViewController? _controller;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS)) {
      _controller = WebViewController()..loadHtmlString(widget.html);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return _TextPreview(text: widget.html);
    }
    return WebViewWidget(controller: controller);
  }
}

class _TextPreview extends StatelessWidget {
  final String text;

  const _TextPreview({required this.text});

  @override
  Widget build(BuildContext context) {
    return Scrollbar(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          text,
          style: const TextStyle(
            fontFamily: 'monospace',
            fontFamilyFallback: [
              'Consolas',
              'Microsoft YaHei',
              'PingFang SC',
              'sans-serif'
            ],
            fontSize: 13,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}
