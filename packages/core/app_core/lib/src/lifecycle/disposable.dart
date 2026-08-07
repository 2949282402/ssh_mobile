/// 可异步释放资源的统一生命周期合约。
///
/// 实现类应保证 [dispose] 可安全重复调用，并在返回前完成自己拥有的
/// Stream、Timer、Subscription 或其他异步资源释放。
abstract interface class Disposable {
  /// 释放当前对象拥有的资源。
  Future<void> dispose();
}
