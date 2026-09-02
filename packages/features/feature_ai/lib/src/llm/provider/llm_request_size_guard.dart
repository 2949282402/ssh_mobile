import 'dart:convert';

import '../../data/models/ai_resource_models.dart';

/// Raised before an oversized serialized provider request can reach HTTP.
class LlmRequestPayloadTooLargeException extends StateError {
  final int actualBytes;
  final int maxBytes;

  LlmRequestPayloadTooLargeException({
    required this.actualBytes,
    required this.maxBytes,
  }) : super(
         'Request payload exceeds the configured safety limit after context '
         'reduction. actualBytes=$actualBytes maxBytes=$maxBytes',
       );
}

/// Encodes [requestBody] once and rejects it when its serialized UTF-8 bytes
/// exceed the final provider request limit.
String encodeBoundedJsonRequest(
  Object? requestBody, {
  int maxBytes = AiRequestBudget.maxSerializedRequestBytes,
}) {
  if (maxBytes < 0) {
    throw ArgumentError.value(maxBytes, 'maxBytes', 'must not be negative');
  }

  final encodedBody = jsonEncode(requestBody);
  final encodedBytes = utf8.encode(encodedBody);
  if (encodedBytes.length > maxBytes) {
    throw LlmRequestPayloadTooLargeException(
      actualBytes: encodedBytes.length,
      maxBytes: maxBytes,
    );
  }
  return encodedBody;
}
