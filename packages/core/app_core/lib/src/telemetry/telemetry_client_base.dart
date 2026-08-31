part of 'telemetry_client.dart';

const Uuid _telemetryUuid = Uuid();

/// Shared state and cross-part implementation contracts for [TelemetryClient].
///
/// The base owns all mutable state so recording, authentication, upload, and
/// lifecycle parts cannot accidentally create competing resource owners.
abstract class _TelemetryClientBase {
  _TelemetryClientBase({
    required this.config,
    required this.storage,
    TelemetryCatalog? catalog,
    TelemetryTransport? transport,
    TelemetryUploadPolicy? initialPolicy,
    TelemetryRedactor? redactor,
    TelemetryTimerFactory? timerFactory,
    DateTime Function()? clock,
    Random? random,
  }) : catalog = catalog ?? TelemetryCatalog.instance,
       transport = transport ?? HttpTelemetryTransport(),
       activePolicy = initialPolicy ?? TelemetryUploadPolicy.defaultPolicy(),
       redactor = redactor ?? const TelemetryRedactor(),
       _timerFactory = timerFactory ?? const DartTelemetryTimerFactory(),
       _clock = clock ?? (() => DateTime.now().toUtc()),
       _random = random ?? Random(),
       _telemetryEnabled = config.telemetryEnabled,
       sessionId = config.sessionId ?? _telemetryUuid.v4() {
    // Keep the credential in memory for this client lifetime. The enrollment
    // provider persists it for restart recovery; refresh reuses this secret.
    _telemetrySecret = config.deviceEnrollmentSecret;
  }

  final TelemetryClientConfig config;
  final TelemetryStorage storage;
  final TelemetryCatalog catalog;
  final TelemetryTransport transport;
  final TelemetryRedactor redactor;
  final TelemetryTimerFactory _timerFactory;
  final DateTime Function() _clock;
  final Random _random;

  bool _telemetryEnabled;

  /// Whether App Scope has confirmed a valid Relay enrollment.
  bool get telemetryEnabled => !_isDisposed && _telemetryEnabled;

  /// Whether new telemetry records may cross the local durable boundary.
  bool get recordingEnabled => !_isDisposed && _telemetryEnabled;

  /// Internal gate used by queued operations that were accepted before
  /// disposal. Those operations are allowed to drain, but never after the
  /// Relay enrollment gate is disabled.
  bool get _canPersistRecord => _telemetryEnabled;

  /// Upload/replay and their ACK bookkeeping require both the Relay gate and
  /// the server-controlled upload policy.
  bool get _canRecord => _telemetryEnabled && activePolicy.uploadEnabled;

  /// App-lifetime session ID.
  final String sessionId;

  TelemetryUploadPolicy activePolicy;
  String? _telemetrySecret;
  String? _authToken;
  DateTime? _authTokenExpiresAt;
  int _authTokenGeneration = 0;
  Future<void>? _authenticationFuture;
  Future<void>? _uploadFuture;
  Future<bool>? _policyRefreshFuture;
  Future<void>? _policyReadyFuture;
  bool _policyRestoreStarted = false;

  // All producers share one durable storage-write queue. This preserves
  // invocation order for fire-and-forget record calls.
  Future<void> _recordQueue = Future<void>.value();

  DateTime? _lastSyncTime;
  String? _lastSyncError;
  DateTime? _lastPolicyFetchTime;
  bool _isUploading = false;
  bool _isDisposed = false;
  Future<void>? _disposeFuture;
  bool _uploadRequested = false;
  bool _policyRefreshRequested = false;
  bool _hasRunCapacityMaintenance = false;
  int _writesSinceCapacityCheck = 0;
  Completer<void>? _retryWaitCompleter;
  TelemetryTimer? _periodicFlushTimer;
  TelemetryTimer? _retryTimer;
  TelemetryTimer? _policyRefreshTimer;

  /// Completes after durable last-known-good policy restoration and timer
  /// startup. App composition can await this before exposing the client.
  Future<void> get ready => _policyReadyFuture ?? Future<void>.value();

  String _newTraceId() => _telemetryUuid.v4();

  DateTime _now() => _clock().toUtc();

  bool get _hasValidToken =>
      _authToken != null &&
      _authToken!.isNotEmpty &&
      _authTokenExpiresAt != null &&
      _authTokenExpiresAt!.isAfter(_now());

  void _clearAuthToken() {
    _authToken = null;
    _authTokenExpiresAt = null;
    _authTokenGeneration++;
  }

  void _setAuthToken(String token, DateTime expiresAt) {
    _authToken = token;
    _authTokenExpiresAt = expiresAt;
    _authTokenGeneration++;
  }

  void _recordStorageFailure() {
    _lastSyncError = 'Telemetry storage operation failed';
  }

  String _describeError(Object error) {
    if (error is TelemetryUploadException) {
      final code = _safeTelemetryErrorCode(error.errorCode);
      final status = error.statusCode;
      if (code != null && status != null) {
        return 'Telemetry request failed ($code, HTTP $status)';
      }
      if (code != null) return 'Telemetry request failed ($code)';
      if (status != null) return 'Telemetry request failed (HTTP $status)';
      return 'Telemetry request failed';
    }
    if (error is HttpException) return 'Telemetry connection error';
    return 'Telemetry operation failed';
  }

  bool _isSafePersistedMetadata(String value) {
    return value.isNotEmpty &&
        value.length <= TelemetryRedactor.maxTextLength &&
        redactor.sanitizeText(value) == value;
  }

  String? _sanitizeConfiguredMetadata(String value) {
    if (!_isSafePersistedMetadata(value)) return null;
    return value;
  }

  // Cross-part contracts. Implementations remain in their owning behavior
  // part, while these declarations let each mixin type-check independently.
  Future<void> _requestUpload();
  void _completeUpload(Future<void> operation);
  Future<List<TelemetryEventRecord>> _preparePersistedRecords(
    Iterable<TelemetryEventRecord> records,
  );
  TelemetryEventRecord? _sanitizePersistedRecord(TelemetryEventRecord record);
  Future<void> _ensureAuthenticated();
  void _cancelRetryTimer();
}
