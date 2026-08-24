import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/sftp/sftp_log_safety.dart';

void main() {
  test('path details are deterministic and never contain the source path', () {
    const path = '/home/alice/.ssh/id_rsa';

    final first = SftpLogSafety.details(
      operation: 'preview_read',
      connectionId: 'server-1',
      path: path,
      bytes: 42,
    );
    final second = SftpLogSafety.details(
      operation: 'preview_read',
      connectionId: 'server-1',
      path: path,
      bytes: 42,
    );

    expect(first, second);
    expect(first, isNot(contains(path)));
    expect(first, contains('pathHash='));
    expect(first, contains('bytes=42'));
  });

  test('source and destination paths use separate irreversible hashes', () {
    final details = SftpLogSafety.details(
      operation: 'rename',
      path: '/secret/source.env',
      destinationPath: '/secret/destination.env',
      directory: false,
    );

    expect(details, isNot(contains('/secret/')));
    expect(details, contains('pathHash='));
    expect(details, contains('destinationPathHash='));
    expect(details, contains('directory=false'));
  });

  test('error codes are stable categories without exception messages', () {
    expect(SftpLogSafety.errorCode(TimeoutException('private')), 'timeout');
    expect(
      SftpLogSafety.errorCode(const FileSystemException('private')),
      'filesystem_error',
    );
    expect(
      SftpLogSafety.errorCode(const FormatException('private')),
      'invalid_format',
    );
    expect(
      SftpLogSafety.errorCode(ArgumentError('private')),
      'invalid_argument',
    );
    expect(SftpLogSafety.errorCode(StateError('private')), 'invalid_state');
    expect(SftpLogSafety.errorCode(Exception('private')), 'operation_failed');
  });
}
