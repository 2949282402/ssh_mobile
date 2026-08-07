part of '../sftp_file_viewer_screen.dart';

class _TextPreview extends StatefulWidget {
  const _TextPreview({super.key, required this.text});

  final String text;

  @override
  State<_TextPreview> createState() => _TextPreviewState();
}

class _TextPreviewState extends State<_TextPreview> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scrollbar(
      controller: _scrollController,
      interactive: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(18),
        child: SelectableText(
          widget.text,
          style: theme.textTheme.bodyMedium?.copyWith(
            fontFamily: 'monospace',
            fontFamilyFallback: AppTheme.monospaceFallback,
            fontSize: 13,
            height: 1.45,
          ),
        ),
      ),
    );
  }
}

class _MarkdownPreview extends StatefulWidget {
  const _MarkdownPreview({required this.text, required this.strings});

  final String text;
  final AppStrings strings;

  @override
  State<_MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<_MarkdownPreview> {
  final ScrollController _scrollController = ScrollController();

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scrollbar(
      key: const ValueKey('sftp-viewer-markdown'),
      controller: _scrollController,
      interactive: true,
      child: SingleChildScrollView(
        controller: _scrollController,
        padding: const EdgeInsets.all(18),
        child: SelectionArea(
          child: GptMarkdown(
            widget.text,
            style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
            textDirection: Directionality.of(context),
            inlineComponents: _safeMarkdownInlineComponents,
            imageBuilder: (context, imageUrl, width, height) {
              return Semantics(
                label: widget.strings.externalPreviewContentBlocked,
                child: Tooltip(
                  message: widget.strings.externalPreviewContentBlocked,
                  child: const Padding(
                    padding: EdgeInsets.all(12),
                    child: Icon(Icons.image_not_supported_outlined),
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
  }
}

final List<MarkdownComponent> _safeMarkdownInlineComponents =
    List<MarkdownComponent>.unmodifiable(
      MarkdownComponent.inlineComponents.where(
        (component) => component is! ATagMd,
      ),
    );

class _ImagePreview extends StatelessWidget {
  const _ImagePreview({
    required this.bytes,
    required this.metadata,
    required this.strings,
    required this.path,
    required this.onRetry,
    this.providerBuilderForTesting,
  });

  final Uint8List bytes;
  final _ImageMetadata metadata;
  final AppStrings strings;
  final String path;
  final VoidCallback onRetry;
  final SftpViewerImageProviderBuilder? providerBuilderForTesting;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final devicePixelRatio = MediaQuery.devicePixelRatioOf(context);
        final targetSize = _boundedPixelSize(
          metadata.size,
          maxWidth: math.min(4096, constraints.maxWidth * devicePixelRatio * 2),
          maxHeight: math.min(
            4096,
            constraints.maxHeight * devicePixelRatio * 2,
          ),
          maxPixels: _maxDecodedImagePixels,
          allowUpscaling: false,
        );
        final targetWidth = targetSize.width.round();
        final targetHeight = targetSize.height.round();
        final provider =
            providerBuilderForTesting?.call(bytes, targetWidth, targetHeight) ??
            ResizeImage(
              MemoryImage(bytes),
              width: targetWidth,
              height: targetHeight,
              policy: ResizeImagePolicy.fit,
            );
        return _ResolvedImagePreview(
          imageProvider: provider,
          semanticLabel: strings.imagePreviewLabel,
          strings: strings,
          loadingWidget: _InlineLoading(
            key: const ValueKey('sftp-viewer-image-decoding'),
            label: strings.loadingFilePreview,
          ),
          errorBuilder: (context, error, stackTrace) => _LoggedRenderError(
            key: const ValueKey('sftp-viewer-image-error'),
            error: error,
            stackTrace: stackTrace,
            logMessage: 'SFTP image preview render failed',
            path: path,
            strings: strings,
            onRetry: onRetry,
          ),
        );
      },
    );
  }
}

class _ResolvedImagePreview extends StatefulWidget {
  const _ResolvedImagePreview({
    required this.imageProvider,
    required this.semanticLabel,
    required this.strings,
    required this.loadingWidget,
    required this.errorBuilder,
  });

  final ImageProvider imageProvider;
  final String semanticLabel;
  final AppStrings strings;
  final Widget loadingWidget;
  final Widget Function(
    BuildContext context,
    Object error,
    StackTrace? stackTrace,
  )
  errorBuilder;

  @override
  State<_ResolvedImagePreview> createState() => _ResolvedImagePreviewState();
}

class _ResolvedImagePreviewState extends State<_ResolvedImagePreview> {
  Object? _error;
  StackTrace? _stackTrace;
  var _firstFrameReady = false;
  var _readyScheduled = false;
  var _providerGeneration = 0;

  @override
  void didUpdateWidget(covariant _ResolvedImagePreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageProvider != widget.imageProvider) {
      _providerGeneration += 1;
      _error = null;
      _stackTrace = null;
      _firstFrameReady = false;
      _readyScheduled = false;
    }
  }

  void _scheduleFirstFrameReady() {
    if (_firstFrameReady || _readyScheduled) return;
    _readyScheduled = true;
    final generation = _providerGeneration;
    scheduleMicrotask(() {
      if (!mounted || generation != _providerGeneration || _firstFrameReady) {
        return;
      }
      setState(() {
        _readyScheduled = false;
        _firstFrameReady = true;
      });
    });
  }

  void _recordZoomError(Object error, StackTrace? stackTrace) {
    if (_error != null) return;
    _error = error;
    _stackTrace = stackTrace;
    scheduleMicrotask(() {
      if (mounted && identical(_error, error)) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return widget.errorBuilder(context, error, _stackTrace);
    }
    if (_firstFrameReady) {
      return _ZoomableImageSurface(
        key: const ValueKey('sftp-viewer-image'),
        imageProvider: widget.imageProvider,
        semanticLabel: widget.semanticLabel,
        strings: widget.strings,
        onImageError: _recordZoomError,
      );
    }
    return Image(
      image: widget.imageProvider,
      fit: BoxFit.contain,
      excludeFromSemantics: true,
      frameBuilder: (context, child, frame, wasSynchronouslyLoaded) {
        if (frame == null) return widget.loadingWidget;
        _scheduleFirstFrameReady();
        return child;
      },
      errorBuilder: widget.errorBuilder,
    );
  }
}

class _ZoomableImageSurface extends StatefulWidget {
  const _ZoomableImageSurface({
    super.key,
    required this.imageProvider,
    required this.semanticLabel,
    required this.strings,
    required this.onImageError,
  });

  final ImageProvider imageProvider;
  final String semanticLabel;
  final AppStrings strings;
  final void Function(Object error, StackTrace? stackTrace) onImageError;

  @override
  State<_ZoomableImageSurface> createState() => _ZoomableImageSurfaceState();
}

class _ZoomableImageSurfaceState extends State<_ZoomableImageSurface> {
  final TransformationController _transformationController =
      TransformationController();
  double _scale = 1;

  @override
  void initState() {
    super.initState();
    _transformationController.addListener(_onTransformChanged);
  }

  @override
  void didUpdateWidget(covariant _ZoomableImageSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.imageProvider != widget.imageProvider) _resetZoom();
  }

  @override
  void dispose() {
    _transformationController
      ..removeListener(_onTransformChanged)
      ..dispose();
    super.dispose();
  }

  void _onTransformChanged() {
    final nextScale = _transformationController.value.getMaxScaleOnAxis();
    if ((nextScale - _scale).abs() < 0.005 || !mounted) return;
    setState(() => _scale = nextScale);
  }

  void _zoomIn() => _setZoom((_scale + 0.5).clamp(0.5, 4));

  void _zoomOut() => _setZoom((_scale - 0.5).clamp(0.5, 4));

  void _resetZoom() => _setZoom(1);

  void _setZoom(double scale) {
    final size = context.size;
    if (size == null || !size.isFinite || size.isEmpty) return;
    final matrix = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, size.width * (1 - scale) / 2)
      ..setEntry(1, 3, size.height * (1 - scale) / 2);
    _transformationController.value = matrix;
  }

  @override
  Widget build(BuildContext context) {
    final zoomValue = widget.strings.imageZoomLevel((_scale * 100).round());
    return Semantics(
      container: true,
      label: widget.semanticLabel,
      value: zoomValue,
      increasedValue: _scale < 4
          ? widget.strings.imageZoomLevel(((_scale + 0.5) * 100).round())
          : null,
      decreasedValue: _scale > 0.5
          ? widget.strings.imageZoomLevel(((_scale - 0.5) * 100).round())
          : null,
      onIncrease: _scale < 4 ? _zoomIn : null,
      onDecrease: _scale > 0.5 ? _zoomOut : null,
      child: CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.equal, control: true):
              _zoomIn,
          const SingleActivator(LogicalKeyboardKey.minus, control: true):
              _zoomOut,
          const SingleActivator(LogicalKeyboardKey.digit0, control: true):
              _resetZoom,
        },
        child: Focus(
          child: Stack(
            fit: StackFit.expand,
            children: [
              InteractiveViewer(
                transformationController: _transformationController,
                minScale: 0.5,
                maxScale: 4,
                child: SizedBox.expand(
                  child: Image(
                    image: widget.imageProvider,
                    fit: BoxFit.contain,
                    filterQuality: FilterQuality.medium,
                    gaplessPlayback: true,
                    excludeFromSemantics: true,
                    errorBuilder: (context, error, stackTrace) {
                      widget.onImageError(error, stackTrace);
                      return const SizedBox.shrink();
                    },
                  ),
                ),
              ),
              Positioned(
                right: 12,
                bottom: 12,
                child: Card(
                  margin: EdgeInsets.zero,
                  elevation: 2,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _ZoomButton(
                        key: const ValueKey('sftp-viewer-zoom-out'),
                        tooltip: widget.strings.zoomOut,
                        icon: Icons.zoom_out_rounded,
                        onPressed: _scale > 0.5 ? _zoomOut : null,
                      ),
                      _ZoomButton(
                        key: const ValueKey('sftp-viewer-zoom-reset'),
                        tooltip: '${widget.strings.resetZoom} · $zoomValue',
                        icon: Icons.fit_screen_rounded,
                        onPressed: _resetZoom,
                      ),
                      _ZoomButton(
                        key: const ValueKey('sftp-viewer-zoom-in'),
                        tooltip: widget.strings.zoomIn,
                        icon: Icons.zoom_in_rounded,
                        onPressed: _scale < 4 ? _zoomIn : null,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ZoomButton extends StatelessWidget {
  const _ZoomButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: tooltip,
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      visualDensity: VisualDensity.standard,
      onPressed: onPressed,
      icon: Icon(icon),
    );
  }
}

class _SecureHtmlPreview extends StatefulWidget {
  const _SecureHtmlPreview({
    super.key,
    required this.sandboxedHtml,
    required this.backgroundColor,
    required this.loadingWidget,
    required this.errorBuilder,
  });

  final String sandboxedHtml;
  final Color backgroundColor;
  final Widget loadingWidget;
  final Widget Function(BuildContext context, Object error) errorBuilder;

  @override
  State<_SecureHtmlPreview> createState() => _SecureHtmlPreviewState();
}

class _SecureHtmlPreviewState extends State<_SecureHtmlPreview> {
  late Future<WebViewController> _controllerFuture;
  Object? _mainFrameError;
  var _loadGeneration = 0;

  @override
  void initState() {
    super.initState();
    _controllerFuture = _startControllerLoad();
  }

  @override
  void didUpdateWidget(covariant _SecureHtmlPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sandboxedHtml != widget.sandboxedHtml ||
        oldWidget.backgroundColor != widget.backgroundColor) {
      _mainFrameError = null;
      _controllerFuture = _startControllerLoad();
    }
  }

  Future<WebViewController> _startControllerLoad() {
    _loadGeneration += 1;
    return _createController(
      generation: _loadGeneration,
      sandboxedHtml: widget.sandboxedHtml,
      backgroundColor: widget.backgroundColor,
    );
  }

  Future<WebViewController> _createController({
    required int generation,
    required String sandboxedHtml,
    required Color backgroundColor,
  }) async {
    final controller = WebViewController(
      onPermissionRequest: (request) => unawaited(request.deny()),
    );
    await controller.setJavaScriptMode(JavaScriptMode.disabled);
    await controller.setBackgroundColor(backgroundColor);
    await controller.enableZoom(true);
    await controller.setNavigationDelegate(
      NavigationDelegate(
        onNavigationRequest: (request) {
          final url = request.url;
          final isBlank =
              url == 'about:blank' || url.startsWith('about:blank#');
          return isBlank
              ? NavigationDecision.navigate
              : NavigationDecision.prevent;
        },
        onWebResourceError: (error) {
          if (error.isForMainFrame == false ||
              !mounted ||
              generation != _loadGeneration) {
            return;
          }
          setState(() => _mainFrameError = error);
        },
      ),
    );
    await controller.loadHtmlString(sandboxedHtml);
    return controller;
  }

  @override
  Widget build(BuildContext context) {
    final mainFrameError = _mainFrameError;
    if (mainFrameError != null) {
      return widget.errorBuilder(context, mainFrameError);
    }
    return FutureBuilder<WebViewController>(
      future: _controllerFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return widget.loadingWidget;
        }
        if (snapshot.hasError) {
          return widget.errorBuilder(context, snapshot.error!);
        }
        return WebViewWidget(controller: snapshot.data!);
      },
    );
  }
}
