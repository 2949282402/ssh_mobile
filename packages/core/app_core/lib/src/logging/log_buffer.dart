import 'dart:collection';

/// 有界日志缓冲区，按插入顺序保留最新记录。
///
/// 日志属于高频诊断数据，不能使用无上限的普通 List。达到容量后，
/// 缓冲区会从最旧的一端淘汰记录；调用方仍然拥有持久化到数据库或
/// 文件的责任，缓冲区本身只负责内存中的有界窗口。
final class LogBuffer<T> extends IterableBase<T> {
  /// 默认的 Core 内存日志上限。
  static const int defaultMaxEntries = 2000;

  /// 创建一个容量为 [maxEntries] 的日志缓冲区。
  LogBuffer({int maxEntries = defaultMaxEntries}) : maxEntries = maxEntries {
    if (maxEntries <= 0) {
      throw ArgumentError.value(maxEntries, 'maxEntries', '日志缓冲区容量必须大于 0');
    }
  }

  /// 缓冲区允许保留的最大条数。
  final int maxEntries;
  final ListQueue<T> _entries = ListQueue<T>();

  /// 当前条数。
  @override
  int get length => _entries.length;

  /// 按最旧到最新的顺序遍历记录。
  @override
  Iterator<T> get iterator => _entries.iterator;

  /// 返回最旧到最新的不可变快照。
  List<T> get oldestFirst => List<T>.unmodifiable(_entries);

  /// 返回最新到最旧的不可变快照，适合日志页面展示。
  List<T> get newestFirst => List<T>.unmodifiable(_entries.toList().reversed);

  /// 追加记录，并在超过上限时淘汰最旧记录。
  void add(T entry) {
    _entries.addLast(entry);
    while (_entries.length > maxEntries) {
      _entries.removeFirst();
    }
  }

  /// 按插入顺序追加多条记录，同时维持容量上限。
  void addAll(Iterable<T> entries) {
    for (final entry in entries) {
      add(entry);
    }
  }

  /// 移除并返回最旧记录。
  T removeFirst() => _entries.removeFirst();

  /// 移除满足 [test] 的记录。
  void removeWhere(bool Function(T entry) test) {
    final retained = <T>[];
    for (final entry in _entries) {
      if (!test(entry)) {
        retained.add(entry);
      }
    }
    _entries
      ..clear()
      ..addAll(retained);
  }

  /// 清空内存缓冲区。
  void clear() => _entries.clear();
}
