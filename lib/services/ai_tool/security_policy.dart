part of '../ai_tool_service.dart';

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
    if (_hasCommandSeparator(normalized)) {
      return const AiCommandReview.requiresApproval(
        'Command chaining or piping requires user approval.',
      );
    }
    const allowedPrefixes = [
      'cat ',
      'command -v ',
      'df ',
      'du ',
      'free',
      'grep ',
      'head ',
      'journalctl ',
      'ls',
      'netstat ',
      'ps ',
      'pwd',
      'readlink ',
      'realpath ',
      'ss ',
      'stat ',
      'systemctl status ',
      'tail ',
      'top ',
      'uname',
      'uptime',
      'whereis ',
      'which ',
      'whoami',
    ];
    if (!allowedPrefixes.any(normalized.startsWith) &&
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
    if (_isSafePowerShellDiagnostic(normalized)) {
      return const AiCommandReview.readOnly();
    }
    const safeCmdPrefixes = [
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
    if (_hasCommandSeparator(normalized)) {
      return const AiCommandReview.requiresApproval(
        'Command chaining or piping requires user approval.',
      );
    }
    if (safeCmdPrefixes.any(normalized.startsWith)) {
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
      RegExp(
        r'(^|[\s;&|()])(sc|reg|schtasks|netsh)\s+delete([\s;&|()]|$)',
      ),
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

  bool _hasCommandSeparator(String normalized) {
    return normalized.contains(';') ||
        normalized.contains('|') ||
        normalized.contains('&&') ||
        normalized.contains('||') ||
        normalized.contains(' & ');
  }

  bool _isSafePowerShellDiagnostic(String normalized) {
    final isPowerShell =
        normalized.startsWith('powershell ') || normalized.startsWith('pwsh ');
    if (!isPowerShell) return false;
    const blockedFragments = [
      ' add-',
      ' clear-',
      ' copy-',
      ' disable-',
      ' enable-',
      ' invoke-',
      ' move-',
      ' new-',
      ' out-file',
      ' remove-',
      ' rename-',
      ' restart-',
      ' set-',
      ' start-',
      ' stop-',
      ' write-',
      '>>',
      '>',
      ';',
      '&&',
      '||',
      ' del ',
      ' erase ',
      ' rd ',
      ' rmdir ',
    ];
    if (blockedFragments.any(normalized.contains)) return false;
    const safeFragments = [
      'get-',
      'select-object',
      'sort-object',
      'measure-object',
      'where-object',
      'convertto-json',
      r'$psversiontable',
    ];
    return safeFragments.any(normalized.contains);
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
      AppSettings.defaultSftpDownloadLimitBytes;

  int get _sftpTextEditLimitBytes =>
      appSettings?.sftpTextEditLimitBytes ??
      AppSettings.defaultSftpTextEditLimitBytes;

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
