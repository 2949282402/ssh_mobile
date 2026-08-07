part of 'system_power_confirm_flow.dart';

class SystemPowerConfirmationToken {
  final SystemPowerAction action;
  final DateTime issuedAt;
  final String nonce;

  SystemPowerConfirmationToken._({
    required this.action,
    required this.issuedAt,
    required this.nonce,
  });

  bool get isFresh {
    return DateTime.now().difference(issuedAt) <= const Duration(minutes: 2);
  }

  @visibleForTesting
  factory SystemPowerConfirmationToken.testing({
    required SystemPowerAction action,
    DateTime? issuedAt,
  }) {
    return SystemPowerConfirmationToken._(
      action: action,
      issuedAt: issuedAt ?? DateTime.now(),
      nonce: 'test',
    );
  }
}
