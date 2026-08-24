// System Admin 电源操作的一次性确认 Token 模型。

part of 'system_power_confirm_flow.dart';

class SystemPowerConfirmationToken {
  static const Duration validity = Duration(minutes: 2);

  final SystemPowerAction action;
  final SystemAdminSessionTarget target;
  final DateTime issuedAt;
  final String nonce;

  SystemPowerConfirmationToken._({
    required this.action,
    required this.target,
    required this.issuedAt,
    required this.nonce,
  });

  bool get isFresh {
    final age = DateTime.now().difference(issuedAt);
    return !age.isNegative && age <= validity;
  }

  @visibleForTesting
  factory SystemPowerConfirmationToken.testing({
    required SystemPowerAction action,
    required SystemAdminSessionTarget target,
    DateTime? issuedAt,
    String? nonce,
  }) {
    return SystemPowerConfirmationToken._(
      action: action,
      target: target,
      issuedAt: issuedAt ?? DateTime.now(),
      nonce:
          nonce ??
          'test-${action.name}-${target.generation}-'
              '${DateTime.now().microsecondsSinceEpoch}',
    );
  }
}
