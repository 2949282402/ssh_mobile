import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:xterm/xterm.dart';
import 'package:animations/animations.dart';

import '../features/terminal/viewmodels/terminal_session_viewmodel.dart';
import '../services/app_settings.dart';
import '../services/ssh_service.dart';
import '../services/storage_service.dart';
import '../theme/app_theme.dart';
import '../utils/responsive.dart';
import '../widgets/connection_progress_dialog.dart';
import '../widgets/overflow_scroll_text.dart';
import '../widgets/ssh_host_key_trust_dialog.dart';
import '../widgets/window_name_dialog.dart';
import 'terminal/terminal_app_bar.dart';
import 'terminal/terminal_copy_screen.dart';
import 'terminal/terminal_shortcut_panel.dart';
import 'terminal/terminal_view_area.dart';

part 'terminal/terminal_settings_models.dart';
part 'terminal/terminal_windows_input.dart';
part 'terminal/terminal_dialogs.dart';

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

  final GlobalKey<TerminalViewState> _terminalViewKey =
      GlobalKey<TerminalViewState>();
  Offset _lastLongPressPosition = Offset.zero;
  Timer? _longPressTimer;
  Timer? _resizeTimer;
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
    _loadServerInfo();
  }

  void _loadServerInfo() {
    final storage = context.read<StorageService>();
    final config = storage.getConnection(widget.connectionId);
    if (config != null) {
      setState(() => _serverName = config.name);
    }
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
      transitionDuration: const Duration(milliseconds: 300),
      reverseTransitionDuration: const Duration(milliseconds: 200),
      pageBuilder: (context, animation, secondaryAnimation) =>
          SharedAxisTransition(
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
    // App cycle resumed handled by session init/attaching, no additional action needed here
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider<TerminalSessionViewModel>(
      create: (context) => TerminalSessionViewModel(
        sshService: context.read<SshService>(),
        sessionId: widget.sessionId,
        connectionId: widget.connectionId,
      ),
      child: Consumer<TerminalSessionViewModel>(
        builder: (context, viewModel, child) {
          final ctrlActive = viewModel.ctrlActive;
          final altActive = viewModel.altActive;
          final terminalFontSize = viewModel.fontSize;

          final appSettings =
              context.select<AppSettings, _TerminalSettingsSnapshot>(
            _TerminalSettingsSnapshot.from,
          );
          final strings = TerminalStrings(appSettings.language);
          final isConnected = viewModel.isConnected;
          final isDark = Theme.of(context).brightness == Brightness.dark;
          final terminalBackground =
              isDark ? AppTheme.terminalBg : const Color(0xFFFAFBFC);
          final toolbarColor = isDark
              ? const Color(0xFF161B22)
              : Theme.of(context).colorScheme.surface;
          final useWideDesktopSideShortcutPanel =
              !_useWindowsBottomShortcutPanel &&
                  MediaQuery.sizeOf(context).width >=
                      AppBreakpoints.wideDesktop;

          final terminalView = TerminalViewArea(
            terminalViewKey: _terminalViewKey,
            terminal: viewModel.terminal,
            controller: viewModel.terminalController,
            focusNode: viewModel.terminalFocusNode,
            theme: _terminalTheme(isDark, terminalBackground),
            fontSize: terminalFontSize,
            minFontSize: _minTerminalFontSize,
            maxFontSize: _maxTerminalFontSize,
            onFontSizeChanged: (size) => viewModel.setFontSize(size),
            onScaleEnd: () => _syncTerminalSize(viewModel),
            onPointerDown: (event) =>
                _handleTerminalPointerDown(event, viewModel),
            onPointerMove: _handleTerminalPointerMove,
            onPointerUp: _handleTerminalPointerUp,
            onPointerCancel: _handleTerminalPointerCancel,
            useWindowsCommandInput: _isWindowsTerminalTarget,
            onSecondaryTapUp: (details) {
              _lastLongPressPosition = details.globalPosition;
              _requestWindowsAwareTerminalFocus(viewModel);
              unawaited(_showTerminalEditMenu(viewModel));
            },
          );

          final shortcutPanel = TerminalShortcutPanel(
            sessionId: widget.sessionId,
            strings: strings,
            toolbarColor: toolbarColor,
            advancedKeyboardVisible: _advancedKeyboardVisible,
            complexInputController: viewModel.complexInputController,
            terminalFocusNode: _isWindowsTerminalTarget
                ? viewModel.commandInputFocusNode
                : viewModel.terminalFocusNode,
            ctrlActive: ctrlActive,
            altActive: altActive,
            onToggleCtrl: () {
              viewModel.toggleCtrl();
              if (viewModel.ctrlActive) {
                viewModel.setAltActive(false);
              }
              _requestWindowsAwareTerminalFocus(viewModel);
            },
            onToggleAlt: () {
              viewModel.toggleAlt();
              if (viewModel.altActive) {
                viewModel.setCtrlActive(false);
              }
              _requestWindowsAwareTerminalFocus(viewModel);
            },
            onToggleAdvancedKeyboard: () {
              setState(
                () => _advancedKeyboardVisible = !_advancedKeyboardVisible,
              );
            },
          );

          return Scaffold(
            appBar: TerminalScreenAppBar(
              strings: strings,
              displayName: viewModel.displayName,
              serverName: _serverName,
              isConnected: isConnected,
              isDarkMode: appSettings.isDarkMode,
              reconnectInProgress: viewModel.reconnectInProgress,
              onReconnect: viewModel.reconnect,
              onToggleTheme: context.read<AppSettings>().toggleTheme,
              onSwitchWindow: () => _showSessionSwitcher(context),
              onCloseWindow: () => _confirmDisconnect(context),
              onOpenSiblingSession: () => _openSiblingSession(context),
              onSmallerFont: () {
                viewModel.setFontSize(terminalFontSize - 1);
                _syncTerminalSize(viewModel);
              },
              onLargerFont: () {
                viewModel.setFontSize(terminalFontSize + 1);
                _syncTerminalSize(viewModel);
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
                                viewModel,
                                toolbarColor,
                                strings,
                              ),
                            shortcutPanel,
                          ],
                        ),
                ),
                if (viewModel.loadingBufferedOutput)
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
        },
      ),
    );
  }

  void _syncTerminalSize(TerminalSessionViewModel viewModel) {
    _resizeTimer?.cancel();
    _resizeTimer = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      final width = viewModel.terminal.viewWidth;
      final height = viewModel.terminal.viewHeight;
      viewModel.syncTerminalSize(width, height);
      _requestWindowsAwareTerminalFocus(viewModel);
    });
  }

  void _handleTerminalPointerDown(
      PointerDownEvent event, TerminalSessionViewModel viewModel) {
    _activePointers += 1;
    _lastLongPressPosition = event.position;
    _requestWindowsAwareTerminalFocus(viewModel);

    _longPressTimer?.cancel();
    _longPressTimer = Timer(const Duration(milliseconds: 550), () {
      if (!mounted || _activePointers != 1 || _terminalMenuOpen) return;
      viewModel.selectWordAtPosition(_lastLongPressPosition, _terminalViewKey);
      unawaited(_showTerminalEditMenu(viewModel));
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

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _longPressTimer?.cancel();
    _resizeTimer?.cancel();
    super.dispose();
  }
}
