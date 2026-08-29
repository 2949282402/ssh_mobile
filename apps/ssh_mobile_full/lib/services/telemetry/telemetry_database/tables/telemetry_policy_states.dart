part of '../../telemetry_database.dart';

/// Durable singleton holding the last policy accepted by the telemetry client.
///
/// The explicit version column lets migrations and diagnostics inspect the
/// monotonic policy boundary without parsing untrusted JSON first.
// Drift replaces this declaration with a generated TableInfo subclass; the
// column builders below are declarative schema input rather than executable
// business logic.
// coverage:ignore-start
class TelemetryPolicyStates extends Table {
  /// There is one policy row per telemetry database.
  IntColumn get id => integer()();

  /// Serialized policy values; only validated policy objects are written.
  TextColumn get policyJson => text()();

  /// Denormalized version used for monotonic comparisons.
  IntColumn get policyVersion => integer()();

  /// Last durable write time in UTC.
  DateTimeColumn get updatedAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}
// coverage:ignore-end
