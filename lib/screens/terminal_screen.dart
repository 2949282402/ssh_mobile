import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../models/connection.dart';
import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../widgets/connection_progress_dialog.dart';
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
  static const double _minTerminalFontSize = 1.0;
  static const double _maxTerminalFontSize = 28.0;

  late final Terminal _terminal;
  late final TerminalController _terminalController;
  late final FocusNode _terminalFocusNode;
  late final TextEditingController _complexInputController;
  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  VoidCallback? _sshListener;
  StreamSubscription<String>? _outputSubscription;
  SshSession? _subscribedSession;
  bool _loadedBufferedOutput = false;
  bool _reconnectInProgress = false;
  bool _hasShownDisconnectMessage = false;
  double _terminalFontSize = 14;
  Offset _lastLongPressPosition = Offset.zero;
  Timer? _longPressTimer;
  int _activePointers = 0;
  bool _terminalMenuOpen = false;
  bool _advancedKeyboardVisible = false;

  String? _serverName;

  TerminalStrings _strings(BuildContext context) {
    return TerminalStrings(context.read<AppSettings>().language);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _terminal = Terminal(
      maxLines: 10000,
      onOutput: (data) {
        if (!mounted) return;
        context.read<SshService>().sendData(widget.sessionId, data);
      },
    );
    _terminalController = TerminalController();
    _terminalFocusNode = FocusNode();
    _complexInputController = TextEditingController();
    _terminalFontSize =
        context.read<SshService>().getSession(widget.sessionId)?.fontSize ??
            _terminalFontSize;

    _loadServerInfo();
    _installSshListener();
    _attachExistingSession();
  }

  void _loadServerInfo() {
    final storage = context.read<StorageService>();
    final config = storage.getConnection(widget.connectionId);
    if (config != null) {
      setState(() => _serverName = config.name);
    }
  }

  void _installSshListener() {
    final ssh = context.read<SshService>();

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
    final ssh = context.read<SshService>();
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
    final strings = _strings(context);
    _terminal.write('\r\n\x1b[33m[${strings.reconnecting}]\x1b[0m\r\n');

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

  void _setupOutputStream(SshService ssh) {
    final session = ssh.getSession(widget.sessionId);
    if (session == null) return;
    if (identical(_subscribedSession, session)) return;

    _outputSubscription?.cancel();
    _subscribedSession = session;

    if (!_loadedBufferedOutput) {
      final bufferedOutput = session.outputText;
      if (bufferedOutput.isNotEmpty) {
        _terminal.write(bufferedOutput);
      }
      _loadedBufferedOutput = true;
    }

    _outputSubscription = session.output.listen(
      _terminal.write,
      onError: (error) {
        if (!mounted) return;
        _terminal.write('\r\n\x1b[31m[Error: $error]\x1b[0m\r\n');
      },
      onDone: () {
        if (!mounted) return;
        _terminal.write('\r\n\x1b[33m[Connection closed]\x1b[0m\r\n');
      },
    );
  }

  void _showDisconnected(String? reason) {
    if (_hasShownDisconnectMessage) return;
    _hasShownDisconnectMessage = true;
    _terminal.write(
      '\r\n\x1b[31m[Disconnected: ${reason ?? "unknown"}]\x1b[0m\r\n',
    );
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
    await _openSessionWindowWithOptions(context, connectionId);
  }

  Future<void> _openSessionWindowWithOptions(
    BuildContext context,
    String connectionId, {
    bool allowTmuxInstall = false,
  }) async {
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
      allowTmuxInstall: allowTmuxInstall,
    );
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (sessionId == null) {
      if (!allowTmuxInstall &&
          config?.launchMode == TerminalLaunchMode.tmux &&
          _isTmuxMissingError(ssh.errorMessage)) {
        final confirmed = await _confirmInstallTmux(context, connectionName);
        if (confirmed == true && context.mounted) {
          await _openSessionWindowWithOptions(
            context,
            connectionId,
            allowTmuxInstall: true,
          );
        }
        return;
      }

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

  bool _isTmuxMissingError(String? message) {
    return message?.toLowerCase().contains('tmux is not installed') == true;
  }

  String _formatConnectionFailure(TerminalStrings strings, String? message) {
    final text = message ?? strings.unknown;
    final lower = text.toLowerCase();
    if (lower.contains('tmux automatic install failed') ||
        lower.contains('unable to check tmux')) {
      return '${strings.connectionFailed(text)}\n请手动登录服务器安装 tmux 后再重试。';
    }
    return strings.connectionFailed(text);
  }

  Future<bool?> _confirmInstallTmux(
    BuildContext context,
    String connectionName,
  ) {
    return showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('服务器未安装 tmux'),
        content: Text(
          '连接 "$connectionName" 需要 tmux。是否允许应用在服务器上尝试安装 tmux？\n\n'
          '安装会使用服务器上的 apt、dnf、yum、pacman、zypper、apk 或 pkg，并且可能需要当前用户拥有免密 sudo 或 root 权限。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('同意安装'),
          ),
        ],
      ),
    );
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
      transitionDuration: const Duration(milliseconds: 180),
      reverseTransitionDuration: const Duration(milliseconds: 120),
      pageBuilder: (_, __, ___) => TerminalScreen(
        connectionId: session.connectionId,
        sessionId: session.id,
      ),
      transitionsBuilder: (_, animation, __, child) {
        final curved = CurvedAnimation(
          parent: animation,
          curve: Curves.easeOutCubic,
        );
        return FadeTransition(
          opacity: curved,
          child: child,
        );
      },
    );
  }

  TerminalTheme _terminalTheme(bool isDark, Color background) {
    if (!isDark) {
      return TerminalTheme(
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
      );
    }

    return TerminalTheme(
      background: background,
      foreground: const Color(0xFFCCCCCC),
      cursor: AppTheme.terminalGreen,
      selection: AppTheme.terminalGreen.withValues(alpha: 0.3),
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
  }

  Future<void> _showRenameDialog(BuildContext context) async {
    final strings = _strings(context);
    final ssh = context.read<SshService>();
    final session = ssh.getSession(widget.sessionId);
    if (session == null) return;

    var nextName = session.displayName;
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.renameWindow),
        content: TextFormField(
          initialValue: session.displayName,
          autofocus: true,
          decoration: InputDecoration(labelText: strings.windowName),
          textInputAction: TextInputAction.done,
          onChanged: (value) => nextName = value,
          onFieldSubmitted: (value) => Navigator.pop(ctx, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, nextName),
            child: Text(strings.save),
          ),
        ],
      ),
    );

    if (name == null) return;
    final renamed = ssh.renameSession(widget.sessionId, name);
    if (!renamed && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(strings.duplicateWindowName),
          backgroundColor: Colors.redAccent,
        ),
      );
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _attachExistingSession();
  }

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshService>();
    final appSettings = context.watch<AppSettings>();
    final strings = TerminalStrings(appSettings.language);
    final session = ssh.getSession(widget.sessionId);
    final isConnected = session?.isConnected == true;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final terminalBackground =
        isDark ? AppTheme.terminalBg : const Color(0xFFFAFBFC);
    final toolbarColor = isDark
        ? const Color(0xFF161B22)
        : Theme.of(context).colorScheme.surface;

    return Scaffold(
      appBar: TerminalScreenAppBar(
        strings: strings,
        session: session,
        serverName: _serverName,
        isConnected: isConnected,
        reconnectInProgress: _reconnectInProgress,
        onReconnect: _reconnectSession,
        onSwitchWindow: () => _showSessionSwitcher(context),
        onCloseWindow: () => _confirmDisconnect(context),
        onOpenSiblingSession: () => _openSiblingSession(context),
        onRenameWindow: () => _showRenameDialog(context),
        onSmallerFont: () {
          _setTerminalFontSize(_terminalFontSize - 1);
          _syncTerminalSize();
        },
        onLargerFont: () {
          _setTerminalFontSize(_terminalFontSize + 1);
          _syncTerminalSize();
        },
      ),
      body: Container(
        color: terminalBackground,
        child: Column(
          children: [
            Expanded(
              child: TerminalViewArea(
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
                onPointerUp: _handleTerminalPointerUp,
                onPointerCancel: _handleTerminalPointerCancel,
              ),
            ),
            TerminalShortcutPanel(
              sessionId: widget.sessionId,
              strings: strings,
              toolbarColor: toolbarColor,
              advancedKeyboardVisible: _advancedKeyboardVisible,
              complexInputController: _complexInputController,
              terminalFocusNode: _terminalFocusNode,
              onToggleAdvancedKeyboard: () {
                setState(
                  () => _advancedKeyboardVisible = !_advancedKeyboardVisible,
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _setTerminalFontSize(double size) {
    final nextSize = size.clamp(_minTerminalFontSize, _maxTerminalFontSize);
    if ((nextSize - _terminalFontSize).abs() < 0.05) return;
    setState(() => _terminalFontSize = nextSize);
    context.read<SshService>().setSessionFontSize(widget.sessionId, nextSize);
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
    _terminalFocusNode.requestFocus();
  }

  Future<void> _showTerminalEditMenu() async {
    if (_terminalMenuOpen) return;
    _terminalMenuOpen = true;
    _terminalFocusNode.requestFocus();
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
      ],
    );

    _terminalMenuOpen = false;

    if (!mounted || action == null) return;

    switch (action) {
      case _TerminalEditAction.selectCopy:
        _terminalController.clearSelection();
        await _showSelectableCopyLayer();
        break;
      case _TerminalEditAction.copy:
        if (selectedText.trim().isEmpty) return;
        await Clipboard.setData(ClipboardData(text: selectedText));
        _terminalController.clearSelection();
        break;
      case _TerminalEditAction.paste:
        final clipboard = await Clipboard.getData(Clipboard.kTextPlain);
        final text = clipboard?.text;
        if (text == null || text.isEmpty) return;
        if (!mounted) return;
        context.read<SshService>().sendData(widget.sessionId, text);
        break;
    }
  }

  void _handleTerminalPointerDown(PointerDownEvent event) {
    _activePointers += 1;
    _lastLongPressPosition = event.position;

    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted || _activePointers != 1 || _terminalMenuOpen) return;
      _selectWordAtLastLongPress();
      unawaited(_showTerminalEditMenu());
    });
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
    final selection = _terminalController.selection;
    if (selection == null) return '';
    return _terminal.buffer.getText(selection);
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

    _terminalFocusNode.requestFocus();
  }

  void _selectWordAtLastLongPress() {
    final terminalView = _terminalViewKey.currentState;
    if (terminalView == null) return;

    final renderTerminal = terminalView.renderTerminal;
    final localToTerminal =
        renderTerminal.globalToLocal(_lastLongPressPosition);
    final offset = renderTerminal.getCellOffset(localToTerminal);
    final boundary = _terminal.buffer.getWordBoundary(offset);

    if (boundary == null) {
      _terminalController.clearSelection();
      return;
    }

    _terminalController.setSelection(
      _terminal.buffer.createAnchorFromOffset(boundary.begin),
      _terminal.buffer.createAnchorFromOffset(boundary.end),
    );
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
      context.read<SshService>().removeListener(listener);
    }
    _outputSubscription?.cancel();
    _terminalController.dispose();
    _terminalFocusNode.dispose();
    _complexInputController.dispose();
    super.dispose();
  }
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
}

enum _NewWindowAction {
  current,
  editCurrent,
  addNew,
}
