import 'package:app_core/app_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const redactor = TelemetryRedactor();

  group('TelemetryRedactor schema boundary', () {
    const event = TelemetryEventDefinition(
      name: 'test.error',
      version: 1,
      recordType: TelemetryRecordType.diagnostic,
      feature: 'test',
      severity: TelemetrySeverity.error,
      allowedProperties: {'message', 'stage', 'count', 'enabled'},
      requiredProperties: {'message'},
      propertyTypes: {
        'message': 'string',
        'stage': 'string',
        'count': 'integer',
        'enabled': 'boolean',
      },
    );

    test('accepts typed allowlisted values and returns an immutable copy', () {
      final properties = redactor.sanitizeProperties(event, {
        'message': 'failure summary',
        'stage': 'handshake-1',
        'count': 2,
        'enabled': true,
      });

      expect(properties, {
        'message': 'failure summary',
        'stage': 'handshake-1',
        'count': 2,
        'enabled': true,
      });
      expect(() => properties!['message'] = 'changed', throwsUnsupportedError);
    });

    test(
      'rejects unknown keys, missing schema types, and wrong primitive types',
      () {
        expect(
          redactor.sanitizeProperties(event, {
            'message': 'failure',
            'unknown': 'value',
          }),
          isNull,
        );
        expect(
          redactor.sanitizeProperties(
            const TelemetryEventDefinition(
              name: 'missing-type',
              version: 1,
              recordType: TelemetryRecordType.diagnostic,
              feature: 'test',
              severity: TelemetrySeverity.error,
              allowedProperties: {'message'},
              requiredProperties: {'message'},
            ),
            {'message': 'failure'},
          ),
          isNull,
        );
        expect(redactor.sanitizeProperties(event, {'message': 1}), isNull);
        expect(
          redactor.sanitizeProperties(event, {
            'message': 'failure',
            'count': true,
          }),
          isNull,
        );
        expect(
          redactor.sanitizeProperties(event, {
            'message': 'failure',
            'enabled': 'true',
          }),
          isNull,
        );
        expect(
          redactor.sanitizeProperties(event, {'stage': 'handshake'}),
          isNull,
        );
        expect(
          redactor.sanitizeProperties(
            const TelemetryEventDefinition(
              name: 'unknown-type',
              version: 1,
              recordType: TelemetryRecordType.diagnostic,
              feature: 'test',
              severity: TelemetrySeverity.error,
              allowedProperties: {'message'},
              requiredProperties: {'message'},
              propertyTypes: {'message': 'object'},
            ),
            {'message': 'failure'},
          ),
          isNull,
        );
      },
    );

    test(
      'rejects unsafe labels and restricted values but allows empty text',
      () {
        expect(redactor.sanitizePropertyText('bad key', 'value'), isNull);
        expect(
          redactor.sanitizePropertyText('stage', 'host.example.test'),
          TelemetryRedactor.redacted,
        );
        expect(redactor.sanitizePropertyText('stage', '192.0.2.10'), isNull);
        expect(redactor.sanitizePropertyText('message', ''), '');
        expect(
          redactor.sanitizePropertyText('details', 'safe detail'),
          'safe detail',
        );
      },
    );
  });

  test('redacts credential, endpoint, command, and path variants', () {
    final input = [
      'password=placeholder-password',
      'token placeholder-token',
      'credential placeholder-credential',
      'auth placeholder-auth',
      'user_name placeholder-user-name',
      'ssh_host placeholder-ssh-host',
      'Authorization: Bearer placeholder-bearer',
      'Cookie: sid=placeholder-cookie',
      'x-api-key: placeholder-api-key',
      'Basic placeholder-basic',
      'header1234.payload1234.signature1234',
      '-----BEGIN OPENSSH PRIVATE KEY-----\nplaceholder\n'
          '-----END OPENSSH PRIVATE KEY-----',
      'sk-abcdefghijkl',
      'ssh://placeholder-user@192.0.2.10:22/home/placeholder',
      'host.example.test and 2001:db8::1',
      'command cat /tmp/placeholder/file',
      'C:\\placeholder\\file and ~/placeholder/file',
      r'\\placeholder-host\share\file and ./relative/file',
      'packages/placeholder/file.dart',
      '?access_token=placeholder-query&next=1',
    ].join(' | ');

    final sanitized = redactor.sanitizeText(input);

    for (final fragment in [
      'placeholder-password',
      'placeholder-token',
      'placeholder-credential',
      'placeholder-auth',
      'placeholder-user-name',
      'placeholder-ssh-host',
      'placeholder-bearer',
      'placeholder-cookie',
      'placeholder-api-key',
      'placeholder-basic',
      'header1234.payload1234.signature1234',
      'placeholder-user',
      '192.0.2.10',
      'host.example.test',
      '2001:db8::1',
      'cat /tmp/placeholder/file',
      'C:\\placeholder\\file',
      '~/placeholder/file',
      'placeholder-query',
    ]) {
      expect(sanitized, isNot(contains(fragment)), reason: fragment);
    }
    expect(sanitized, contains(TelemetryRedactor.redacted));
  });

  test(
    'fails closed for adversarial token, host, path, and command variants',
    () {
      final input = [
        'sk-proj-abcdefghijklmnop',
        'ASIAABCDEFGHIJKLMNOP',
        'OPENAI_API_KEY=env-placeholder-value',
        'AWS_SECRET_ACCESS_KEY=aws-placeholder-value',
        'localhost:8080',
        'bare-host:22',
        '../folder with spaces/file.txt',
        'project/secret file.txt',
        r'relative\folder with spaces\file.txt',
        'python script.py --input=relative/file.txt',
        'node ./script.js --config=project/config.json',
        'kubectl get pods --context=cluster-placeholder',
      ].join(' | ');

      final sanitized = redactor.sanitizeText(input);

      for (final fragment in [
        'abcdefghijklmnop',
        'ASIAABCDEFGHIJKLMNOP',
        'env-placeholder-value',
        'aws-placeholder-value',
        'localhost:8080',
        'bare-host:22',
        'folder with spaces/file.txt',
        'project/secret file.txt',
        r'folder with spaces\file.txt',
        'python script.py',
        'node ./script.js',
        'kubectl get pods',
        'cluster-placeholder',
      ]) {
        expect(sanitized, isNot(contains(fragment)), reason: fragment);
      }
      expect(sanitized, contains(TelemetryRedactor.redacted));
    },
  );

  test(
    'redacts prefixed secret assignments without destroying lookalike metadata',
    () {
      final sanitized = redactor.sanitizeText(
        [
          'remote_password=remote-placeholder',
          'ssh_username: ssh-placeholder',
          'GITHUB_TOKEN=ghs_abcdefghijklmnop',
          'AWS_SESSION_TOKEN=aws-session-placeholder',
          'GOOGLE_API_KEY=google-api-placeholder',
          'remote_password_alias=aliased-password-placeholder',
          'remote_password remote-word-placeholder',
          'AWS_SESSION_TOKEN aws-word-placeholder',
          'token_count=42',
          'passwordless_mode=true',
          'user_count=7',
        ].join(' | '),
      );

      for (final fragment in [
        'remote-placeholder',
        'ssh-placeholder',
        'ghs_abcdefghijklmnop',
        'aws-session-placeholder',
        'google-api-placeholder',
        'aliased-password-placeholder',
        'remote-word-placeholder',
        'aws-word-placeholder',
      ]) {
        expect(sanitized, isNot(contains(fragment)), reason: fragment);
      }
      for (final safeMetadata in [
        'token_count=42',
        'passwordless_mode=true',
        'user_count=7',
      ]) {
        expect(sanitized, contains(safeMetadata), reason: safeMetadata);
      }
    },
  );

  test('redacts exception and stack text and bounds long diagnostics', () {
    expect(
      redactor.sanitizeExceptionText('failure password=exception-placeholder'),
      isNot(contains('exception-placeholder')),
    );
    expect(
      redactor.sanitizeStackTrace(
        'at /home/placeholder/client.dart:1:1 token=stack-placeholder',
      ),
      isNot(contains('stack-placeholder')),
    );
    expect(redactor.sanitizeExceptionText(null), isNull);
    expect(redactor.sanitizeExceptionText(''), isNull);
    expect(redactor.sanitizeStackTrace(null), isNull);
    expect(redactor.sanitizeStackTrace(''), isNull);

    final bounded = redactor.sanitizeText('x' * 600);
    expect(
      bounded.length,
      lessThanOrEqualTo(TelemetryRedactor.maxTextLength + 14),
    );
    expect(bounded, endsWith('...[truncated]'));
  });

  test('accepts safe correlation identifiers and rejects unsafe variants', () {
    expect(redactor.sanitizeIdentifier('trace-123'), 'trace-123');
    expect(redactor.sanitizeIdentifier(null), isNull);
    expect(redactor.sanitizeIdentifier(''), isNull);
    expect(redactor.sanitizeIdentifier('trace with spaces'), isNull);
    expect(redactor.sanitizeIdentifier('password-value'), isNull);
    expect(redactor.sanitizeIdentifier('192.0.2.10'), isNull);
    expect(redactor.sanitizeIdentifier('token-value'), isNull);
  });
}
