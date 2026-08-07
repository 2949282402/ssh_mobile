class SshConnectionInfo {
  final String user;
  final String host;
  final int port;

  const SshConnectionInfo({
    required this.user,
    required this.host,
    this.port = 22,
  });
}

/// Helper class for parsing smart text actions (SSH commands, URLs, IPs)
class LanTextActionHelper {
  static final RegExp _sshPattern = RegExp(
    r'ssh\s+(?:-p\s+(\d+)\s+)?(?:([a-zA-Z0-9_\-]+)@)?([a-zA-Z0-9_\-\.]+)(?:\s+-p\s+(\d+))?',
    caseSensitive: false,
  );

  static final RegExp _urlPattern = RegExp(
    r'https?:\/\/[^\s]+',
    caseSensitive: false,
  );

  static final RegExp _ipPattern = RegExp(r'\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b');

  /// Parse SSH connection string such as `ssh root@192.168.1.100` or `ssh -p 2222 admin@host.com`
  static SshConnectionInfo? parseSshString(String text) {
    final trimmed = text.trim();
    final match = _sshPattern.firstMatch(trimmed);
    if (match != null) {
      final port1 = match.group(1);
      final user = match.group(2) ?? 'root';
      final host = match.group(3) ?? '';
      final port2 = match.group(4);
      final port = int.tryParse(port1 ?? port2 ?? '22') ?? 22;
      if (host.isNotEmpty) {
        return SshConnectionInfo(user: user, host: host, port: port);
      }
    }

    // Secondary heuristic if string is just user@host
    if (trimmed.contains('@') && !trimmed.contains(' ')) {
      final parts = trimmed.split('@');
      if (parts.length == 2 && parts[1].isNotEmpty) {
        return SshConnectionInfo(user: parts[0], host: parts[1], port: 22);
      }
    }

    return null;
  }

  /// Parse URL string (http:// or https://)
  static String? parseUrl(String text) {
    final match = _urlPattern.firstMatch(text.trim());
    return match?.group(0);
  }

  /// Parse IPv4 address
  static String? parseIp(String text) {
    final match = _ipPattern.firstMatch(text.trim());
    return match?.group(0);
  }
}
