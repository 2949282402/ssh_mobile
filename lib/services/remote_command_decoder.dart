import 'dart:convert';

import 'package:flutter/foundation.dart';

class DecodedRemoteOutput {
  const DecodedRemoteOutput({required this.stdout, required this.stderr});

  final String stdout;
  final String stderr;
}

Future<DecodedRemoteOutput> decodeRemoteCommandBytes({
  required List<int> stdout,
  required List<int> stderr,
}) => compute(_decodeRemoteCommandBytes, {'stdout': stdout, 'stderr': stderr});

DecodedRemoteOutput _decodeRemoteCommandBytes(Map<String, List<int>> bytes) {
  return DecodedRemoteOutput(
    stdout: utf8.decode(bytes['stdout']!, allowMalformed: true),
    stderr: utf8.decode(bytes['stderr']!, allowMalformed: true),
  );
}
