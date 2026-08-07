/// 支持激活和停用的生命周期合约。
///
/// 激活通常用于开始监听或轮询，停用只应停止运行时活动，不等同于最终
/// [Disposable.dispose]。这样 Module 可以在同一 Runtime 中安全地暂停和恢复。
abstract interface class Activatable {
  /// 开始当前对象的运行时活动。
  Future<void> activate();

  /// 停止当前对象的运行时活动，但保留重新激活所需的状态。
  Future<void> deactivate();
}
