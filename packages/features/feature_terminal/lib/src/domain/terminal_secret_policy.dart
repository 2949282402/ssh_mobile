// Terminal 历史页面使用的最小敏感信息脱敏策略。
//
// 历史错误信息可能来自 SSH/认证层，页面只展示脱敏且有界的摘要，避免
// 密码、Token、私钥片段或过长异常文本进入 UI。

/// 对 Terminal 历史错误信息做脱敏和长度限制。
final class TerminalSecretPolicy {
  /// 脱敏占位符。
  static const String redacted = '[REDACTED]';

  /// 返回不超过 [maxChars] 的安全摘要。
  String previewText(String value, {int maxChars = 240}) {
    var text = value.replaceAll(
      RegExp(
        r'-----BEGIN [A-Z0-9 ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z0-9 ]*PRIVATE KEY-----',
        caseSensitive: false,
      ),
      redacted,
    );
    text = text.replaceAllMapped(
      RegExp(
        r'\b(password|passwd|pwd|token|secret|api[_-]?key|private[_-]?key)\b\s*[:=]\s*([^\s,;]+)',
        caseSensitive: false,
      ),
      (match) => '${match.group(1)}=$redacted',
    );
    text = text.replaceAllMapped(
      RegExp(r'Bearer\s+[A-Za-z0-9._~+/=-]+', caseSensitive: false),
      (_) => redacted,
    );
    if (text.length <= maxChars) return text;
    return '${text.substring(0, maxChars)}...[truncated]';
  }
}
