import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/foundation.dart';

import '../sftp_service.dart';

class SftpEntryParser {
  const SftpEntryParser._();

  static Future<List<SftpEntry>> parse({
    required String connectionId,
    required String targetFingerprint,
    required String absolutePath,
    required Iterable<SftpName> names,
  }) => compute(
    _parseSftpEntries,
    _SftpEntriesInput(
      connectionId: connectionId,
      targetFingerprint: targetFingerprint,
      absolutePath: absolutePath,
      names: names.toList(growable: false),
    ),
  );
}

class _SftpEntriesInput {
  const _SftpEntriesInput({
    required this.connectionId,
    required this.targetFingerprint,
    required this.absolutePath,
    required this.names,
  });

  final String connectionId;
  final String targetFingerprint;
  final String absolutePath;
  final List<SftpName> names;
}

List<SftpEntry> _parseSftpEntries(_SftpEntriesInput input) {
  final entries = <SftpEntry>[];
  for (final name in input.names) {
    if (name.filename == '.' || name.filename == '..') continue;
    final modifiedAt = name.attr.modifyTime == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(name.attr.modifyTime! * 1000);
    entries.add(
      SftpEntry(
        connectionId: input.connectionId,
        targetFingerprint: input.targetFingerprint,
        name: name.filename,
        path: _joinPath(input.absolutePath, name.filename),
        lowerName: name.filename.toLowerCase(),
        isDirectory: name.attr.isDirectory,
        isLink: name.attr.isSymbolicLink,
        size: name.attr.size,
        sizeLabel: _formatBytes(name.attr.size),
        modifiedAt: modifiedAt,
        modifiedLabel: modifiedAt == null ? null : _formatTimestamp(modifiedAt),
      ),
    );
  }
  entries.sort((a, b) {
    if (a.isDirectory != b.isDirectory) return a.isDirectory ? -1 : 1;
    return a.lowerName.compareTo(b.lowerName);
  });
  return entries;
}

String _joinPath(String base, String name) {
  if (base == '/' || base.isEmpty) return '/$name';
  return '$base/$name';
}

String _formatBytes(int? bytes) {
  if (bytes == null) return '-';
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(gb < 10 ? 1 : 0)} GB';
}

String _formatTimestamp(DateTime time) {
  String two(int value) => value.toString().padLeft(2, '0');
  return '${time.year.toString().padLeft(4, '0')}-'
      '${two(time.month)}-'
      '${two(time.day)} '
      '${two(time.hour)}:'
      '${two(time.minute)}';
}
