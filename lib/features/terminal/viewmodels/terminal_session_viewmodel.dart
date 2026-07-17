import 'dart:async';
import 'dart:collection';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';
import 'package:ssh_mobile/features/terminal/models/terminal_keyboard_models.dart';
import '../../../services/ssh_service.dart';

class TerminalSessionViewModel extends ChangeNotifier {
  final SshService _sshService;
  final String sessionId;
  final String connectionId;

  // Local interaction states
  bool _ctrlActive = false;
  bool _altActive = false;
  double _fontSize = 13.0;
  final List<String> _commandInputHistory = <String>[];
  int? _commandInputHistoryIndex;
  String _commandInputHistoryDraft = '';

  // Terminal instances
  late final Terminal terminal;
  late final TerminalController terminalController;
  late final FocusNode terminalFocusNode;
  late final FocusNode commandInputFocusNode;
  late final TextEditingController complexInputController;
  late final TextEditingController commandInputController;

  // Connection process states
  bool _reconnectInProgress = false;
  bool _loadingBufferedOutput = false;
  bool _loadedBufferedOutput = false;
  bool _hasShownDisconnectMessage = false;

  // Stream & Timer handling
  StreamSubscription<String>? _outputSubscription;
  SshSession? _subscribedSession;
  final ListQueue<String> _pendingTerminalWrites = ListQueue<String>();
  int _pendingTerminalWriteChars = 0;
  bool _terminalWriteScheduled = false;
  DateTime _lastFlushTime = DateTime.fromMillisecondsSinceEpoch(0);
  Timer? _throttleTimer;

  static const double _minTerminalFontSize = SshSession.minTerminalFontSize;
  static const double _maxTerminalFontSize = SshSession.maxTerminalFontSize;
  static const int _baseTerminalFlushChars = 12000;
  static const int _highTerminalFlushChars = 40000;
  static const int _terminalScrollbackLines = 4000;
  static const int _commandInputHistoryLimit = 100;

  TerminalSessionViewModel({
    required this._sshService,
    required this.sessionId,
    required this.connectionId,
  }) {
    _sshService.addListener(_onSshServiceChanged);

    final initialFontSize =
        _sshService.getSession(sessionId)?.fontSize ??
        SshSession.defaultTerminalFontSize;
    _fontSize = initialFontSize;

    terminal = Terminal(
      maxLines: _terminalScrollbackLines,
      onOutput: _handleTerminalInput,
    );
    terminalController = TerminalController();
    terminalFocusNode = FocusNode();
    commandInputFocusNode = FocusNode(
      debugLabel: 'Windows terminal command input',
    );
    complexInputController = TextEditingController();
    commandInputController = TextEditingController();

    _attachExistingSession();
  }

  @override
  void dispose() {
    _sshService.removeListener(_onSshServiceChanged);
    _outputSubscription?.cancel();
    _throttleTimer?.cancel();
    _pendingTerminalWrites.clear();
    terminalController.dispose();
    terminalFocusNode.dispose();
    commandInputFocusNode.dispose();
    complexInputController.dispose();
    commandInputController.dispose();
    super.dispose();
  }

  void _onSshServiceChanged() {
    final session = _sshService.getSession(sessionId);
    if (session?.isConnected == true) {
      _setupOutputStream();
    } else if (session?.state == SshConnectionState.disconnected ||
        session?.state == SshConnectionState.error) {
      _showDisconnected(session?.errorMessage);
    }
    notifyListeners();
  }

  // Getters
  bool get ctrlActive => _ctrlActive;
  bool get altActive => _altActive;
  double get fontSize => _fontSize;
  bool get reconnectInProgress => _reconnectInProgress;
  bool get loadingBufferedOutput => _loadingBufferedOutput;

  SshSession? get session => _sshService.getSession(sessionId);
  bool get isConnected => session?.isConnected ?? false;
  SshConnectionState get connectionState =>
      session?.state ?? SshConnectionState.disconnected;
  String? get connectionError =>
      session?.errorMessage ?? _sshService.errorMessage;
  String? get displayName => session?.displayName;

  bool get isWindowsTarget =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.windows;

  void toggleCtrl() {
    _ctrlActive = !_ctrlActive;
    notifyListeners();
  }

  void toggleAlt() {
    _altActive = !_altActive;
    notifyListeners();
  }

  void setCtrlActive(bool active) {
    if (_ctrlActive == active) return;
    _ctrlActive = active;
    notifyListeners();
  }

  void setAltActive(bool active) {
    if (_altActive == active) return;
    _altActive = active;
    notifyListeners();
  }

  void setFontSize(double size) {
    final nextSize = size.clamp(_minTerminalFontSize, _maxTerminalFontSize);
    if ((nextSize - _fontSize).abs() < 0.05) return;
    _fontSize = nextSize;
    _sshService.setSessionFontSize(sessionId, nextSize);
    notifyListeners();
  }

  void changeFontSize(double delta) {
    setFontSize(_fontSize + delta);
  }

  void sendData(String data) {
    _sshService.sendData(sessionId, data);
  }

  bool sendTerminalKeyboardStroke(TerminalKeyboardStroke stroke) {
    if (_ctrlActive) setCtrlActive(false);
    if (_altActive) setAltActive(false);

    final key = stroke.key;
    if (key != null) {
      return terminal.keyInput(
        key,
        ctrl: stroke.ctrl,
        alt: stroke.alt,
        shift: stroke.shift,
      );
    }

    final text = stroke.text;
    if (text == null || text.isEmpty) return false;
    var output = text;
    if (stroke.ctrl && text.length == 1) {
      final code = text.codeUnitAt(0);
      if (code == 32) {
        output = '\x00';
      } else if (code >= 64 && code <= 95) {
        output = String.fromCharCode(code - 64);
      } else if (code >= 96 && code <= 127) {
        output = String.fromCharCode(code - 96);
      }
    }
    if (stroke.alt) output = '\x1b$output';
    terminal.textInput(output);
    return true;
  }

  bool submitCommandInput() {
    final text = commandInputController.text;
    if (text.isEmpty) {
      return terminal.keyInput(TerminalKey.enter);
    }

    final submitted = submitCommandText(text);
    if (submitted) {
      commandInputController.clear();
    }
    return submitted;
  }

  bool submitCommandText(String text) {
    if (text.isEmpty) return false;

    final normalizedText = text.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    terminal.paste(normalizedText);
    terminal.keyInput(TerminalKey.enter);
    _rememberCommandInput(normalizedText);
    resetCommandInputHistoryNavigation();
    return true;
  }

  void insertCommandInputText(String text) {
    if (text.isEmpty) return;

    final value = commandInputController.value;
    final selection = value.selection.isValid
        ? value.selection
        : TextSelection.collapsed(offset: value.text.length);
    final nextText = value.text.replaceRange(
      selection.start,
      selection.end,
      text,
    );
    final nextOffset = selection.start + text.length;
    commandInputController.value = TextEditingValue(
      text: nextText,
      selection: TextSelection.collapsed(offset: nextOffset),
    );
    resetCommandInputHistoryNavigation();
  }

  Future<bool> pasteClipboardIntoCommandInput() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return false;
    insertCommandInputText(text);
    return true;
  }

  void clearCommandInput() {
    commandInputController.clear();
    resetCommandInputHistoryNavigation();
  }

  void resetCommandInputHistoryNavigation() {
    _commandInputHistoryIndex = null;
    _commandInputHistoryDraft = '';
  }

  bool showPreviousCommandInput() {
    if (_commandInputHistory.isEmpty) return false;

    final currentIndex = _commandInputHistoryIndex;
    if (currentIndex == null) {
      _commandInputHistoryDraft = commandInputController.text;
      _commandInputHistoryIndex = _commandInputHistory.length - 1;
    } else if (currentIndex > 0) {
      _commandInputHistoryIndex = currentIndex - 1;
    }
    _showCommandInputHistoryValue(
      _commandInputHistory[_commandInputHistoryIndex!],
    );
    return true;
  }

  bool showNextCommandInput() {
    final currentIndex = _commandInputHistoryIndex;
    if (currentIndex == null) return false;

    if (currentIndex < _commandInputHistory.length - 1) {
      _commandInputHistoryIndex = currentIndex + 1;
      _showCommandInputHistoryValue(
        _commandInputHistory[_commandInputHistoryIndex!],
      );
    } else {
      _commandInputHistoryIndex = null;
      _showCommandInputHistoryValue(_commandInputHistoryDraft);
      _commandInputHistoryDraft = '';
    }
    return true;
  }

  void _rememberCommandInput(String text) {
    if (_commandInputHistory.isNotEmpty && _commandInputHistory.last == text) {
      return;
    }
    _commandInputHistory.add(text);
    if (_commandInputHistory.length > _commandInputHistoryLimit) {
      _commandInputHistory.removeAt(0);
    }
  }

  void _showCommandInputHistoryValue(String text) {
    commandInputController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  void syncTerminalSize(int width, int height) {
    if (width > 0 && height > 0) {
      _sshService.resizeTerminal(sessionId, width, height);
    }
  }

  Future<void> reconnect() async {
    if (_reconnectInProgress) return;
    _reconnectInProgress = true;
    notifyListeners();

    final connected = await _sshService.ensureSessionConnected(
      sessionId,
      connectionId,
    );

    if (connected) {
      _setupOutputStream();
      _hasShownDisconnectMessage = false;
    } else {
      _showDisconnected(_sshService.errorMessage);
    }

    _reconnectInProgress = false;
    notifyListeners();
  }

  void _handleTerminalInput(String data) {
    if (ctrlActive) {
      setCtrlActive(false);
      if (data.length == 1) {
        final charCode = data.codeUnitAt(0);
        if ((charCode >= 97 && charCode <= 122) ||
            (charCode >= 65 && charCode <= 90)) {
          final ctrlCode = charCode >= 97 ? charCode - 96 : charCode - 64;
          _sshService.sendData(sessionId, String.fromCharCode(ctrlCode));
          return;
        }
      }
      _sshService.sendData(sessionId, data);
      return;
    }
    if (altActive) {
      setAltActive(false);
      if (data.length == 1) {
        _sshService.sendData(sessionId, '\x1b$data');
        return;
      }
      _sshService.sendData(sessionId, data);
      return;
    }
    _sshService.sendData(sessionId, data);
  }

  void _attachExistingSession() {
    final s = session;
    if (s?.isConnected == true) {
      _setupOutputStream();
      _hasShownDisconnectMessage = false;
    } else if (s != null) {
      _setupOutputStream();
      if (s.state == SshConnectionState.disconnected ||
          s.state == SshConnectionState.error) {
        _showDisconnected(s.errorMessage);
      }
    }
  }

  Future<void> _setupOutputStream() async {
    final s = session;
    if (s == null) return;
    if (identical(_subscribedSession, s)) return;

    _outputSubscription?.cancel();
    _subscribedSession = s;
    final pendingOutput = StringBuffer();
    var queueLiveOutput = !_loadedBufferedOutput;

    _outputSubscription = s.output.listen(
      (data) {
        if (queueLiveOutput) {
          pendingOutput.write(data);
          return;
        }
        _queueTerminalWrite(data);
      },
      onError: (error) {
        _queueTerminalWrite('\r\n\x1b[31m[Error: $error]\x1b[0m\r\n');
      },
      onDone: () {
        _queueTerminalWrite('\r\n\x1b[33m[Connection closed]\x1b[0m\r\n');
      },
    );

    if (!_loadedBufferedOutput && !_loadingBufferedOutput) {
      _loadingBufferedOutput = true;
      notifyListeners();
      try {
        final bufferedOutput = s.outputText;
        final initialOutput = bufferedOutput.isNotEmpty
            ? bufferedOutput
            : await _sshService.loadSessionHistoryText(s.id);

        if (!identical(_subscribedSession, s)) return;

        if (initialOutput.isNotEmpty) {
          _queueTerminalWrite(initialOutput);
        }

        final pending = pendingOutput.toString();
        if (pending.isNotEmpty && !initialOutput.endsWith(pending)) {
          _queueTerminalWrite(pending);
        }

        _loadedBufferedOutput = true;
      } finally {
        if (identical(_subscribedSession, s)) {
          _loadingBufferedOutput = false;
          notifyListeners();
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
    if (data.isEmpty) return;
    _pendingTerminalWrites.add(data);
    _pendingTerminalWriteChars += data.length;

    while (_pendingTerminalWriteChars > 200000 &&
        _pendingTerminalWrites.length > 1) {
      final removed = _pendingTerminalWrites.removeFirst();
      _pendingTerminalWriteChars -= removed.length;
    }

    if (_terminalWriteScheduled) return;

    final now = DateTime.now();
    final elapsed = now.difference(_lastFlushTime).inMilliseconds;
    final isHighFrequency = elapsed < 50 || _pendingTerminalWriteChars > 2000;

    _terminalWriteScheduled = true;
    if (isHighFrequency) {
      _throttleTimer = Timer(const Duration(milliseconds: 25), () {
        _throttleTimer = null;
        _flushTerminalWrites();
      });
    } else {
      WidgetsBinding.instance.scheduleFrameCallback((_) {
        _flushTerminalWrites();
      });
    }
  }

  void _flushTerminalWrites() {
    _throttleTimer?.cancel();
    _throttleTimer = null;

    _terminalWriteScheduled = false;
    _lastFlushTime = DateTime.now();
    if (_pendingTerminalWrites.isEmpty) return;

    _clearTerminalSelection();
    final buffer = StringBuffer();
    var written = 0;
    final flushLimit = _pendingTerminalWriteChars > 15000
        ? _highTerminalFlushChars
        : _baseTerminalFlushChars;

    while (_pendingTerminalWrites.isNotEmpty && written < flushLimit) {
      final chunk = _pendingTerminalWrites.removeFirst();
      final remainingBudget = flushLimit - written;
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
        terminal.write(text);
      } catch (_) {}
    }

    if (_pendingTerminalWrites.isNotEmpty || _pendingTerminalWriteChars > 0) {
      _terminalWriteScheduled = true;
      _throttleTimer = Timer(const Duration(milliseconds: 25), () {
        _throttleTimer = null;
        _flushTerminalWrites();
      });
    }
  }

  void _clearTerminalSelection() {
    try {
      if (terminalController.selection == null) return;
      terminalController.clearSelection();
    } catch (_) {}
  }

  void selectWordAtPosition(
    Offset globalPos,
    GlobalKey<TerminalViewState> viewKey,
  ) {
    final terminalView = viewKey.currentState;
    if (terminalView == null) return;

    try {
      final renderTerminal = terminalView.renderTerminal;
      final localToTerminal = renderTerminal.globalToLocal(globalPos);
      final offset = renderTerminal.getCellOffset(localToTerminal);
      final boundary = terminal.buffer.getWordBoundary(offset);

      if (boundary == null) {
        _clearTerminalSelection();
        return;
      }

      terminalController.setSelection(
        terminal.buffer.createAnchorFromOffset(boundary.begin),
        terminal.buffer.createAnchorFromOffset(boundary.end),
      );
    } catch (_) {
      _clearTerminalSelection();
    }
  }

  void selectAllText() {
    try {
      terminalController.setSelection(
        terminal.buffer.createAnchor(
          0,
          terminal.buffer.height - terminal.viewHeight,
        ),
        terminal.buffer.createAnchor(
          terminal.viewWidth,
          terminal.buffer.height - 1,
        ),
      );
    } catch (_) {
      _clearTerminalSelection();
    }
  }

  void clearSelection() {
    _clearTerminalSelection();
  }

  String getSelectedText() {
    try {
      final selection = terminalController.selection;
      if (selection == null) return '';
      return terminal.buffer.getText(selection);
    } catch (_) {
      _clearTerminalSelection();
      return '';
    }
  }

  Future<void> copySelectedText() async {
    final text = getSelectedText();
    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  Future<void> pasteClipboardText() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      sendData(text);
    }
  }
}
