import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:ssh_mobile/services/remote_command_decoder.dart';

void main() {
  test('remote command output is decoded in a background isolate', () async {
    final decoded = await decodeRemoteCommandBytes(
      stdout: utf8.encode('运行正常\n'),
      stderr: utf8.encode('warning'),
    );

    expect(decoded.stdout, '运行正常\n');
    expect(decoded.stderr, 'warning');
  });
}
