import 'package:flutter_test/flutter_test.dart';
import 'package:ssh_mobile/services/tool_secret_policy.dart';

void main() {
  const policy = ToolSecretPolicy();

  test('redacts auth headers, cookies, tokens, and URL query secrets', () {
    final redacted = policy.redactText(
      'Authorization: Bearer sk-secret\n'
      'Authorization: Basic dXNlcjpwYXNz\n'
      'Cookie: session=abc\n'
      'Set-Cookie: refresh=def\n'
      'x-api-key: key-123\n'
      'url=https://example.com/path?token=abc&client_secret=def\n'
      'password=plain private_key=hidden refresh_token=refresh',
    );

    expect(redacted, isNot(contains('sk-secret')));
    expect(redacted, isNot(contains('dXNlcjpwYXNz')));
    expect(redacted, isNot(contains('session=abc')));
    expect(redacted, isNot(contains('key-123')));
    expect(redacted, isNot(contains('client_secret=def')));
    expect(redacted, contains('[REDACTED]'));
  });

  test('redacts private key blocks', () {
    final redacted = policy.redactText(
      '-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n'
      '-----END OPENSSH PRIVATE KEY-----',
    );

    expect(redacted, '[REDACTED]');
  });

  test('blocks secret-bearing paths', () {
    expect(policy.suspiciousPathReason('/etc/shadow'), isNotNull);
    expect(policy.suspiciousPathReason('/etc/sudoers'), isNotNull);
    expect(policy.suspiciousPathReason('/proc/self/environ'), isNotNull);
    expect(policy.suspiciousPathReason('~/.aws/credentials'), isNotNull);
    expect(policy.suspiciousPathReason('/home/demo/.kube/config'), isNotNull);
    expect(policy.suspiciousPathReason('secret-token.txt'), isNotNull);
    expect(policy.suspiciousPathReason('/tmp/readme.txt'), isNull);
    expect(
      policy.suspiciousPathReason('blocked by the tool secret policy'),
      isNull,
    );
    expect(policy.suspiciousPathReason('tool_secret_policy'), isNull);
  });

  test('blocks environment dumps and metadata endpoints in commands', () {
    expect(policy.blockedCommandReason('printenv'), contains('Environment'));
    expect(
      policy.blockedCommandReason('curl 169.254.169.254'),
      contains('metadata'),
    );
    expect(
      policy.blockedCommandReason('curl metadata.google.internal'),
      contains('metadata'),
    );
    expect(policy.blockedCommandReason('cat /tmp/readme.txt'), isNull);
  });
}
