import 'dart:convert';
import 'dart:io';

/// 纯 Dart 实现的轻量级 PDF 文本提取器。
/// 无任何外部 Native 依赖，完全离线运行。
class PdfTextExtractor {
  const PdfTextExtractor._();

  /// 从 PDF 二进制数据中提取纯文本。
  static String extractText(List<int> bytes) {
    if (bytes.length < 4 ||
        bytes[0] != 0x25 || // %
        bytes[1] != 0x50 || // P
        bytes[2] != 0x44 || // D
        bytes[3] != 0x46) {
      // F
      throw ArgumentError('Invalid PDF file header.');
    }

    final textBuffer = StringBuffer();

    // 寻找 PDF 中的数据流
    final streamPattern = [115, 116, 114, 101, 97, 109]; // "stream"
    final endStreamPattern = [
      101,
      110,
      100,
      115,
      116,
      114,
      101,
      97,
      109
    ]; // "endstream"

    int start = 0;
    while (true) {
      final streamIdx = _indexOf(bytes, streamPattern, start);
      if (streamIdx == -1) break;

      final endStreamIdx = _indexOf(bytes, endStreamPattern, streamIdx + 6);
      if (endStreamIdx == -1) break;

      // 确定流数据的真实起始位置（跳过 stream 之后的换行符 \r\n 或 \n）
      int streamStart = streamIdx + 6;
      if (streamStart < bytes.length && bytes[streamStart] == 13)
        streamStart++; // \r
      if (streamStart < bytes.length && bytes[streamStart] == 10)
        streamStart++; // \n

      int streamEnd = endStreamIdx;
      // 剔除 endstream 前面的换行符
      if (streamEnd > streamStart && bytes[streamEnd - 1] == 10) streamEnd--;
      if (streamEnd > streamStart && bytes[streamEnd - 1] == 13) streamEnd--;

      if (streamEnd > streamStart) {
        final streamBytes = bytes.sublist(streamStart, streamEnd);
        List<int>? decompressedBytes;

        // 尝试使用 ZLib (FlateDecode) 解压
        try {
          decompressedBytes = zlib.decode(streamBytes);
        } catch (_) {
          // 解压失败，说明可能不是 Flate 压缩流或是非文本流（如图片），忽略即可
        }

        if (decompressedBytes != null) {
          try {
            // 将解压后的数据流转为 Latin1 字符串，便于按字符检索 PDF 指令
            final streamStr = latin1.decode(decompressedBytes);
            final extractedText = _parsePdfStreamText(streamStr);
            if (extractedText.isNotEmpty) {
              textBuffer.write(extractedText);
              textBuffer.write('\n');
            }
          } catch (_) {
            // 忽略转换失败的流
          }
        }
      }

      start = endStreamIdx + 9;
    }

    // 格式化输出：去除多余的空白和多重换行
    final rawResult = textBuffer.toString();
    final lines = rawResult.split('\n');
    final cleanedLines = <String>[];
    for (var line in lines) {
      final trimmed = line.trim();
      // 过滤掉 PDF 操作符指令残留，通常真正的文本行不会全由少于3个字母的特殊指令组成
      if (trimmed.isNotEmpty && !_isPdfOperatorOnly(trimmed)) {
        cleanedLines.add(trimmed);
      }
    }

    return cleanedLines.join('\n');
  }

  /// 在字节数组中定位子数组索引
  static int _indexOf(List<int> bytes, List<int> pattern, int start) {
    if (pattern.isEmpty) return -1;
    final limit = bytes.length - pattern.length;
    for (int i = start; i <= limit; i++) {
      var match = true;
      for (int j = 0; j < pattern.length; j++) {
        if (bytes[i + j] != pattern[j]) {
          match = false;
          break;
        }
      }
      if (match) return i;
    }
    return -1;
  }

  /// 判断一行是否仅仅是 PDF 内部控制指令
  static bool _isPdfOperatorOnly(String text) {
    if (text.length <= 2) {
      // 大部分纯控制指令如 BT, ET, Td, Tj, TJ, g, RG 很短
      final lower = text.toLowerCase();
      if (lower == 'bt' ||
          lower == 'et' ||
          lower == 'q' ||
          lower == 'q' ||
          lower == 'cm') {
        return true;
      }
    }
    return false;
  }

  /// 提取 PDF Stream 字符串中的文本信息。
  /// 精确扫描圆括号 `(...)` 提取文本，并支持处理嵌套括号和转义符号。
  static String _parsePdfStreamText(String streamStr) {
    final buffer = StringBuffer();
    int i = 0;
    final len = streamStr.length;

    // 我们只在 Text Block 内部提取文本（BT = Begin Text, ET = End Text）
    // 很多 PDF 即使不在 BT/ET 之间也可能有 Tj，这里做一个轻量且包容的扫描
    while (i < len) {
      if (streamStr[i] == '(') {
        i++;
        final start = i;
        var parens = 1;
        while (i < len && parens > 0) {
          if (streamStr[i] == '\\') {
            i += 2; // 跳过转义字符
            continue;
          }
          if (streamStr[i] == '(') {
            parens++;
          } else if (streamStr[i] == ')') {
            parens--;
          }
          if (parens > 0) {
            i++;
          }
        }
        if (i < len) {
          final content = streamStr.substring(start, i);
          buffer.write(_cleanPdfString(content));
          buffer.write(' '); // 加空格防止单词粘连
          i++; // 跳过结束圆括号 ')'
        }
      } else {
        i++;
      }
    }

    return buffer.toString();
  }

  /// 清理并转换 PDF 中的转义符及十六进制/八进制编码
  static String _cleanPdfString(String pdfStr) {
    if (pdfStr.isEmpty) return '';
    final buffer = StringBuffer();
    int i = 0;
    final len = pdfStr.length;

    while (i < len) {
      if (pdfStr[i] == '\\' && i + 1 < len) {
        final next = pdfStr[i + 1];
        if (next == 'n') {
          buffer.write('\n');
          i += 2;
        } else if (next == 'r') {
          buffer.write('\r');
          i += 2;
        } else if (next == 't') {
          buffer.write('\t');
          i += 2;
        } else if (next == 'b') {
          buffer.write('\b');
          i += 2;
        } else if (next == 'f') {
          buffer.write('\f');
          i += 2;
        } else if (next == '(' || next == ')' || next == '\\') {
          buffer.write(next);
          i += 2;
        } else if (RegExp(r'[0-7]').hasMatch(next)) {
          // 八进制字符转义，如 \344
          var octStart = i + 1;
          var octEnd = octStart;
          while (octEnd < len &&
              octEnd < octStart + 3 &&
              RegExp(r'[0-7]').hasMatch(pdfStr[octEnd])) {
            octEnd++;
          }
          final octStr = pdfStr.substring(octStart, octEnd);
          final octVal = int.tryParse(octStr, radix: 8);
          if (octVal != null) {
            buffer.write(String.fromCharCode(octVal));
          }
          i = octEnd;
        } else {
          buffer.write(next);
          i += 2;
        }
      } else {
        buffer.write(pdfStr[i]);
        i++;
      }
    }

    final decodedStr = buffer.toString();

    // 检查是否为 UTF-16 Big Endian 编码（以 FE FF 为特征标记，以支持中文等特殊字符）
    if (decodedStr.startsWith('þÿ') ||
        decodedStr.startsWith('þÿ') ||
        (decodedStr.length >= 2 &&
            decodedStr.codeUnitAt(0) == 0xFE &&
            decodedStr.codeUnitAt(1) == 0xFF)) {
      final bytes = <int>[];
      final startIdx =
          (decodedStr.startsWith('þÿ') || decodedStr.startsWith('þÿ')) ? 2 : 2;
      for (var idx = startIdx; idx < decodedStr.length; idx++) {
        bytes.add(decodedStr.codeUnitAt(idx) & 0xFF);
      }
      final utfBuffer = StringBuffer();
      for (var k = 0; k < bytes.length - 1; k += 2) {
        final code = (bytes[k] << 8) | bytes[k + 1];
        utfBuffer.write(String.fromCharCode(code));
      }
      return utfBuffer.toString();
    }

    return decodedStr;
  }
}
