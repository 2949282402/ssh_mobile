import 'dart:convert';
import 'dart:io';

import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('Telemetry HMAC Auth Golden Vectors', () {
    test('cross-language golden vector compliance matches Go backend', () {
      final candidates = [
        '../../../contracts/telemetry/auth_proof_vectors.json',
        '../../contracts/telemetry/auth_proof_vectors.json',
        'contracts/telemetry/auth_proof_vectors.json',
      ];

      File? vectorFile;
      for (final p in candidates) {
        final f = File(p);
        if (f.existsSync()) {
          vectorFile = f;
          break;
        }
      }

      expect(
        vectorFile,
        isNotNull,
        reason: 'auth_proof_vectors.json must exist in repository root contracts/',
      );

      final content = vectorFile!.readAsStringSync();
      final data = jsonDecode(content) as Map<String, dynamic>;
      final vectors = data['vectors'] as List<dynamic>;

      expect(vectors, isNotEmpty);

      const factory = HmacTelemetryProofFactory();

      for (final v in vectors) {
        final map = v as Map<String, dynamic>;
        final secret = map['secret'] as String;
        final deviceId = map['deviceId'] as String;
        final expEpoch = map['expEpoch'] as int;
        final expectedProof = map['proof'] as String;

        final computedProof = factory.sign(
          enrollmentSecret: secret,
          deviceId: deviceId,
          expEpoch: expEpoch,
        );

        expect(
          computedProof,
          expectedProof,
          reason: 'HMAC proof mismatch for device: $deviceId',
        );
      }
    });
  });
}
