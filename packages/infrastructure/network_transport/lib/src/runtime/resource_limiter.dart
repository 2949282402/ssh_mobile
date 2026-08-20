/// Frozen Network V2 resource budgets shared by App/native adapters.
///
/// The limiter deliberately accounts for both item count and bytes. A caller
/// must reserve before enqueueing and release exactly once after dequeue or
/// cancellation; it never owns the queued value or the runtime.
final class ResourceLimiter {
  const ResourceLimiter({
    required this.maxItems,
    required this.maxBytes,
    required this.maxSinglePayloadBytes,
  }) : assert(maxItems > 0),
       assert(maxBytes > 0),
       assert(maxSinglePayloadBytes > 0);

  static const int maxActivePeers = 64;
  static const int maxConfiguredPeers = 256;
  static const int maxEstablishments = 8;
  static const int maxUnauthenticatedInbound = 32;
  static const int maxRelayDataPaths = 64;
  static const int maxCommandsPerPeer = 64;
  static const int maxStreamsPerPeer = 32;
  static const int maxActiveTransfers = 16;
  static const int maxControlQueueItems = 256;
  static const int maxControlQueueBytes = 4 * 1024 * 1024;
  static const int maxDataQueueItems = 128;
  static const int maxDataQueueBytes = 8 * 1024 * 1024;
  static const int maxCommandBytes = 1024 * 1024;
  static const int maxEventBytes = 1024 * 1024;
  static const int maxStreamChunkBytes = 64 * 1024;

  static const ResourceLimiter controlQueue = ResourceLimiter(
    maxItems: maxControlQueueItems,
    maxBytes: maxControlQueueBytes,
    maxSinglePayloadBytes: maxEventBytes,
  );
  static const ResourceLimiter dataQueue = ResourceLimiter(
    maxItems: maxDataQueueItems,
    maxBytes: maxDataQueueBytes,
    maxSinglePayloadBytes: maxEventBytes,
  );

  final int maxItems;
  final int maxBytes;
  final int maxSinglePayloadBytes;

  bool canReserve({required int items, required int bytes}) {
    if (items < 0 || bytes < 0) {
      return false;
    }
    // `bytes` is the aggregate reservation when more than one item is being
    // reserved. Only a single-item reservation is also a single payload.
    if (items == 1 && bytes > maxSinglePayloadBytes) return false;
    return items <= maxItems && bytes <= maxBytes;
  }
}
