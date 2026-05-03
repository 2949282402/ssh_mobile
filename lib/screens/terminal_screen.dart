import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../services/shortcut_command_service.dart';
import '../theme/app_theme.dart';

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
  double _scaleStartFontSize = 14;
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
    _scaleStartFontSize = _terminalFontSize;

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
    final strings = _strings(context);
    final ssh = context.read<SshService>();
    final storage = context.read<StorageService>();
    final connectionName = storage.getConnection(connectionId)?.name ??
        _serverName ??
        strings.currentServer;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: Text(strings.connectingTo(connectionName)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 40,
              height: 40,
              child: CircularProgressIndicator(),
            ),
            const SizedBox(height: 16),
            Text(strings.openingNewWindow),
          ],
        ),
      ),
    );

    final sessionId = await ssh.openSession(connectionId);
    if (!context.mounted) return;
    Navigator.of(context).pop();

    if (sessionId == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
              strings.connectionFailed(ssh.errorMessage ?? strings.unknown)),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    Navigator.pushNamed(
      context,
      '/terminal',
      arguments: {
        'id': connectionId,
        'sessionId': sessionId,
      },
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
          Navigator.of(context).pushReplacement(
            _animatedTerminalRoute(nextSession),
          );
        } else {
          Navigator.pop(context);
        }
      }
      return;
    }

    if (action.sessionId == widget.sessionId) return;

    final target = ssh.getSession(action.sessionId);
    if (target == null) return;

    Navigator.pushReplacementNamed(
      context,
      '/terminal',
      arguments: {
        'id': target.connectionId,
        'sessionId': target.id,
      },
    );
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

  Route<void> _animatedTerminalRoute(SshSession session) {
    return PageRouteBuilder<void>(
      transitionDuration: const Duration(milliseconds: 260),
      reverseTransitionDuration: const Duration(milliseconds: 180),
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
          child: SlideTransition(
            position: Tween<Offset>(
              begin: const Offset(0.08, 0),
              end: Offset.zero,
            ).animate(curved),
            child: child,
          ),
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
    ssh.renameSession(widget.sessionId, name);
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
    final closeColor = isConnected ? Colors.redAccent : Colors.orangeAccent;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final terminalBackground =
        isDark ? AppTheme.terminalBg : const Color(0xFFFAFBFC);
    final toolbarColor = isDark
        ? const Color(0xFF161B22)
        : Theme.of(context).colorScheme.surface;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    session?.displayName ??
                        _serverName ??
                        strings.defaultTerminal,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    icon: const Icon(Icons.add, size: 18),
                    tooltip: strings.newWindow,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _openSiblingSession(context),
                  ),
                ),
                SizedBox(
                  width: 28,
                  height: 28,
                  child: IconButton(
                    icon: const Icon(Icons.edit, size: 16),
                    tooltip: strings.renameWindow,
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _showRenameDialog(context),
                  ),
                ),
              ],
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isConnected ? strings.connected : strings.disconnected,
                  style: TextStyle(
                    fontSize: 11,
                    color:
                        isConnected ? AppTheme.terminalGreen : Colors.redAccent,
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  strings.fontSize,
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.8),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 2),
                _fontSizeButton(Icons.remove, strings.smallerFont, -1),
                const SizedBox(width: 2),
                _fontSizeButton(Icons.add, strings.largerFont, 1),
              ],
            ),
          ],
        ),
        actions: [
          if (!isConnected)
            IconButton(
              icon: const Icon(Icons.refresh, size: 20),
              tooltip: strings.reconnect,
              onPressed: _reconnectInProgress ? null : _reconnectSession,
            ),
          IconButton(
            icon: const Icon(Icons.view_list, size: 20),
            tooltip: strings.switchWindow,
            onPressed: () => _showSessionSwitcher(context),
          ),
          IconButton(
            icon: Icon(
              isConnected ? Icons.power_settings_new : Icons.warning_amber,
              color: closeColor,
            ),
            tooltip:
                isConnected ? strings.disconnect : strings.closeDisconnected,
            onPressed: () => _confirmDisconnect(context),
          ),
        ],
      ),
      body: Container(
        color: terminalBackground,
        child: Column(
          children: [
            Expanded(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: _handleTerminalPointerDown,
                onPointerUp: _handleTerminalPointerUp,
                onPointerCancel: _handleTerminalPointerCancel,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onScaleStart: (details) {
                    _scaleStartFontSize = _terminalFontSize;
                  },
                  onScaleUpdate: (details) {
                    if (details.pointerCount < 2) return;
                    final nextSize =
                        (_scaleStartFontSize * details.scale).clamp(
                      _minTerminalFontSize,
                      _maxTerminalFontSize,
                    );
                    _setTerminalFontSize(nextSize);
                  },
                  onScaleEnd: (_) => _syncTerminalSize(),
                  child: Stack(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(4),
                        child: TerminalView(
                          key: _terminalViewKey,
                          _terminal,
                          controller: _terminalController,
                          focusNode: _terminalFocusNode,
                          autofocus: true,
                          backgroundOpacity: 1,
                          textStyle: TerminalStyle(fontSize: _terminalFontSize),
                          theme: _terminalTheme(isDark, terminalBackground),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Container(
              color: toolbarColor,
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(child: _buildShortcutBar(context)),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(Icons.add_circle_outline, size: 20),
                        tooltip: strings.addShortcut,
                        onPressed: () => _showAddShortcutDialog(
                          context,
                          strings,
                        ),
                      ),
                      const SizedBox(width: 4),
                      IconButton(
                        icon: Icon(
                          _advancedKeyboardVisible
                              ? Icons.keyboard_hide
                              : Icons.keyboard_command_key,
                          size: 20,
                        ),
                        tooltip: strings.complexKeyboard,
                        onPressed: () {
                          setState(
                            () => _advancedKeyboardVisible =
                                !_advancedKeyboardVisible,
                          );
                        },
                      ),
                    ],
                  ),
                  if (_advancedKeyboardVisible) _buildAdvancedKeyboard(context),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShortcutBar(BuildContext context) {
    final shortcuts = context.watch<ShortcutCommandService>();
    final commands = shortcuts.sortByUsage([
      const ShortcutCommand(id: 'tab', label: 'TAB', code: '\t'),
      const ShortcutCommand(id: 'esc', label: 'ESC', code: '\x1b'),
      const ShortcutCommand(id: 'enter', label: 'ENTER', code: '\r'),
      const ShortcutCommand(id: 'bksp', label: 'BKSP', code: '\x7f'),
      const ShortcutCommand(id: 'up', label: '↑', code: '\x1b[A'),
      const ShortcutCommand(id: 'down', label: '↓', code: '\x1b[B'),
      const ShortcutCommand(id: 'left', label: '←', code: '\x1b[D'),
      const ShortcutCommand(id: 'right', label: '→', code: '\x1b[C'),
      const ShortcutCommand(id: 'home', label: 'HOME', code: '\x1b[H'),
      const ShortcutCommand(id: 'end', label: 'END', code: '\x1b[F'),
      const ShortcutCommand(id: 'pgup', label: 'PGUP', code: '\x1b[5~'),
      const ShortcutCommand(id: 'pgdn', label: 'PGDN', code: '\x1b[6~'),
      const ShortcutCommand(id: 'ctrl_c', label: 'CTRL+C', code: '\x03'),
      const ShortcutCommand(id: 'ctrl_d', label: 'CTRL+D', code: '\x04'),
      const ShortcutCommand(id: 'ctrl_l', label: 'CTRL+L', code: '\x0c'),
      ...shortcuts.customCommands,
    ]);

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children:
            commands.map((command) => _quickKey(context, command)).toList(),
      ),
    );
  }

  Widget _buildAdvancedKeyboard(BuildContext context) {
    final strings = _strings(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _keyGroup(context, [
            _KeySpec('INS', '\x1b[2~'),
            _KeySpec('DEL', '\x1b[3~'),
            _KeySpec('SPACE', ' '),
            _KeySpec('CTRL+A', '\x01'),
            _KeySpec('CTRL+E', '\x05'),
            _KeySpec('CTRL+U', '\x15'),
            _KeySpec('CTRL+K', '\x0b'),
            _KeySpec('CTRL+W', '\x17'),
            _KeySpec('CTRL+R', '\x12'),
            _KeySpec('CTRL+Z', '\x1a'),
            _KeySpec('CTRL+\\', '\x1c'),
          ]),
          const SizedBox(height: 4),
          _keyGroup(context, [
            _KeySpec('ALT+B', '\x1bb'),
            _KeySpec('ALT+F', '\x1bf'),
            _KeySpec('ALT+D', '\x1bd'),
            _KeySpec('F1', '\x1bOP'),
            _KeySpec('F2', '\x1bOQ'),
            _KeySpec('F3', '\x1bOR'),
            _KeySpec('F4', '\x1bOS'),
            _KeySpec('F5', '\x1b[15~'),
            _KeySpec('F6', '\x1b[17~'),
            _KeySpec('F7', '\x1b[18~'),
            _KeySpec('F8', '\x1b[19~'),
            _KeySpec('F9', '\x1b[20~'),
            _KeySpec('F10', '\x1b[21~'),
            _KeySpec('F11', '\x1b[23~'),
            _KeySpec('F12', '\x1b[24~'),
          ]),
          const SizedBox(height: 6),
          SizedBox(
            height: 118,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: _complexInputController,
                    decoration: InputDecoration(
                      hintText: strings.multilineHint,
                      alignLabelWithHint: true,
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 10, vertical: 8),
                    ),
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    minLines: null,
                    maxLines: null,
                    expands: true,
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 44,
                  child: IconButton(
                    icon: const Icon(Icons.send, size: 20),
                    tooltip: strings.send,
                    onPressed: _sendComplexInput,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _keyGroup(BuildContext context, List<_KeySpec> keys) {
    final shortcuts = context.watch<ShortcutCommandService>();
    final commands = shortcuts.sortByUsage(
      keys
          .map(
            (key) =>
                ShortcutCommand(id: key.id, label: key.label, code: key.code),
          )
          .toList(),
    );

    return SizedBox(
      height: 34,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: commands.length,
        separatorBuilder: (_, __) => const SizedBox(width: 4),
        itemBuilder: (context, index) {
          return _quickKey(context, commands[index]);
        },
      ),
    );
  }

  Widget _quickKey(BuildContext context, ShortcutCommand command) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final normalBackground =
        isDark ? const Color(0xFF21262D) : const Color(0xFFF6F8FA);
    final normalBorder =
        isDark ? const Color(0xFF30363D) : const Color(0xFFD0D7DE);
    final customBackground = Theme.of(context)
        .colorScheme
        .primary
        .withValues(alpha: isDark ? 0.32 : 0.12);
    final customBorder = Theme.of(context).colorScheme.primary;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onLongPress: command.custom
            ? () => _confirmRemoveShortcut(context, command)
            : null,
        child: ActionChip(
          label: Text(
            command.label,
            style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
          ),
          backgroundColor: command.custom ? customBackground : normalBackground,
          side: BorderSide(
            color: command.custom ? customBorder : normalBorder,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          onPressed: () {
            context.read<ShortcutCommandService>().recordUse(command.id);
            context.read<SshService>().sendData(widget.sessionId, command.code);
            _terminalFocusNode.requestFocus();
          },
        ),
      ),
    );
  }

  Widget _fontSizeButton(IconData icon, String tooltip, double delta) {
    return SizedBox(
      width: 28,
      height: 28,
      child: IconButton(
        icon: Icon(icon, size: 18),
        tooltip: tooltip,
        padding: EdgeInsets.zero,
        visualDensity: VisualDensity.compact,
        onPressed: () {
          _setTerminalFontSize(_terminalFontSize + delta);
          _syncTerminalSize();
        },
      ),
    );
  }

  Future<void> _showAddShortcutDialog(
    BuildContext context,
    TerminalStrings strings,
  ) async {
    var label = '';
    var command = '';

    final result = await showDialog<(String, String)>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.addShortcut),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              decoration: InputDecoration(
                labelText: strings.label,
                hintText: 'e.g. LS',
              ),
              textInputAction: TextInputAction.next,
              onChanged: (value) => label = value,
            ),
            const SizedBox(height: 12),
            TextField(
              decoration: InputDecoration(
                labelText: strings.command,
                hintText: 'e.g. ls -la',
                alignLabelWithHint: true,
              ),
              keyboardType: TextInputType.multiline,
              minLines: 2,
              maxLines: 4,
              onChanged: (value) => command = value,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(
                ctx,
                (label, command),
              );
            },
            child: Text(strings.add),
          ),
        ],
      ),
    );

    if (result == null || !context.mounted) return;

    await context
        .read<ShortcutCommandService>()
        .addCustomCommand(result.$1, result.$2);
  }

  Future<void> _confirmRemoveShortcut(
    BuildContext context,
    ShortcutCommand command,
  ) async {
    final strings = _strings(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(strings.removeShortcut),
        content: Text(strings.removeShortcutContent(command.label)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(strings.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: Text(strings.remove),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;
    await context
        .read<ShortcutCommandService>()
        .removeCustomCommand(command.id);
  }

  void _setTerminalFontSize(double size) {
    final nextSize = size.clamp(_minTerminalFontSize, _maxTerminalFontSize);
    if ((nextSize - _terminalFontSize).abs() < 0.05) return;
    setState(() => _terminalFontSize = nextSize);
    context.read<SshService>().setSessionFontSize(widget.sessionId, nextSize);
  }

  void _sendComplexInput() {
    final rawText = _complexInputController.text;
    if (rawText.isEmpty) return;

    context.read<SshService>().sendData(widget.sessionId, rawText);
    _complexInputController.clear();
    _terminalFocusNode.requestFocus();
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
        builder: (_) => _TerminalCopyScreen(
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
                Navigator.of(context).pushReplacement(
                  _animatedTerminalRoute(nextSession),
                );
              } else {
                Navigator.pop(context);
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

class _KeySpec {
  final String id;
  final String label;
  final String code;

  const _KeySpec(this.label, this.code) : id = 'adv_$label';
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

class _TerminalCopyScreen extends StatelessWidget {
  final String title;
  final String text;
  final String copyAllTooltip;

  const _TerminalCopyScreen({
    required this.title,
    required this.text,
    required this.copyAllTooltip,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          IconButton(
            icon: const Icon(Icons.copy_all),
            tooltip: copyAllTooltip,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: text));
              Navigator.pop(context);
            },
          ),
        ],
      ),
      body: SafeArea(
        child: SelectionArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectableText(
              text,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 13,
                height: 1.35,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
