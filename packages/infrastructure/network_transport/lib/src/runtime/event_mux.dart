import 'dart:collection';

import 'resource_limiter.dart';

/// Priority assigned by the typed adapter before an event enters [EventMux].
///
/// The adapter owns the classification because it knows which decoded event
/// is a terminal/control event.  The mux itself is transport-neutral.
enum EventMuxPriority {
  criticalControl,
  normalControl,
  data;

  bool get isControl => this != EventMuxPriority.data;
}

/// One bounded event item held by [EventMux].
final class EventMuxEntry<T> {
  const EventMuxEntry({
    required this.value,
    required this.priority,
    required this.bytes,
  });

  final T value;
  final EventMuxPriority priority;
  final int bytes;
}

/// Bounded control/data event scheduler.
///
/// Scheduling is deterministic:

/// * critical control wins over normal control and data;
/// * data is forced after [maxConsecutiveControlEvents] control items while
///   data is pending;
/// * oversized items are rejected before allocation;
/// * data overflow drops the oldest data item, while control overflow rejects
///   the new control item so a critical event is never silently evicted.
///
/// The class owns only queued event values.  It does not own the native
/// runtime, a stream subscription, or a socket.
final class EventMux<T> {
  EventMux({
    this.maxControlItems = ResourceLimiter.maxControlQueueItems,
    this.maxControlBytes = ResourceLimiter.maxControlQueueBytes,
    this.maxDataItems = ResourceLimiter.maxDataQueueItems,
    this.maxDataBytes = ResourceLimiter.maxDataQueueBytes,
    this.maxSinglePayloadBytes = ResourceLimiter.maxEventBytes,
    this.maxConsecutiveControlEvents =
        ResourceLimiter.maxConsecutiveControlEvents,
  }) : assert(maxControlItems > 0),
       assert(maxControlBytes > 0),
       assert(maxDataItems > 0),
       assert(maxDataBytes > 0),
       assert(maxSinglePayloadBytes > 0),
       assert(maxConsecutiveControlEvents > 0);

  final int maxControlItems;
  final int maxControlBytes;
  final int maxDataItems;
  final int maxDataBytes;
  final int maxSinglePayloadBytes;
  final int maxConsecutiveControlEvents;

  final Queue<EventMuxEntry<T>> _critical = Queue<EventMuxEntry<T>>();
  final Queue<EventMuxEntry<T>> _normal = Queue<EventMuxEntry<T>>();
  final Queue<EventMuxEntry<T>> _data = Queue<EventMuxEntry<T>>();
  int _controlBytes = 0;
  int _dataBytes = 0;
  int _consecutiveControlEvents = 0;
  int _droppedDataItems = 0;
  int _rejectedControlItems = 0;
  int _rejectedOversizeItems = 0;
  bool _closed = false;

  int get controlItemCount => _critical.length + _normal.length;
  int get dataItemCount => _data.length;
  int get controlBytes => _controlBytes;
  int get dataBytes => _dataBytes;
  int get droppedDataItems => _droppedDataItems;
  int get rejectedControlItems => _rejectedControlItems;
  int get rejectedOversizeItems => _rejectedOversizeItems;
  bool get isClosed => _closed;
  bool get isEmpty => _critical.isEmpty && _normal.isEmpty && _data.isEmpty;

  /// Adds one item and returns whether it is retained by the mux.
  bool add(T value, {required EventMuxPriority priority, required int bytes}) {
    if (_closed || bytes < 0 || bytes > maxSinglePayloadBytes) {
      _rejectedOversizeItems++;
      return false;
    }
    final entry = EventMuxEntry<T>(
      value: value,
      priority: priority,
      bytes: bytes,
    );
    if (priority.isControl) return _addControl(entry);
    return _addData(entry);
  }

  /// Returns the next event according to the fairness contract.
  EventMuxEntry<T>? takeEntry() {
    if (_closed && isEmpty) return null;

    final hasData = _data.isNotEmpty;
    final mustServeData =
        hasData && _consecutiveControlEvents >= maxConsecutiveControlEvents;
    if (!mustServeData && _critical.isNotEmpty) {
      return _takeControl(_critical);
    }
    if (!mustServeData && _normal.isNotEmpty) {
      return _takeControl(_normal);
    }
    if (_data.isNotEmpty) {
      final entry = _data.removeFirst();
      _dataBytes -= entry.bytes;
      _consecutiveControlEvents = 0;
      return entry;
    }
    if (_critical.isNotEmpty) return _takeControl(_critical);
    if (_normal.isNotEmpty) return _takeControl(_normal);
    return null;
  }

  /// Convenience value-only dequeue.
  T? take() => takeEntry()?.value;

  /// Closes the mux and releases all queued values.  Closing is idempotent.
  void close() {
    if (_closed) return;
    _closed = true;
    clear();
  }

  /// Drops queued values without changing the lifecycle state.
  void clear() {
    _critical.clear();
    _normal.clear();
    _data.clear();
    _controlBytes = 0;
    _dataBytes = 0;
    _consecutiveControlEvents = 0;
  }

  bool _addControl(EventMuxEntry<T> entry) {
    if (controlItemCount >= maxControlItems ||
        _controlBytes + entry.bytes > maxControlBytes) {
      _rejectedControlItems++;
      return false;
    }
    if (entry.priority == EventMuxPriority.criticalControl) {
      _critical.addLast(entry);
    } else {
      _normal.addLast(entry);
    }
    _controlBytes += entry.bytes;
    return true;
  }

  bool _addData(EventMuxEntry<T> entry) {
    if (entry.bytes > maxDataBytes) {
      _rejectedOversizeItems++;
      return false;
    }
    while (_data.isNotEmpty &&
        (_data.length >= maxDataItems ||
            _dataBytes + entry.bytes > maxDataBytes)) {
      final dropped = _data.removeFirst();
      _dataBytes -= dropped.bytes;
      _droppedDataItems++;
    }
    _data.addLast(entry);
    _dataBytes += entry.bytes;
    return true;
  }

  EventMuxEntry<T> _takeControl(Queue<EventMuxEntry<T>> queue) {
    final entry = queue.removeFirst();
    _controlBytes -= entry.bytes;
    _consecutiveControlEvents++;
    return entry;
  }
}
