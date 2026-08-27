class TelemetryUploadPolicy {
  const TelemetryUploadPolicy({
    required this.uploadEnabled,
    required this.batchSizeThreshold,
    required this.timeIntervalSeconds,
    required this.maxBatchSize,
    required this.clientMaxLocalRecords,
    required this.specialTriggers,
    required this.policyVersion,
  });

  final bool uploadEnabled;
  final int batchSizeThreshold;
  final int timeIntervalSeconds;
  final int maxBatchSize;
  final int clientMaxLocalRecords;
  final List<String> specialTriggers;
  final int policyVersion;

  static const int minBatchSizeThreshold = 1;
  static const int maxBatchSizeThreshold = 1000;
  static const int minTimeIntervalSeconds = 5;
  static const int maxTimeIntervalSeconds = 3600;
  static const int minMaxBatchSize = 1;
  static const int maxMaxBatchSize = 1000;
  static const int minClientMaxLocalRecords = 100;
  static const int maxClientMaxLocalRecords = 1000000;

  factory TelemetryUploadPolicy.defaultPolicy() {
    return const TelemetryUploadPolicy(
      uploadEnabled: true,
      batchSizeThreshold: 50,
      timeIntervalSeconds: 60,
      maxBatchSize: 100,
      clientMaxLocalRecords: 10000,
      specialTriggers: [
        'highPriorityError',
        'appBackground',
        'networkRecovered',
        'appForegroundWithBacklog',
      ],
      policyVersion: 1,
    );
  }

  factory TelemetryUploadPolicy.fromJson(Map<String, dynamic> json) {
    final rawBatchThreshold = json['batchSizeThreshold'] as int? ?? 50;
    final rawInterval = json['timeIntervalSeconds'] as int? ?? 60;
    final rawMaxBatch = json['maxBatchSize'] as int? ?? 100;
    final rawMaxLocal = json['clientMaxLocalRecords'] as int? ?? 10000;
    final rawTriggers =
        (json['specialTriggers'] as List<dynamic>?)
            ?.map((e) => e.toString())
            .toList() ??
        [
          'highPriorityError',
          'appBackground',
          'networkRecovered',
          'appForegroundWithBacklog',
        ];
    final rawVersion = json['policyVersion'] as int? ?? 1;

    // Apply safety clamps
    final clampedBatchThreshold = rawBatchThreshold.clamp(
      minBatchSizeThreshold,
      maxBatchSizeThreshold,
    );
    final clampedInterval = rawInterval.clamp(
      minTimeIntervalSeconds,
      maxTimeIntervalSeconds,
    );
    final clampedMaxBatch = rawMaxBatch.clamp(minMaxBatchSize, maxMaxBatchSize);
    final clampedMaxLocal = rawMaxLocal.clamp(
      minClientMaxLocalRecords,
      maxClientMaxLocalRecords,
    );

    return TelemetryUploadPolicy(
      uploadEnabled: json['uploadEnabled'] as bool? ?? true,
      batchSizeThreshold: clampedBatchThreshold,
      timeIntervalSeconds: clampedInterval,
      maxBatchSize: clampedMaxBatch,
      clientMaxLocalRecords: clampedMaxLocal,
      specialTriggers: rawTriggers,
      policyVersion: rawVersion > 0 ? rawVersion : 1,
    );
  }

  Map<String, dynamic> toJson() => {
    'uploadEnabled': uploadEnabled,
    'batchSizeThreshold': batchSizeThreshold,
    'timeIntervalSeconds': timeIntervalSeconds,
    'maxBatchSize': maxBatchSize,
    'clientMaxLocalRecords': clientMaxLocalRecords,
    'specialTriggers': specialTriggers,
    'policyVersion': policyVersion,
  };
}
