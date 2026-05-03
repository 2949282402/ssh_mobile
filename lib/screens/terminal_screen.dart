import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';

class TerminalScreen extends StatefulWidget {
  final String connectionId;

  const TerminalScreen({super.key, required this.connectionId});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  late final Terminal _terminal;
  late final TerminalController _terminalController;
  late final FocusNode _terminalFocusNode;
  VoidCallback? _sshListener;
  StreamSubscription<String>? _outputSubscription;
  SshSession? _subscribedSession;
  bool _reconnectInProgress = false;

  String? _serverName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _terminal = Terminal(
      maxLines: 10000,
      onOutput: (data) {
        if (!mounted) return;
        context.read<SshService>().sendData(data);
      },
    );
    _terminalController = TerminalController();
    _terminalFocusNode = FocusNode();

    _loadServerInfo();
    _installSshListener();
    unawaited(_ensureConnectedAndAttach());
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
      if (ssh.isConnected && ssh.activeConnectionId == widget.connectionId) {
        _setupOutputStream(ssh);
      } else if (ssh.state == SshConnectionState.disconnected ||
          ssh.state == SshConnectionState.error) {
        _showDisconnected(ssh.errorMessage);
      }
    };

    ssh.addListener(_sshListener!);
  }

  Future<void> _ensureConnectedAndAttach({bool fromResume = false}) async {
    if (_reconnectInProgress) return;
    _reconnectInProgress = true;

    final ssh = context.read<SshService>();
    if (fromResume) {
      _terminal.write('\r\n\x1b[33m[Checking SSH connection...]\x1b[0m\r\n');
    }

    final connected = await ssh.ensureConnected(widget.connectionId);
    if (!mounted) return;

    if (connected) {
      _setupOutputStream(ssh);
      if (fromResume) {
        _terminal.write('\r\n\x1b[32m[SSH connection ready]\x1b[0m\r\n');
      }
    } else {
      _showDisconnected(ssh.errorMessage);
    }

    _reconnectInProgress = false;
  }

  void _setupOutputStream(SshService ssh) {
    final session = ssh.currentSession;
    if (session == null) return;
    if (identical(_subscribedSession, session)) return;

    _outputSubscription?.cancel();
    _subscribedSession = session;

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
    _terminal.write(
      '\r\n\x1b[31m[Disconnected: ${reason ?? "unknown"}]\x1b[0m\r\n',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(_ensureConnectedAndAttach(fromResume: true));
    }
  }

  @override
  Widget build(BuildContext context) {
    final ssh = context.watch<SshService>();
    final isConnected =
        ssh.activeConnectionId == widget.connectionId && ssh.isConnected;

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _serverName ?? 'SSH Terminal',
              style: const TextStyle(fontSize: 14),
            ),
            Text(
              isConnected ? 'Connected' : 'Disconnected',
              style: TextStyle(
                fontSize: 11,
                color: isConnected ? AppTheme.terminalGreen : Colors.redAccent,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.aspect_ratio, size: 20),
            tooltip: 'Resize terminal',
            onPressed: () => _showResizeDialog(context),
          ),
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            tooltip: 'Disconnect',
            onPressed: () => _confirmDisconnect(context),
          ),
        ],
      ),
      body: Container(
        color: AppTheme.terminalBg,
        child: Column(
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: TerminalView(
                  _terminal,
                  controller: _terminalController,
                  focusNode: _terminalFocusNode,
                  autofocus: true,
                  backgroundOpacity: 1,
                  theme: TerminalTheme(
                    background: AppTheme.terminalBg,
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
                  ),
                ),
              ),
            ),
            Container(
              color: const Color(0xFF161B22),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  Expanded(child: _buildShortcutBar(context)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildShortcutBar(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _quickKey(context, 'TAB', '\t'),
          _quickKey(context, 'ESC', '\x1b'),
          _quickKey(context, 'UP', '\x1b[A'),
          _quickKey(context, 'DOWN', '\x1b[B'),
          _quickKey(context, 'LEFT', '\x1b[D'),
          _quickKey(context, 'RIGHT', '\x1b[C'),
          _quickKey(context, 'CTRL+C', '\x03'),
          _quickKey(context, 'CTRL+D', '\x04'),
          _quickKey(context, 'CTRL+L', '\x0c'),
        ],
      ),
    );
  }

  Widget _quickKey(BuildContext context, String label, String code) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: ActionChip(
        label: Text(
          label,
          style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
        ),
        backgroundColor: const Color(0xFF21262D),
        side: const BorderSide(color: Color(0xFF30363D)),
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onPressed: () {
          context.read<SshService>().sendData(code);
          _terminalFocusNode.requestFocus();
        },
      ),
    );
  }

  void _showResizeDialog(BuildContext context) {
    final widthController = TextEditingController(
      text: _terminal.viewWidth.toString(),
    );
    final heightController = TextEditingController(
      text: _terminal.viewHeight.toString(),
    );

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Resize terminal'),
        content: Row(
          children: [
            Expanded(
              child: TextField(
                controller: widthController,
                decoration: const InputDecoration(labelText: 'Columns'),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 8),
            const Text('x', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: heightController,
                decoration: const InputDecoration(labelText: 'Rows'),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final w = int.tryParse(widthController.text);
              final h = int.tryParse(heightController.text);
              if (w != null && h != null && w > 0 && h > 0) {
                _terminal.resize(w, h);
                context.read<SshService>().resizeTerminal(w, h);
              }
              Navigator.pop(ctx);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }

  void _confirmDisconnect(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Disconnect'),
        content: const Text('Disconnect the current SSH session?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              context.read<SshService>().disconnect();
              Navigator.pop(ctx);
              Navigator.pop(context);
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final listener = _sshListener;
    if (listener != null) {
      context.read<SshService>().removeListener(listener);
    }
    _outputSubscription?.cancel();
    _terminalController.dispose();
    _terminalFocusNode.dispose();
    super.dispose();
  }
}
