import 'dart:async';

import '../telemetry/generated/telemetry_events.dart';
import '../telemetry/telemetry_catalog.dart';
import '../telemetry/telemetry_client.dart';
import '../telemetry/telemetry_model.dart';
import 'log_level.dart';
import 'log_record.dart';
import 'log_sink.dart';

/// A structured log sink that forwards only approved error diagnostics.
///
/// Ordinary application logs remain local. A record must have an explicit
/// event name in the configured allowlist, use [LogLevel.error], and pass the
/// diagnostic event schema before it is handed to [TelemetryClient]. This
/// keeps a logger sink from turning into an accidental full-log uploader.
final class TelemetryLogSink implements LogSink {
  /// Creates a sink owned by the App Scope logger.
  TelemetryLogSink({
    required this.client,
    TelemetryCatalog? catalog,
    Set<String>? allowlistedEvents,
  }) : catalog = catalog ?? client.catalog,
       allowlistedEvents = Set.unmodifiable(
         allowlistedEvents ?? defaultAllowlistedEvents,
       );

  /// The event names explicitly approved for structured error forwarding.
  static final Set<String> defaultAllowlistedEvents = Set.unmodifiable(
    TelemetryEvents.all
        .where(
          (event) =>
              event.feature != 'telemetry' &&
              event.recordType == TelemetryRecordType.diagnostic &&
              (event.severity == TelemetrySeverity.error ||
                  event.severity == TelemetrySeverity.critical),
        )
        .map((event) => event.name)
        .toSet(),
  );

  final TelemetryClient client;
  final TelemetryCatalog catalog;
  final Set<String> allowlistedEvents;
  Future<void> _writeQueue = Future<void>.value();
  bool _closed = false;

  /// Whether the sink has stopped accepting records.
  bool get isClosed => _closed;

  /// Completes after all accepted records have reached the client.
  Future<void> get pendingWrites => _writeQueue;

  @override
  void write(LogRecord record) {
    if (_closed || record.level != LogLevel.error) return;

    final eventName = record.eventName;
    if (eventName == null || !allowlistedEvents.contains(eventName)) return;
    final event = catalog.eventDefinition(eventName);
    if (event == null ||
        event.feature == 'telemetry' ||
        event.recordType != TelemetryRecordType.diagnostic ||
        (event.severity != TelemetrySeverity.error &&
            event.severity != TelemetrySeverity.critical)) {
      return;
    }

    final properties = <String, dynamic>{...record.attributes};
    // Application error/crash contracts require a message. Requiring an
    // explicit structured event name still keeps this path opt-in while the
    // LogRecord message supplies the event's required summary.
    if (event.allowedProperties.contains('message') &&
        !properties.containsKey('message')) {
      properties['message'] = record.message;
    }
    if (event.allowedProperties.contains('details') &&
        !properties.containsKey('details') &&
        record.details != null) {
      properties['details'] = record.details;
    }

    final errorCode = record.errorCode == null
        ? null
        : catalog.errorDefinition(record.errorCode!);
    if (record.errorCode != null && errorCode == null) return;

    final previous = _writeQueue;
    _writeQueue = previous.then<void>((_) async {
      try {
        final accepted = await client.record(
          event: event,
          properties: properties,
          errorCode: errorCode,
          errorMessage: record.error?.toString(),
          stackTrace: record.stackTrace?.toString(),
          sessionId: null,
          traceId: record.traceId,
        );
        // record() durably inserts before this await. Explicitly flushing here
        // makes the ordering clear for crash/error records without making the
        // logger call itself synchronous or network-bound.
        if (accepted) await client.flush();
      } on Object {
        // Logging must never throw into the business operation or recursively
        // manufacture a telemetry event about its own network failure.
      }
    });
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _writeQueue;
  }
}
