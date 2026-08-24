part of 'ai_tool_service.dart';

extension _SecurityPolicy on AiToolService {
  String? _secretPathBlocked(String path) {
    final reason = secretPolicy.suspiciousPathReason(path);
    if (reason == null) return null;
    AppLogService.instance.warning(
      'AI tool blocked by secret path policy',
      details: 'blocked by tool secret policy',
    );
    return jsonEncode({
      'error': reason,
      'path': path,
      'blockedBy': 'tool_secret_policy',
    });
  }

  AiCommandReview _reviewLinuxCommand(String normalized) {
    final powerBlockReason = _systemPowerCommandBlockReason(normalized);
    if (powerBlockReason != null) {
      return AiCommandReview.blocked(powerBlockReason);
    }
    if (_looksLikeWindowsShellCommand(normalized)) {
      return const AiCommandReview.blocked(
        'Windows command was requested for a Linux server. Use POSIX or Linux commands for this server.',
      );
    }
    if (_hasShellControlSyntax(normalized)) {
      return const AiCommandReview.requiresApproval(
        'Shell chaining, substitution, or redirection requires user approval.',
      );
    }
    if (_matchesCommandInvocation(normalized, 'cmd /c type')) {
      return const AiCommandReview.requiresApproval(
        'Reading remote file contents requires user approval.',
      );
    }
    final readReview = _sensitiveReadCommandReview(normalized);
    if (readReview != null) return readReview;
    const allowedCommands = [
      'cat',
      'command -v',
      'df',
      'du',
      'free',
      'grep',
      'head',
      'journalctl',
      'ls',
      'netstat',
      'ps',
      'pwd',
      'readlink',
      'realpath',
      'ss',
      'stat',
      'systemctl status',
      'tail',
      'top',
      'uname',
      'uptime',
      'whereis',
      'which',
      'whoami',
    ];
    if (!allowedCommands.any(
          (command) => _matchesCommandInvocation(normalized, command),
        ) &&
        !_isSafePowerShellDiagnostic(normalized)) {
      return const AiCommandReview.requiresApproval(
        'This command may change server state.',
      );
    }
    return const AiCommandReview.readOnly();
  }

  AiCommandReview _reviewWindowsCommand(String normalized) {
    final powerBlockReason = _systemPowerCommandBlockReason(normalized);
    if (powerBlockReason != null) {
      return AiCommandReview.blocked(powerBlockReason);
    }
    if (_looksLikeLinuxShellCommand(normalized)) {
      return const AiCommandReview.blocked(
        'Linux or POSIX command was requested for a Windows server. Use explicit cmd /c or PowerShell commands for this server.',
      );
    }
    const safeCmdCommands = [
      'cmd /c cd',
      'cmd /c dir',
      'cmd /c echo',
      'cmd /c hostname',
      'cmd /c ipconfig',
      'cmd /c netstat',
      'cmd /c systeminfo',
      'cmd /c tasklist',
      'cmd /c type',
      'cmd /c ver',
      'cmd /c whoami',
    ];
    if (_isSafePowerShellDiagnostic(normalized)) {
      return const AiCommandReview.readOnly();
    }
    if (_hasShellControlSyntax(normalized)) {
      return const AiCommandReview.requiresApproval(
        'Shell chaining, substitution, or redirection requires user approval.',
      );
    }
    if (_matchesCommandInvocation(normalized, 'cmd /c type')) {
      return const AiCommandReview.requiresApproval(
        'Reading remote file contents requires user approval.',
      );
    }
    final readReview = _sensitiveReadCommandReview(normalized);
    if (readReview != null) return readReview;
    if (safeCmdCommands.any(
      (command) => _matchesCommandInvocation(normalized, command),
    )) {
      return const AiCommandReview.readOnly();
    }
    if (normalized.startsWith('cmd /c ') ||
        normalized.startsWith('powershell ') ||
        normalized.startsWith('pwsh ')) {
      return const AiCommandReview.requiresApproval(
        'This Windows command may change server state.',
      );
    }
    return const AiCommandReview.blocked(
      'Windows server commands must be explicit: use cmd /c or powershell or pwsh so the tool can enforce Windows safety rules.',
    );
  }

  String? _deletionCommandBlockReason(String normalized) {
    final text = normalized
        .replaceAll(RegExp(r'''["'`]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ');
    if (text.contains(' remove-') || text.startsWith('remove-')) {
      return 'Delete or remove commands are blocked for AI tools.';
    }
    final deletePatterns = [
      RegExp(
        r'(^|[\s;&|()])(rm|unlink|rmdir|shred|trash-put)(\.exe)?([\s;&|()]|$)',
      ),
      RegExp(r'(^|[\s;&|()])(del|erase|rd)(\.exe)?([\s;&|()]|$)'),
      RegExp(r'(^|[\s;&|()])find([\s;&|()].*)\s-delete([\s;&|()]|$)'),
      RegExp(
        r'(^|[\s;&|()])(docker|podman|kubectl|git)\s+(rm|rmi|delete)([\s;&|()]|$)',
      ),
      RegExp(r'(^|[\s;&|()])(sc|reg|schtasks|netsh)\s+delete([\s;&|()]|$)'),
    ];
    if (deletePatterns.any((pattern) => pattern.hasMatch(text))) {
      return 'Delete or remove commands are blocked for AI tools.';
    }
    return null;
  }

  String? _systemPowerCommandBlockReason(String normalized) {
    final text = normalized
        .replaceAll(RegExp(r'''["'`]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    final powerPatterns = [
      RegExp(r'(^|[\s;&|()])systemctl\s+(reboot|poweroff|halt)([\s;&|()]|$)'),
      RegExp(r'(^|[\s;&|()])(reboot|shutdown|poweroff|halt)([\s;&|()]|$)'),
      RegExp(r'(^|[\s;&|()])shutdown\.exe([\s;&|()]|$)'),
      RegExp(r'(^|[\s;&|()])restart-computer([\s;&|()]|$)'),
      RegExp(r'(^|[\s;&|()])stop-computer([\s;&|()]|$)'),
    ];
    if (powerPatterns.any((pattern) => pattern.hasMatch(text))) {
      return 'System reboot, shutdown, poweroff, and halt commands are blocked for AI tools. Use the System Admin power UI, which requires triple confirmation.';
    }
    return null;
  }

  bool _looksLikeWindowsShellCommand(String normalized) {
    const prefixes = [
      'cmd ',
      'cmd.exe ',
      'powershell ',
      'powershell.exe ',
      'pwsh ',
      'pwsh.exe ',
      'wmic ',
      'tasklist',
      'systeminfo',
      'ipconfig',
    ];
    return prefixes.any(normalized.startsWith);
  }

  bool _looksLikeLinuxShellCommand(String normalized) {
    const prefixes = [
      './',
      '/',
      'awk ',
      'bash ',
      'cat ',
      'command -v ',
      'df ',
      'du ',
      'free',
      'grep ',
      'head ',
      'journalctl ',
      'ls',
      'ps ',
      'pwd',
      'readlink ',
      'realpath ',
      'sed ',
      'sh ',
      'ss ',
      'stat ',
      'systemctl ',
      'tail ',
      'top ',
      'uname',
      'uptime',
      'whereis ',
      'which ',
      'whoami',
      'zsh ',
    ];
    return prefixes.any(normalized.startsWith);
  }

  bool _hasShellControlSyntax(String normalized) {
    if (normalized.contains(r'$(') || normalized.contains('`')) return true;
    for (final codeUnit in normalized.codeUnits) {
      if (codeUnit == 0x3b || // ;
          codeUnit == 0x26 || // &
          codeUnit == 0x7c || // |
          codeUnit == 0x3c || // <
          codeUnit == 0x3e || // >
          codeUnit == 0x0a || // LF
          codeUnit == 0x0d || // CR
          (codeUnit < 0x20 && codeUnit != 0x09) ||
          codeUnit == 0x7f) {
        return true;
      }
    }
    return false;
  }

  AiCommandReview? _sensitiveReadCommandReview(String normalized) {
    final text = normalized
        .replaceAll(RegExp(r'''["'`]'''), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (text.startsWith('journalctl') || text.contains(' journalctl ')) {
      return const AiCommandReview.requiresApproval(
        'Reading server logs requires user approval because logs may contain secrets.',
      );
    }
    if (text.contains('/var/log') || RegExp(r'\.log(\s|$)').hasMatch(text)) {
      return const AiCommandReview.requiresApproval(
        'Reading server log files requires user approval because logs may contain secrets.',
      );
    }

    final readCommands = [
      'cat',
      'grep',
      'head',
      'tail',
      'less',
      'more',
      'type',
      'get-content',
    ];
    final command = readCommands.firstWhere(
      (item) => text == item || text.startsWith('$item '),
      orElse: () => '',
    );
    if (command.isEmpty) return null;
    if (_isClearlySafeReadCommand(text)) return null;
    return const AiCommandReview.requiresApproval(
      'Reading remote file contents requires user approval unless the path is a known safe system status file.',
    );
  }

  bool _isClearlySafeReadCommand(String text) {
    const safeFiles = {
      '/etc/os-release',
      '/etc/issue',
      '/proc/cpuinfo',
      '/proc/meminfo',
      '/proc/loadavg',
      '/proc/uptime',
      '/proc/stat',
      '/proc/diskstats',
      '/proc/net/dev',
      '/proc/net/tcp',
      '/proc/net/udp',
    };
    const safeDirectories = {'/sys/class/net', '/sys/class/thermal'};
    final tokens = text
        .split(RegExp(r'\s+'))
        .where((token) => token.isNotEmpty)
        .toList(growable: false);
    if (tokens.isEmpty ||
        (tokens.first != 'cat' &&
            tokens.first != 'head' &&
            tokens.first != 'tail')) {
      return false;
    }

    final operands = <String>[];
    var expectsNumericOptionValue = false;
    for (final token in tokens.skip(1)) {
      if (expectsNumericOptionValue) {
        if (!RegExp(r'^\+?\d+$').hasMatch(token)) return false;
        expectsNumericOptionValue = false;
        continue;
      }
      if (tokens.first != 'cat' &&
          (token == '-n' ||
              token == '--lines' ||
              token == '-c' ||
              token == '--bytes')) {
        expectsNumericOptionValue = true;
        continue;
      }
      if (token.startsWith('-')) continue;
      operands.add(token);
    }
    if (expectsNumericOptionValue || operands.isEmpty) return false;

    return operands.every((path) {
      final segments = path.split('/');
      if (!path.startsWith('/') || segments.contains('..')) return false;
      if (safeFiles.contains(path)) return true;
      return safeDirectories.any(
        (directory) => path == directory || path.startsWith('$directory/'),
      );
    });
  }

  bool _isSafePowerShellDiagnostic(String normalized) {
    const launchers = ['powershell', 'powershell.exe', 'pwsh', 'pwsh.exe'];
    final launcher = launchers.firstWhere(
      (value) => _matchesCommandInvocation(normalized, value),
      orElse: () => '',
    );
    if (launcher.isEmpty || normalized.length == launcher.length) return false;
    var script = normalized.substring(launcher.length).trimLeft();
    const allowedLauncherFlags = {
      '-nologo',
      '-noprofile',
      '-noninteractive',
      '-sta',
      '-mta',
    };
    while (script.startsWith('-')) {
      final separator = script.indexOf(RegExp(r'[ \t]'));
      final option = separator < 0 ? script : script.substring(0, separator);
      if (option == '-encodedcommand' ||
          option == '-enc' ||
          option == '-file' ||
          option == '-f') {
        return false;
      }
      if (option == '-command' || option == '-c') {
        if (separator < 0) return false;
        script = script.substring(separator).trimLeft();
        break;
      }
      if (!allowedLauncherFlags.contains(option) || separator < 0) return false;
      script = script.substring(separator).trimLeft();
    }
    if ((script.startsWith('"') && script.endsWith('"')) ||
        (script.startsWith("'") && script.endsWith("'"))) {
      script = script.substring(1, script.length - 1).trim();
    }
    final hasUnsafeControl = script.codeUnits.any(
      (codeUnit) =>
          (codeUnit < 0x20 && codeUnit != 0x09) ||
          codeUnit == 0x7f ||
          codeUnit == 0x85 ||
          codeUnit == 0x2028 ||
          codeUnit == 0x2029,
    );
    if (script.isEmpty ||
        hasUnsafeControl ||
        script.contains(';') ||
        script.contains('&') ||
        script.contains('<') ||
        script.contains('>') ||
        script.contains('`') ||
        script.contains(r'$(') ||
        script.contains('{') ||
        script.contains('}') ||
        script.contains('(') ||
        script.contains(')') ||
        script.contains('\n') ||
        script.contains('\r') ||
        script.contains('||')) {
      return false;
    }

    const firstCmdlets = {
      'get-ciminstance',
      'get-computerinfo',
      'get-counter',
      'get-date',
      'get-dnsclientcache',
      'get-host',
      'get-hotfix',
      'get-location',
      'get-netadapter',
      'get-netipconfiguration',
      'get-netroute',
      'get-nettcpconnection',
      'get-netudpendpoint',
      'get-process',
      'get-psdrive',
      'get-service',
      'get-timezone',
      'get-wmiobject',
      'resolve-dnsname',
      'test-connection',
      'test-netconnection',
    };
    const pipelineCmdlets = {
      'convertto-json',
      'format-list',
      'format-table',
      'measure-object',
      'out-string',
      'select-object',
      'sort-object',
    };
    final segments = script.split('|').map((value) => value.trim()).toList();
    if (segments.isEmpty || segments.any((value) => value.isEmpty))
      return false;
    for (var index = 0; index < segments.length; index++) {
      final segment = segments[index];
      final separator = segment.indexOf(RegExp(r'[ \t]'));
      final command = separator < 0 ? segment : segment.substring(0, separator);
      if (index == 0) {
        final isVersionTable = RegExp(
          r'^\$psversiontable(?:\.[a-z0-9_]+)?$',
        ).hasMatch(command);
        if (!isVersionTable && !firstCmdlets.contains(command)) return false;
        if (!isVersionTable && segment.contains(r'$')) return false;
      } else if (!pipelineCmdlets.contains(command) || segment.contains(r'$')) {
        return false;
      }
    }
    return true;
  }

  bool _matchesCommandInvocation(String normalized, String command) {
    if (normalized == command) return true;
    if (!normalized.startsWith(command) ||
        normalized.length == command.length) {
      return false;
    }
    final separator = normalized.codeUnitAt(command.length);
    return separator == 0x20 || separator == 0x09;
  }

  String _truncate(String value) {
    final redacted = secretPolicy.redactText(value);
    if (redacted.length <= AiToolService._maxToolTextChars) return redacted;
    return '${redacted.substring(0, AiToolService._maxToolTextChars)}\n...[truncated]';
  }

  String _remoteFileName(String path) {
    final normalized = path.trim().replaceAll('\\', '/');
    final parts = normalized.split('/').where((part) => part.isNotEmpty);
    if (parts.isEmpty) return 'download.bin';
    return parts.last;
  }

  int get _sftpDownloadLimitBytes =>
      appSettings?.sftpDownloadLimitBytes ??
      AiSettingsDefaults.defaultSftpDownloadLimitBytes;

  int get _sftpTextEditLimitBytes =>
      appSettings?.sftpTextEditLimitBytes ??
      AiSettingsDefaults.defaultSftpTextEditLimitBytes;

  String _arg(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! String || value.trim().isEmpty) {
      throw StateError('Missing tool argument: $key');
    }
    return value.trim();
  }

  String? _optionalString(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  int _argInt(Map<String, dynamic> arguments, String key) {
    final value = _optionalInt(arguments, key);
    if (value == null) {
      throw StateError('Missing tool argument: $key');
    }
    return value;
  }

  int? _optionalInt(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  bool? _optionalBool(Map<String, dynamic> arguments, String key) {
    final value = arguments[key];
    if (value is bool) return value;
    if (value is String) {
      switch (value.trim().toLowerCase()) {
        case 'true':
        case 'yes':
        case '1':
          return true;
        case 'false':
        case 'no':
        case '0':
          return false;
      }
    }
    return null;
  }

  List<String> _stringList(Object? value) {
    if (value is! List) {
      throw StateError('Expected a string array.');
    }
    final items = value
        .whereType<Object?>()
        .map((item) => item?.toString().trim() ?? '')
        .where((item) => item.isNotEmpty)
        .toList(growable: false);
    if (items.isEmpty) {
      throw StateError('Expected a non-empty string array.');
    }
    return items;
  }

  List<String>? _optionalStringList(
    Map<String, dynamic> arguments,
    String key,
  ) {
    if (!arguments.containsKey(key)) return null;
    final value = arguments[key];
    if (value == null) return null;
    return _stringList(value);
  }

  List<int> _intList(Object? value) {
    if (value is! List) {
      throw StateError('Expected an integer array.');
    }
    final items = <int>[];
    for (final item in value) {
      if (item is num) {
        items.add(item.toInt());
      } else if (item is String) {
        final parsed = int.tryParse(item.trim());
        if (parsed != null) items.add(parsed);
      }
    }
    if (items.isEmpty) {
      throw StateError('Expected a non-empty integer array.');
    }
    return items;
  }
}
