import 'dart:async';
import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import 'package:animations/animations.dart';

import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/connection_progress_dialog.dart';
import '../widgets/window_name_dialog.dart';
import 'terminal/terminal_app_bar.dart';
import 'terminal/terminal_copy_screen.dart';
import 'terminal/terminal_shortcut_panel.dart';
import 'terminal/terminal_view_area.dart';

class TerminalScreen extends StatefulWidget {
  final String connectionId;
  final String sessionId;

  const TerminalScreen({
    super.key,
    required this.connectionId,
    required this.sessionId,
  });

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  static const double _minTerminalFontSize = SshSession.minTerminalFontSize;
  static const double _maxTerminalFontSize = SshSession.maxTerminalFontSize;
  static const int _maxTerminalFlushChars = 6000;
  static const int _terminalScrollbackLines = 4000;

  late final Terminal _terminal;
  late final TerminalController _terminalController;
  late final FocusNode _terminalFocusNode;
  late final FocusNode _windowsCommandInputFocusNode;
  late final FocusNode _terminalInputFocusNode;
  late final TextEditingController _complexInputController;
  late final TextEditingController _windowsCommandInputController;
  late final SshService _sshService;
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  VoidCallback? _sshListener;
  StreamSubscription<String>? _outputSubscription;
  final ListQueue<String> _pendingTerminalWrites = ListQueue<String>();
  int _pendingTerminalWriteChars = 0;
  SshSession? _subscribedSession;
  bool _terminalWriteScheduled = false;
  bool _loadedBufferedOutput = false;
  bool _loadingBufferedOutput = false;
  bool _reconnectInProgress = false;
  bool _hasShownDisconnectMessage = false;
  double _terminalFontSize = SshSession.defaultTerminalFontSize;
  Offset _lastLongPressPosition = Offset.zero;
  Timer? _longPressTimer;
  int _activePointers = 0;
  bool _terminalMenuOpen = false;
  bool _advancedKeyboardVisible = false;
  TerminalTheme? _cachedTerminalTheme;
  bool? _cachedTerminalThemeIsDark;
  Color? _cachedTerminalThemeBackground;

  String? _serverName;

  bool get _isWindowsTerminalTarget {
    return !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;
  }

  bool get _isDesktopTerminalTarget {
    return !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.linux);
  }

  bool get _useWindowsBottomShortcutPanel {
    return _isWindowsTerminalTarget;
  }

  TerminalStrings _strings(BuildContext context) {
    return TerminalStrings(context.read<AppSettings>().language);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _sshService = context.read<SshService>();

    _terminal = Terminal(
      // Keep the interactive scrollback bounded; full raw output still goes to
      // encrypted terminal history, while a huge xterm buffer makes touch
      // scrolling and repainting noticeably slower on phones.
      maxLines: _terminalScrollbackLines,
      onOutput: (data) {
        if (!mounted) return;
        _sshService.sendData(widget.sessionId, data);
      },
    );
    _terminalController = TerminalController();
    _terminalFocusNode = FocusNode();
    _windowsCommandInputFocusNode =
        FocusNode(debugLabel: 'Windows terminal command input');
    _terminalInputFocusNode = _isWindowsTerminalTarget
        ? _windowsCommandInputFocusNode
        : _terminalFocusNode;
    _complexInputController = TextEditingController();
    _windowsCommandInputController = TextEditingController();
    _terminalFontSize = (_sshService.getSession(widget.sessionId)?.fontSize ??
            _terminalFontSize)
        .clamp(_minTerminalFontSize, _maxTerminalFontSize)
        .toDouble();

    _loadServerInfo();
    _installSshListener();
    _attachExistingSession();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _requestWindowsAwareTerminalFocus();
    });
  }

  void _loadServerInfo() {
    final storage = context.read<StorageService>();
    final config = storage.getConnection(widget.connectionId);
    if (config != null) {
      setState(() => _serverName = config.name);
    }
  }

  void _installSshListener() {
    final ssh = _sshService;

    _sshListener = () {
      if (!mounted) return;
      final session = ssh.getSession(widget.sessionId);
      if (session?.isConnected == true) {
        _setupOutputStream(ssh);
      } else if (session?.state == SshConnectionState.disconnected ||
          session?.state == SshConnectionState.error) {
        _showDisconnected(session?.errorMessage);
      }
    };

    ssh.addListener(_sshListener!);
  }

  void _attachExistingSession() {
    final ssh = _sshService;
    final session = ssh.getSession(widget.sessionId);
    if (session?.isConnected == true) {
      _setupOutputStream(ssh);
      _hasShownDisconnectMessage = false;
    } else if (session != null) {
      _setupOutputStream(ssh);
      if (session.state == SshConnectionState.disconnected ||
          session.state == SshConnectionState.error) {
        _showDisconnected(session.errorMessage);
      }
    }
  }

  Future<void> _reconnectSession() async {
    if (_reconnectInProgress) return;
    _reconnectInProgress = true;

    final ssh = context.read<SshService>();

    final connected = await ssh.ensureSessionConnected(
      widget.sessionId,
      widget.connectionId,
    );
    if (!mounted) return;

    if (connected) {
      _setupOutputStream(ssh);
      _hasShownDisconnectMessage = false;
    } else {
      _showDisconnected(ssh.errorMessage);
    }

    _reconnectInProgress = false;
  }

  Future<void> _setupOutputStream(SshService ssh) async {
    final session = ssh.getSession(widget.sessionId);
    if (session == null) return;
    if (identical(_subscribedSession, session)) return;

    _outputSubscription?.cancel();
    _subscribedSession = session;
    final pendingOutput = StringBuffer();
    var queueLiveOutput = !_loadedBufferedOutput;

    _outputSubscription = session.output.listen(
      (data) {
        if (queueLiveOutput) {
          pendingOutput.write(data);
          return;
        }
        _queueTerminalWrite(data);
      },
      onError: (error) {
        if (!mounted) return;
        _queueTerminalWrite('\r\n\x1b[31m[Error: $error]\x1b[0m\r\n');
      },
      onDone: () {
        if (!mounted) return;
        _queueTerminalWrite('\r\n\x1b[33m[Connection closed]\x1b[0m\r\n');
      },
    );

    if (!_loadedBufferedOutput && !_loadingBufferedOutput) {
      if (mounted) {
        setState(() => _loadingBufferedOutput = true);
      } else {
        _loadingBufferedOutput = true;
      }
      try {
        final bufferedOutput = session.outputText;
        final initialOutput = bufferedOutput.isNotEmpty
            ? bufferedOutput
            : await ssh.loadSessionHistoryText(session.id);

        if (!mounted || !identical(_subscribedSession, session)) return;

        if (initialOutput.isNotEmpty) {
          _queueTerminalWrite(initialOutput);
        }

        final pending = pendingOutput.toString();
        if (pending.isNotEmpty && !initialOutput.endsWith(pending)) {
          _queueTerminalWrite(pending);
        }

        _loadedBufferedOutput = true;
      } finally {
        if (mounted && identical(_subscribedSession, session)) {
          setState(() => _loadingBufferedOutput = false);
        } else {
          _loadingBufferedOutput = false;
        }
        queueLiveOutput = false;
      }
    } else {
      queueLiveOutput = false;
    }
  }

  void _showDisconnected(String? reason) {
    if (_hasShownDisconnectMessage) return;
    _hasShownDisconnectMessage = true;
    _queueTerminalWrite(
      '\r\n\x1b[31m[Disconnected: ${reason ?? "unknown"}]\x1b[0m\r\n',
    );
  }

  void _queueTerminalWrite(String data) {
    if (!mounted || data.isEmpty) return;
    _pendingTerminalWrites.add(data);
    _pendingTerminalWriteChars += data.length;

    // Guard against massive streams causing Out Of Memory (OOM) or long UI freezes.
    // Since the scrollback is capped at 4000 lines, caching and processing
    // more than 200,000 characters of pending output is redundant and laggy.
    while (_pendingTerminalWriteChars > 200000 && _pendingTerminalWrites.length > 1) {
      final removed = _pendingTerminalWrites.removeFirst();
      _pendingTerminalWriteChars -= removed.length;
    }

    if (_terminalWriteScheduled) return;
    _terminalWriteScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _flushTerminalWrites();
    });
  }

  void _flushTerminalWrites() {
    if (!mounted) {
      _pendingTerminalWrites.clear();
      _pendingTerminalWriteChars = 0;
      _terminalWriteScheduled = false;
      return;
    }

    _terminalWriteScheduled = false;
    if (_pendingTerminalWrites.isEmpty) return;

    _clearTerminalSelection();
    final buffer = StringBuffer();
    var written = 0;

    while (
        _pendingTerminalWrites.isNotEmpty && written < _maxTerminalFlushChars) {
      final chunk = _pendingTerminalWrites.removeFirst();
      final remainingBudget = _maxTerminalFlushChars - written;
      if (chunk.length <= remainingBudget) {
        buffer.write(chunk);
        written += chunk.length;
        _pendingTerminalWriteChars -= chunk.length;
        continue;
      }

      buffer.write(chunk.substring(0, remainingBudget));
      _pendingTerminalWrites.addFirst(chunk.substring(remainingBudget));
      written += remainingBudget;
      _pendingTerminalWriteChars -= remainingBudget;
      break;
    }

    final text = buffer.toString();
    if (text.isNotEmpty) {
      try {
        _terminal.write(text);
      } catch (_) {
        // Drop malformed chunks rather than leaving xterm in a half-rendered UI
        // state. The raw stream remains in local history for debugging.
      }
    }

    if (_pendingTerminalWrites.isNotEmpty || _pendingTerminalWriteChars > 0) {
      _terminalWriteScheduled = true;
      WidgetsBinding.instance.scheduleFrameCallback((_) {
        _flushTerminalWrites();
      });
    }
  }

  Future<void> _openSiblingSession(BuildContext context) async {
    final strings = _strings(context);
    final action = await showDialog<_NewWindowAction>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.openNewWindow),
        content: Text(
          strings.createFrom(_serverName ?? strings.currentServer),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.editCurrent),
            child: Text(strings.editServer),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.addNew),
            child: Text(strings.addServer),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _NewWindowAction.current),
            child: Text(strings.create),
          ),
        ],
      ),
    );

    if (!context.mounted || action == null) return;

    switch (action) {
      case _NewWindowAction.current:
        await _openSessionWindow(context, widget.connectionId);
        break;
      case _NewWindowAction.editCurrent:
        final result = await Navigator.pushNamed(
          context,
          '/edit',
          arguments: widget.connectionId,
        );
        if (!context.mounted || result == null) return;
        await _openSessionWindow(context, widget.connectionId);
        break;
      case _NewWindowAction.addNew:
        final result = await Navigator.pushNamed(context, '/add');
        if (!context.mounted || result is! String) return;
        await _openSessionWindow(context, result);
        break;
    }
  }

  Future<void> _openSessionWindow(
    BuildContext context,
    String connectionId,
  ) async {
    final windowName = await _askWindowName(context, connectionId);
    if (!context.mounted || windowName == null) return;
    await _openSessionWindowWithOptions(context, connectionId, windowName);
  }

  Future<void> _openSessionWindowWithOptions(
    BuildContext context,
    String connectionId,
    String windowName,
  ) async {
    final strings = _strings(context);
    final ssh = context.read<SshService>();
    final storage = context.read<StorageService>();
    final config = storage.getConnection(connectionId);
    final connectionName = config?.name ?? _serverName ?? strings.currentServer;

    showDialog(
      context: context,
      barrierDismissible: false,
      useSafeArea: false,
      builder: (ctx) => ConnectionProgressDialog(
        title: strings.connectingTo(connectionName),
        message: strings.openingNewWindow,
      ),
    );

    await waitForConnectionProgressFrame();
    if (!context.mounted) return;

    final sessionId = await ssh.openSession(
      connectionId,
      displayName: windowName,
    );
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (sessionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _formatConnectionFailure(
              strings,
              ssh.errorMessage,
            ),
          ),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final session = ssh.getSession(sessionId);
    if (session == null) return;

    _replaceWithTerminalSession(session, animated: true);
  }

  Future<String?> _askWindowName(
    BuildContext context,
    String connectionId,
  ) async {
    final ssh = context.read<SshService>();
    return showDialog<String>(
      context: context,
      builder: (_) => WindowNameDialog(
        initialName: ssh.defaultDisplayNameForConnection(connectionId),
        isNameAvailable: ssh.isSessionNameAvailable,
      ),
    );
  }

  String _formatConnectionFailure(TerminalStrings strings, String? message) {
    final text = message ?? strings.unknown;
    final lower = text.toLowerCase();
    if (lower.contains('tmux is not installed') ||
        lower.contains('unable to check tmux')) {
      return strings.tmuxMissingHint(text);
    }
    return strings.connectionFailed(text);
  }

  Future<void> _showSessionSwitcher(BuildContext context) async {
    final strings = _strings(context);
    final ssh = context.read<SshService>();
    final sessions = ssh.sessions;
    if (sessions.isEmpty) return;

    final action = await showModalBottomSheet<_SessionSwitcherAction>(
      context: context,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => SafeArea(
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: sessions.length,
          separatorBuilder: (_, __) => const Divider(height: 1),
          itemBuilder: (context, index) {
            final session = sessions[index];
            final current = session.id == widget.sessionId;
            return ListTile(
              leading: Icon(
                session.isConnected ? Icons.link : Icons.link_off,
                color: session.isConnected
                    ? AppTheme.terminalGreen
                    : Colors.redAccent,
              ),
              title: Text(session.displayName),
              subtitle: Text(
                current
                    ? strings.currentWindow
                    : '${session.connectionName} - '
                        '${session.isConnected ? strings.connected : session.errorMessage ?? strings.disconnected}',
              ),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (current) const Icon(Icons.check),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: Colors.redAccent,
                    tooltip: session.isConnected
                        ? strings.disconnect
                        : strings.closeDisconnected,
                    onPressed: () => Navigator.pop(
                      ctx,
                      _SessionSwitcherAction.close(session.id),
                    ),
                  ),
                ],
              ),
              onTap: () => Navigator.pop(
                ctx,
                _SessionSwitcherAction.switchTo(session.id),
              ),
            );
          },
        ),
      ),
    );

    if (!context.mounted || action == null) return;

    if (action.close) {
      final closingCurrent = action.sessionId == widget.sessionId;
      await ssh.disconnectSession(action.sessionId);
      if (!context.mounted) return;

      if (closingCurrent) {
        final nextSession = _nextSessionAfterClose(ssh);
        if (nextSession != null) {
          _replaceWithTerminalSession(nextSession, animated: true);
        } else {
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      }
      return;
    }

    if (action.sessionId == widget.sessionId) return;

    final target = ssh.getSession(action.sessionId);
    if (target == null) return;

    _replaceWithTerminalSession(target);
  }

  SshSession? _nextSessionAfterClose(SshService ssh) {
    final otherSessions = ssh.sessions
        .where((session) => session.id != widget.sessionId)
        .toList()
        .reversed;
    for (final session in otherSessions) {
      if (session.isConnected) return session;
    }
    return otherSessions.isEmpty ? null : otherSessions.first;
  }

  void _replaceWithTerminalSession(
    SshSession session, {
    bool animated = false,
  }) {
    _clearTerminalSelection();
    Navigator.of(context).pushAndRemoveUntil(
      animated ? _fadeTerminalRoute(session) : _instantTerminalRoute(session),
      (route) => route.isFirst,
    );
  }

  Route<void> _instantTerminalRoute(SshSession session) {
    return PageRouteBuilder<void>(
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
      pageBuilder: (_, __, ___) => TerminalScreen(
        connectionId: session.connectionId,
        sessionId: session.id,
      ),
    );
  }

  Route<void> _fadeTerminalRoute(SshSession session) {
    return PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) => SharedAxisTransition(
        animation: animation,
        secondaryAnimation: secondaryAnimation,
        transitionType: SharedAxisTransitionType.scaled,
        child: TerminalScreen(
          connectionId: session.connectionId,
          sessionId: session.id,
        ),
      ),
    );
  }

  TerminalTheme _terminalTheme(bool isDark, Color background) {
    final cached = _cachedTerminalTheme;
    if (cached != null &&
        _cachedTerminalThemeIsDark == isDark &&
        _cachedTerminalThemeBackground == background) {
      return cached;
    }

    final theme = !isDark
        ? TerminalTheme(
            background: background,
            foreground: const Color(0xFF24292F),
            cursor: const Color(0xFF0969DA),
            selection: const Color(0xFF0969DA).withValues(alpha: 0.22),
            searchHitBackground: const Color(0xFFFFD33D),
            searchHitBackgroundCurrent: const Color(0xFFFFAB00),
            searchHitForeground: const Color(0xFF24292F),
            black: const Color(0xFF24292F),
            red: const Color(0xFFCF222E),
            green: const Color(0xFF116329),
            yellow: const Color(0xFF4D2D00),
            blue: const Color(0xFF0969DA),
            magenta: const Color(0xFF8250DF),
            cyan: const Color(0xFF1B7C83),
            white: const Color(0xFF6E7781),
            brightBlack: const Color(0xFF57606A),
            brightRed: const Color(0xFFA40E26),
            brightGreen: const Color(0xFF1A7F37),
            brightYellow: const Color(0xFF9A6700),
            brightBlue: const Color(0xFF218BFF),
            brightMagenta: const Color(0xFFA475F9),
            brightCyan: const Color(0xFF3192AA),
            brightWhite: const Color(0xFF24292F),
          )
        : TerminalTheme(
            background: background,
            foreground: const Color(0xFFCCCCCC),
            cursor: const Color(0xFF58A6FF),
            selection: const Color(0xFF58A6FF).withValues(alpha: 0.24),
            searchHitBackground: const Color(0xFF725C00),
            searchHitBackgroundCurrent: const Color(0xFFA88400),
            searchHitForeground: const Color(0xFFFFFFFF),
            black: const Color(0xFF1A1A2E),
            red: const Color(0xFFFF6B6B),
            green: const Color(0xFF00FF41),
            yellow: const Color(0xFFFFD93D),
            blue: const Color(0xFF58A6FF),
            magenta: const Color(0xFFB388FF),
            cyan: const Color(0xFF00D4FF),
            white: const Color(0xFFCCCCCC),
            brightBlack: const Color(0xFF4A4A5E),
            brightRed: const Color(0xFFFF8E8E),
            brightGreen: const Color(0xFF6BFF6B),
            brightYellow: const Color(0xFFFFF176),
            brightBlue: const Color(0xFF8BC4FF),
            brightMagenta: const Color(0xFFD1BFFF),
            brightCyan: const Color(0xFF80EBFF),
            brightWhite: const Color(0xFFFFFFFF),
          );
    _cachedTerminalTheme = theme;
    _cachedTerminalThemeIsDark = isDark;
    _cachedTerminalThemeBackground = background;
    return theme;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _attachExistingSession();
  }

  @override
  Widget build(BuildContext context) {
    final appSettings = context.select<AppSettings, _TerminalSettingsSnapshot>(
      _TerminalSettingsSnapshot.from,
    );
    final strings = TerminalStrings(appSettings.language);
    final sessionSnapshot =
        context.select<SshService, _TerminalSessionSnapshot>(
      (ssh) => _TerminalSessionSnapshot.from(ssh.getSession(widget.sessionId)),
    );
    final isConnected = sessionSnapshot.isConnected;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final terminalBackground =
        isDark ? AppTheme.terminalBg : const Color(0xFFFAFBFC);
    final toolbarColor = isDark
        ? const Color(0xFF161B22)
        : Theme.of(context).colorScheme.surface;
    final useWideDesktopSideShortcutPanel = !_useWindowsBottomShortcutPanel &&
        MediaQuery.sizeOf(context).width >= AppBreakpoints.wideDesktop;
    final terminalView = TerminalViewArea(
      terminalViewKey: _terminalViewKey,
      terminal: _terminal,
      controller: _terminalController,
      focusNode: _terminalFocusNode,
      theme: _terminalTheme(isDark, terminalBackground),
      fontSize: _terminalFontSize,
      minFontSize: _minTerminalFontSize,
      maxFontSize: _maxTerminalFontSize,
      onFontSizeChanged: _setTerminalFontSize,
      onScaleEnd: _syncTerminalSize,
      onPointerDown: _handleTerminalPointerDown,
      onPointerMove: _handleTerminalPointerMove,
      onPointerUp: _handleTerminalPointerUp,
      onPointerCancel: _handleTerminalPointerCancel,
      useWindowsCommandInput: _isWindowsTerminalTarget,
      onSecondaryTapUp: (details) {
        _lastLongPressPosition = details.globalPosition;
        _requestWindowsAwareTerminalFocus();
        unawaited(_showTerminalEditMenu());
      },
    );
    final shortcutPanel = TerminalShortcutPanel(
      sessionId: widget.sessionId,
      strings: strings,
      toolbarColor: toolbarColor,
      advancedKeyboardVisible: _advancedKeyboardVisible,
      complexInputController: _complexInputController,
      terminalFocusNode: _terminalInputFocusNode,
      onToggleAdvancedKeyboard: () {
        setState(
          () => _advancedKeyboardVisible = !_advancedKeyboardVisible,
        );
      },
    );

    return Scaffold(
      appBar: TerminalScreenAppBar(
        strings: strings,
        displayName: sessionSnapshot.displayName,
        serverName: _serverName,
        isConnected: isConnected,
        isDarkMode: appSettings.isDarkMode,
        reconnectInProgress: _reconnectInProgress,
        onReconnect: _reconnectSession,
        onToggleTheme: context.read<AppSettings>().toggleTheme,
        onSwitchWindow: () => _showSessionSwitcher(context),
        onCloseWindow: () => _confirmDisconnect(context),
        onOpenSiblingSession: () => _openSiblingSession(context),
        onSmallerFont: () {
          _setTerminalFontSize(_terminalFontSize - 1);
          _syncTerminalSize();
        },
        onLargerFont: () {
          _setTerminalFontSize(_terminalFontSize + 1);
          _syncTerminalSize();
        },
      ),
      body: Stack(
        children: [
          Container(
            color: terminalBackground,
            child: useWideDesktopSideShortcutPanel
                ? Row(
                    children: [
                      Expanded(child: terminalView),
                      SizedBox(
                        width: 360,
                        child: Align(
                          alignment: Alignment.topCenter,
                          child: shortcutPanel,
                        ),
                      ),
                    ],
                  )
                : Column(
                    children: [
                      Expanded(child: terminalView),
                      if (_isWindowsTerminalTarget)
                        _buildWindowsCommandInput(
                          context,
                          toolbarColor,
                          strings,
                        ),
                      shortcutPanel,
                    ],
                  ),
          ),
          if (_loadingBufferedOutput)
            ColoredBox(
              color: terminalBackground.withValues(alpha: 0.72),
              child: const Center(
                child: SizedBox(
                  width: 28,
                  height: 28,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _setTerminalFontSize(double size) {
    final nextSize = size.clamp(_minTerminalFontSize, _maxTerminalFontSize);
    if ((nextSize - _terminalFontSize).abs() < 0.05) return;
    setState(() => _terminalFontSize = nextSize);
    context.read<SshService>().setSessionFontSize(widget.sessionId, nextSize);
  }

  Widget _buildWindowsCommandInput(
    BuildContext context,
    Color toolbarColor,
    TerminalStrings strings,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final colorScheme = Theme.of(context).colorScheme;
    final borderColor =
        isDark ? const Color(0xFF30363D) : const Color(0xFFD0D7DE);

    return DecoratedBox(
      decoration: BoxDecoration(
        color: toolbarColor,
        border: Border(top: BorderSide(color: borderColor)),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Focus(
                onKeyEvent: _handleWindowsCommandInputKeyEvent,
                child: TextField(
                  controller: _windowsCommandInputController,
                  focusNode: _windowsCommandInputFocusNode,
                  autofocus: true,
                  minLines: 1,
                  maxLines: 4,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: InputDecoration(
                    hintText: strings.multilineHint,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 9,
                    ),
                    suffixText: 'Enter',
                    suffixStyle: TextStyle(
                      color: colorScheme.onSurface.withValues(alpha: 0.48),
                      fontSize: 12,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            SizedBox(
              height: 38,
              width: 42,
              child: IconButton(
                icon: const Icon(Icons.send, size: 20),
                tooltip: strings.send,
                onPressed: _sendWindowsCommandInput,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _syncTerminalSize() {
    final width = _terminal.viewWidth;
    final height = _terminal.viewHeight;
    if (width > 0 && height > 0) {
      context.read<SshService>().resizeTerminal(
            widget.sessionId,
            width,
            height,
          );
    }
    _requestWindowsAwareTerminalFocus();
  }

  void _requestWindowsAwareTerminalFocus() {
    if (_isWindowsTerminalTarget) {
      _windowsCommandInputFocusNode.requestFocus();
    } else {
      _terminalFocusNode.requestFocus();
    }
  }

  KeyEventResult _handleWindowsCommandInputKeyEvent(
    FocusNode focusNode,
    KeyEvent event,
  ) {
    if (!_isWindowsTerminalTarget || event is KeyUpEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.keyC &&
        HardwareKeyboard.instance.isControlPressed &&
        !HardwareKeyboard.instance.isAltPressed &&
        !HardwareKeyboard.instance.isMetaPressed) {
      final inputSelection = _windowsCommandInputController.selection;
      if (inputSelection.isValid && !inputSelection.isCollapsed) {
        return KeyEventResult.ignored;
      }

      final selectedText = _selectedTerminalText();
      if (selectedText.isNotEmpty) {
        Clipboard.setData(ClipboardData(text: selectedText));
        return KeyEventResult.handled;
      }
      return _sendTerminalKey(TerminalKey.keyC, ctrl: true);
    }

    if (event.logicalKey != LogicalKeyboardKey.enter &&
        event.logicalKey != LogicalKeyboardKey.numpadEnter) {
      return KeyEventResult.ignored;
    }

    final value = _windowsCommandInputController.value;
    if (!value.composing.isCollapsed) return KeyEventResult.ignored;

    if (HardwareKeyboard.instance.isShiftPressed) {
      _insertWindowsCommandInputText('\n');
      return KeyEventResult.handled;
    }

    _sendWindowsCommandInput();
    return KeyEventResult.handled;
  }

  KeyEventResult _sendTerminalKey(
    TerminalKey key, {
    bool ctrl = false,
    bool alt = false,
    bool shift = false,
  }) {
    final handled = _terminal.keyInput(
      key,
      ctrl: ctrl,
      alt: alt,
      shift: shift,
    );
    return handled ? KeyEventResult.handled : KeyEventResult.ignored;
  }

  void _insertWindowsCommandInputText(String text) {
    final value = _windowsCommandInputController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    final offset = selection.start + text.length;
    _windowsCommandInputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: offset),
    );
  }

  void _sendWindowsCommandInput() {
    final text = _windowsCommandInputController.text;
    if (text.isEmpty) {
      _sendTerminalKey(TerminalKey.enter);
      return;
    }

    context.read<SshService>().sendData(widget.sessionId, '$text\r');
    _windowsCommandInputController.clear();
    _requestWindowsAwareTerminalFocus();
  }

  Future<void> _showTerminalEditMenu() async {
    if (_terminalMenuOpen) return;
    _terminalMenuOpen = true;
    _requestWindowsAwareTerminalFocus();
    final strings = _strings(context);

    final selectedText = _selectedTerminalText();
    final action = await showMenu<_TerminalEditAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        _lastLongPressPosition.dx,
        _lastLongPressPosition.dy,
        _lastLongPressPosition.dx,
        _lastLongPressPosition.dy,
      ),
      items: [
        PopupMenuItem(
          value: _TerminalEditAction.selectCopy,
          child: Text(strings.selectCopy),
        ),
        PopupMenuItem(
          value: _TerminalEditAction.copy,
          enabled: selectedText.trim().isNotEmpty,
          child: Text(strings.copy),
        ),
        PopupMenuItem(
          value: _TerminalEditAction.paste,
          child: Text(strings.paste),
        ),
        if (_isDesktopTerminalTarget)
          PopupMenuItem(
            value: _TerminalEditAction.selectAll,
            child: Text(_selectAllLabel(context)),
          ),
      ],
    );

    _terminalMenuOpen = false;

    if (!mounted || action == null) return;

    switch (action) {
      case _TerminalEditAction.selectCopy:
        _clearTerminalSelection();
        await _showSelectableCopyLayer();
        break;
      case _TerminalEditAction.copy:
        if (selectedText.trim().isEmpty) return;
        await Clipboard.setData(ClipboardData(text: selectedText));
        _clearTerminalSelection();
        break;
      case _TerminalEditAction.paste:
        final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
        final text = clipboard?.text;
        if (text == null || text.isEmpty) return;
        if (!mounted) return;
        context.read<SshService>().sendData(widget.sessionId, text);
        break;
      case _TerminalEditAction.selectAll:
        _selectAllTerminalText();
        break;
    }
  }

  String _selectAllLabel(BuildContext context) {
    return AppStrings(context.read<AppSettings>().language).selectAll;
  }

  void _handleTerminalPointerDown(PointerDownEvent event) {
    _activePointers += 1;
    _lastLongPressPosition = event.position;
    _requestWindowsAwareTerminalFocus();

    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted || _activePointers != 1 || _terminalMenuOpen) return;
      _selectWordAtLastLongPress();
      unawaited(_showTerminalEditMenu());
    });
  }

  void _handleTerminalPointerMove(PointerMoveEvent event) {
    if ((event.position - _lastLongPressPosition).distance > 8) {
      _longPressTimer?.cancel();
    }
  }

  void _handleTerminalPointerUp(PointerUpEvent event) {
    _activePointers = (_activePointers - 1).clamp(0, 10);
    _longPressTimer?.cancel();
  }

  void _handleTerminalPointerCancel(PointerCancelEvent event) {
    _activePointers = 0;
    _longPressTimer?.cancel();
  }

  String _selectedTerminalText() {
    try {
      final selection = _terminalController.selection;
      if (selection == null) return '';
      return _terminal.buffer.getText(selection);
    } catch (_) {
      _clearTerminalSelection();
      return '';
    }
  }

  Future<void> _showSelectableCopyLayer() async {
    final strings = _strings(context);
    final text = _terminal.buffer.getText().trimRight();
    if (text.isEmpty) return;

    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => TerminalCopyScreen(
          title: _serverName ?? strings.defaultTerminal,
          text: text,
          copyAllTooltip: strings.copyAll,
        ),
      ),
    );

    _requestWindowsAwareTerminalFocus();
  }

  void _selectWordAtLastLongPress() {
    final terminalView = _terminalViewKey.currentState;
    if (terminalView == null) return;

    try {
      final renderTerminal = terminalView.renderTerminal;
      final localToTerminal =
          renderTerminal.globalToLocal(_lastLongPressPosition);
      final offset = renderTerminal.getCellOffset(localToTerminal);
      final boundary = _terminal.buffer.getWordBoundary(offset);

      if (boundary == null) {
        _clearTerminalSelection();
        return;
      }

      _terminalController.setSelection(
        _terminal.buffer.createAnchorFromOffset(boundary.begin),
        _terminal.buffer.createAnchorFromOffset(boundary.end),
      );
    } catch (_) {
      _clearTerminalSelection();
    }
  }

  void _clearTerminalSelection() {
    try {
      if (_terminalController.selection == null) return;
      _terminalController.clearSelection();
    } catch (_) {}
  }

  void _selectAllTerminalText() {
    try {
      _terminalController.setSelection(
        _terminal.buffer.createAnchor(
          0,
          _terminal.buffer.height - _terminal.viewHeight,
        ),
        _terminal.buffer.createAnchor(
          _terminal.viewWidth,
          _terminal.buffer.height - 1,
        ),
      );
    } catch (_) {
      _clearTerminalSelection();
    }
  }

  void _confirmDisconnect(BuildContext context) {
    final strings = _strings(context);
    final session = context.read<SshService>().getSession(widget.sessionId);
    final windowName =
        session?.displayName ?? _serverName ?? strings.defaultTerminal;
    final isConnected = session?.isConnected == true;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(
          isConnected ? strings.disconnect : strings.closeDisconnectedTitle,
        ),
        content: Text(
          isConnected
              ? strings.disconnectContent(windowName)
              : strings.closeDisconnectedContent(windowName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () async {
              final ssh = context.read<SshService>();
              Navigator.pop(ctx);
              await ssh.disconnectSession(widget.sessionId);
              if (!context.mounted) return;

              final nextSession = _nextSessionAfterClose(ssh);
              if (nextSession != null) {
                _replaceWithTerminalSession(nextSession, animated: true);
              } else {
                Navigator.of(context).popUntil((route) => route.isFirst);
              }
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(
                isConnected ? strings.disconnect : strings.closeDisconnected),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressTimer?.cancel();
    final listener = _sshListener;
    if (listener != null) {
      _sshService.removeListener(listener);
    }
    _outputSubscription?.cancel();
    _pendingTerminalWrites.clear();
    _pendingTerminalWriteChars = 0;
    _clearTerminalSelection();
    _terminalController.dispose();
    _terminalFocusNode.dispose();
    _windowsCommandInputFocusNode.dispose();
    _complexInputController.dispose();
    _windowsCommandInputController.dispose();
    super.dispose();
  }
}

class _TerminalSettingsSnapshot {
  final AppLanguage language;
  final bool isDarkMode;

  const _TerminalSettingsSnapshot({
    required this.language,
    required this.isDarkMode,
  });

  factory _TerminalSettingsSnapshot.from(AppSettings settings) {
    return _TerminalSettingsSnapshot(
      language: settings.language,
      isDarkMode: settings.isDarkMode,
    );
  }

  @override
  bool operator ==(Object other) {
    return other is _TerminalSettingsSnapshot &&
        other.language == language &&
        other.isDarkMode == isDarkMode;
  }

  @override
  int get hashCode => Object.hash(language, isDarkMode);
}

class _TerminalSessionSnapshot {
  final String? displayName;
  final SshConnectionState? state;
  final String? errorMessage;

  const _TerminalSessionSnapshot({
    required this.displayName,
    required this.state,
    required this.errorMessage,
  });

  factory _TerminalSessionSnapshot.from(SshSession? session) {
    return _TerminalSessionSnapshot(
      displayName: session?.displayName,
      state: session?.state,
      errorMessage: session?.errorMessage,
    );
  }

  bool get isConnected => state == SshConnectionState.connected;

  @override
  bool operator ==(Object other) {
    return other is _TerminalSessionSnapshot &&
        other.displayName == displayName &&
        other.state == state &&
        other.errorMessage == errorMessage;
  }

  @override
  int get hashCode => Object.hash(displayName, state, errorMessage);
}

class _SessionSwitcherAction {
  final String sessionId;
  final bool close;

  const _SessionSwitcherAction.switchTo(this.sessionId) : close = false;
  const _SessionSwitcherAction.close(this.sessionId) : close = true;
}

enum _TerminalEditAction {
  selectCopy,
  copy,
  paste,
  selectAll,
}

enum _NewWindowAction {
  current,
  editCurrent,
  addNew,
}
