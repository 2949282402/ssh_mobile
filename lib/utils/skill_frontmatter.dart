class SkillFrontmatter {
  final String name;
  final String description;
  final String body;

  const SkillFrontmatter({
    required this.name,
    required this.description,
    required this.body,
  });

  /// 解析包含 yaml frontmatter 的 markdown 文本。
  /// 如果不包含 frontmatter，则解析失败，返回 null。
  static SkillFrontmatter? parse(String text) {
    if (!text.trim().startsWith('---')) return null;

    final regex = RegExp(r'^---\r?\n([\s\S]*?)\r?\n---(?:\r?\n)?([\s\S]*)');
    final match = regex.firstMatch(text);
    if (match == null) return null;

    final frontmatterText = match.group(1) ?? '';
    final bodyText = match.group(2) ?? '';

    String name = '';
    String description = '';

    final lines = frontmatterText.split(RegExp(r'\r?\n'));
    int i = 0;
    while (i < lines.length) {
      final line = lines[i];
      final parts = line.split(':');
      if (parts.length < 2) {
        i++;
        continue;
      }

      final key = parts[0].trim().toLowerCase();
      final remainingValue = parts.sublist(1).join(':').trim();

      // 判断是否是多行 YAML 语法，如 name: > 或 description: >
      if (remainingValue.startsWith('>') || remainingValue.startsWith('|')) {
        final blockLines = <String>[];
        i++;
        // 收集所有缩进不为空的行
        while (i < lines.length &&
            (lines[i].startsWith(' ') || lines[i].isEmpty)) {
          final blockLine = lines[i];
          if (blockLine.trim().isEmpty) {
            blockLines.add('');
          } else {
            // 去除最开头的缩进（通常是 2 个空格）
            final trimmedLine = blockLine.replaceFirst(RegExp(r'^\s{1,2}'), '');
            blockLines.add(trimmedLine);
          }
          i++;
        }
        final finalVal = blockLines.join('\n').trim();
        if (key == 'name') {
          name = finalVal;
        } else if (key == 'description') {
          description = finalVal;
        }
      } else {
        // 单行解析，去除可能存在的首尾引号
        final cleanedVal = stripQuotes(remainingValue);
        if (key == 'name') {
          name = cleanedVal;
        } else if (key == 'description') {
          description = cleanedVal;
        }
        i++;
      }
    }

    return SkillFrontmatter(
      name: name,
      description: description,
      body: bodyText,
    );
  }

  /// 拼装带有 frontmatter 的文本。
  static String format({
    required String name,
    required String description,
    required String body,
  }) {
    final buffer = StringBuffer()..writeln('---');

    // 格式化 name
    if (name.contains('\n')) {
      buffer.writeln('name: >');
      for (final line in name.split('\n')) {
        buffer.writeln('  $line');
      }
    } else {
      buffer.writeln('name: "${escapeString(name)}"');
    }

    // 格式化 description
    if (description.contains('\n')) {
      buffer.writeln('description: >');
      for (final line in description.split('\n')) {
        buffer.writeln('  $line');
      }
    } else {
      buffer.writeln('description: "${escapeString(description)}"');
    }

    buffer
      ..writeln('---')
      ..write(body); // 不 trim()，保持 body 原始排版

    return buffer.toString();
  }

  /// 剥离首尾的双引号或单引号
  static String stripQuotes(String val) {
    var s = val.trim();
    if (s.isEmpty) return '';
    if ((s.startsWith('"') && s.endsWith('"')) ||
        (s.startsWith("'") && s.endsWith("'"))) {
      if (s.length <= 2) return '';
      s = s.substring(1, s.length - 1);
      s = s.replaceAll('\\"', '"').replaceAll('\\\\', '\\');
    }
    return s;
  }

  /// YAML 字符串转义
  static String escapeString(String s) {
    return s.replaceAll('\\', '\\\\').replaceAll('"', '\\"');
  }
}
