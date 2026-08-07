// Terminal 原始输出历史的跨平台导出入口。
//
// IO 平台使用加密文件实现；Web/不支持文件系统的平台使用安全空实现，
// 保持 Terminal 页面和 SSH Owner 的调用契约一致。
export 'terminal_history_service_stub.dart'
    if (dart.library.io) 'terminal_history_service_io.dart';
