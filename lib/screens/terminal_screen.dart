import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';

import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../models/connection.dart';
import '../theme/app_theme.dart';

/// 终端界面 - SSH 会话交互
class TerminalScreen extends StatefulWidget {
  final String connectionId;

  const TerminalScreen({super.key, required this.connectionId});

  @override
  State<TerminalScreen> createState() => _TerminalScreenState();
}

class _TerminalScreenState extends State<TerminalScreen>
    with WidgetsBindingObserver {
  late Terminal _terminal;
  late TerminalController _terminalController;
  StreamSubscription<String>? _outputSubscription;

  String? _serverName;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 初始化终端模拟器
    _terminal = Terminal(
      maxLines: 10000,
    );
    _terminalController = TerminalController(terminal: _terminal);

    _loadServerInfo();
    _connectToSession();
  }

  void _loadServerInfo() {
    final storage = context.read<StorageService>();
    final config = storage.getConnection(widget.connectionId);
    if (config != null) {
      setState(() => _serverName = config.name);
    }
  }

  void _connectToSession() {
    final ssh = context.read<SshService>();

    // 如果还没有连接，先连接
    if (ssh.activeConnectionId != widget.connectionId) {
      ssh.connect(widget.connectionId).then((_) {
        if (ssh.isConnected) {
          _setupOutputStream(ssh);
        }
      });
    } else if (ssh.isConnected) {
      _setupOutputStream(ssh);
    }

    // 监听连接状态变化
    ssh.addListener(() {
      if (!mounted) return;
      if (ssh.isConnected &&
          ssh.activeConnectionId == widget.connectionId) {
        _setupOutputStream(ssh);
      } else if (ssh.state == SshConnectionState.disconnected ||
          ssh.state == SshConnectionState.error) {
        _showDisconnected(ssh.errorMessage);
      }
    });
  }

  void _setupOutputStream(SshService ssh) {
    _outputSubscription?.cancel();

    final session = ssh.currentSession;
    if (session == null) return;

    // 订阅 SSH 输出 → 终端
    _outputSubscription = session.output.listen(
      (data) {
        if (!mounted) return;
        _terminal.write(data);
      },
      onError: (error) {
        if (!mounted) return;
        _terminal.write('\r\n\x1b[31m[错误: $error]\x1b[0m\r\n');
      },
      onDone: () {
        if (!mounted) return;
        _terminal.write('\r\n\x1b[33m[连接已关闭]\x1b[0m\r\n');
      },
    );
  }

  void _showDisconnected(String? reason) {
    _terminal.write(
      '\r\n\x1b[31m[连接断开: ${reason ?? "未知原因"}]\x1b[0m\r\n',
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // 从后台恢复 → 检查连接
      final ssh = context.read<SshService>();
      if (!ssh.isConnected &&
          ssh.activeConnectionId == widget.connectionId) {
        // 连接已断，尝试重连
        _terminal.write('\r\n\x1b[33m[正在重新连接...]\x1b[0m\r\n');
        ssh.connect(widget.connectionId);
      }
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
              _serverName ?? 'SSH 终端',
              style: const TextStyle(fontSize: 14),
            ),
            Text(
              isConnected ? '● 已连接' : '● 未连接',
              style: TextStyle(
                fontSize: 11,
                color: isConnected
                    ? AppTheme.terminalGreen
                    : Colors.redAccent,
              ),
            ),
          ],
        ),
        actions: [
          // 终端大小
          IconButton(
            icon: const Icon(Icons.aspect_ratio, size: 20),
            tooltip: '调整终端大小',
            onPressed: () => _showResizeDialog(context),
          ),
          // 断开连接
          IconButton(
            icon: const Icon(Icons.power_settings_new),
            tooltip: '断开连接',
            onPressed: () => _confirmDisconnect(context),
          ),
        ],
      ),
      body: Container(
        color: AppTheme.terminalBg,
        child: Column(
          children: [
            // 终端视图
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: TerminalView(
                  _terminal,
                  controller: _terminalController,
                  backgroundOpacity: 1,
                  theme: TerminalTheme(
                    background: AppTheme.terminalBg,
                    foreground: const Color(0xFFCCCCCC),
                    cursor: AppTheme.terminalGreen,
                    cursorAccent: AppTheme.terminalBg,
                    selection: AppTheme.terminalGreen.withOpacity(0.3),
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
                  // 用户键盘输入 → SSH
                  onInput: (data) {
                    final sshService = context.read<SshService>();
                    sshService.sendData(data);
                  },
                ),
              ),
            ),
            // 底部快捷栏
            Container(
              color: const Color(0xFF161B22),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  _buildShortcutBar(context),
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
          _quickKey(context, '↑', '\x1b[A'),
          _quickKey(context, '↓', '\x1b[B'),
          _quickKey(context, '←', '\x1b[D'),
          _quickKey(context, '→', '\x1b[C'),
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
          // 让终端获焦
          _terminalController.focus();
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
        title: const Text('调整终端大小'),
        content: Row(
          children: [
            Expanded(
              child: TextField(
                controller: widthController,
                decoration: const InputDecoration(labelText: '列 (Width)'),
                keyboardType: TextInputType.number,
              ),
            ),
            const SizedBox(width: 8),
            const Text('×', style: TextStyle(fontSize: 20)),
            const SizedBox(width: 8),
            Expanded(
              child: TextField(
                controller: heightController,
                decoration: const InputDecoration(labelText: '行 (Height)'),
                keyboardType: TextInputType.number,
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
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
            child: const Text('应用'),
          ),
        ],
      ),
    );
  }

  void _confirmDisconnect(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('断开连接'),
        content: const Text('确定断开当前 SSH 连接吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              context.read<SshService>().disconnect();
              Navigator.pop(ctx);
              Navigator.pop(context); // 返回列表
            },
            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
            child: const Text('断开'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _outputSubscription?.cancel();
    _terminalController.dispose();
    super.dispose();
  }
}
