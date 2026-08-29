import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import 'generated/error_codes.dart';
import 'telemetry_catalog.dart';
import 'telemetry_endpoints.dart';
import 'telemetry_model.dart';
import 'telemetry_policy.dart';
import 'telemetry_redactor.dart';
import 'telemetry_storage.dart';

part 'telemetry_client_models.dart';
part 'telemetry_client_timer.dart';
part 'telemetry_client_transport.dart';
part 'telemetry_http_transport.dart';
part 'telemetry_client_base.dart';
part 'telemetry_client_recording.dart';
part 'telemetry_client_authentication.dart';
part 'telemetry_client_upload.dart';
part 'telemetry_client_lifecycle.dart';

/// Client-side telemetry recorder and upload dispatcher.
///
/// The public facade remains intentionally small. Its implementation is split
/// into private library parts so recording, authentication, upload/retry, and
/// lifecycle state each have an explicit owner without changing the package
/// export or the injected storage/transport contracts.
class TelemetryClient extends _TelemetryClientBase
    with
        _TelemetryClientRecording,
        _TelemetryClientAuthentication,
        _TelemetryClientUpload,
        _TelemetryClientLifecycle {
  TelemetryClient({
    required super.config,
    required super.storage,
    super.catalog,
    super.transport,
    super.initialPolicy,
    super.redactor,
    super.timerFactory,
    super.clock,
    super.random,
  }) {
    _beginPolicyRestore();
  }
}
